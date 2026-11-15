-- The Metronome live panel.
--
-- A floating window that shows the attention bell and one row per task. It is
-- the human's view of the pipeline: blocked questions, failures, reviews ready
-- to read, and work in progress, in that order.
--
-- Everything the panel touches is injected: the renderer, the state store, the
-- UI primitives, the task focus, the runtime actions and the autocmd API. That
-- keeps the module testable without an interactive host, and it keeps the
-- panel from reaching into the pipeline directly. The panel never runs a
-- phase; it only calls the runtime action the user asked for.
--
-- Keys, matching the plan:
--   Enter  focus the selected task's transcript
--   Space  peek at the task without attaching, or reply
--   r      retry a failed task
--   a      answer the pending question round
--   +/-    rate a review finding (calibration)
--   j/k    move the cursor
--   q      close

local M = {}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

-- Default UI adapters, resolved lazily so a test can inject fakes and a host
-- without a UI (maki -p) still loads the module.
local function ui_of(panel)
  if type(panel.deps.ui) == "table" then
    return panel.deps.ui
  end
  return { buf = maki.ui.buf, open_win = maki.ui.open_win }
end

local function task_of(panel)
  if type(panel.deps.task) == "table" then
    return panel.deps.task
  end
  return maki.task
end

local function notify_of(panel)
  local notify = panel.deps.notify
  if type(notify) == "function" then
    return notify
  end
  return maki.notify
end

local function keymap_of(panel)
  if type(panel.deps.keymap) == "table" then
    return panel.deps.keymap
  end
  return maki.keymap
end

local function flash_of(panel)
  if type(panel.deps.flash) == "function" then
    return panel.deps.flash
  end
  if maki.ui and type(maki.ui.flash) == "function" then
    return maki.ui.flash
  end
  return nil
end

local function show(panel, text)
  local flash = flash_of(panel)
  if type(flash) == "function" and text ~= nil then
    pcall(flash, tostring(text))
  end
end

-- Every key the panel handles. They are bound to the panel's own buffer in
-- normal mode: the window takes focus on open, so without these bindings it
-- would swallow every key and the user could not even close it.
local PANEL_KEYS = {
  { "<Esc>", "close" },
  { "q", "close" },
  { "j", "down" },
  { "<Down>", "down" },
  { "k", "up" },
  { "<Up>", "up" },
  { "<CR>", "focus" },
  { "<Space>", "peek" },
  { "a", "answer" },
  { "r", "retry" },
  { "d", "delete" },
  { "s", "stop" },
  { "v", "verbose" },
  { "+", "rate up" },
  { "-", "rate down" },
}

-- Constructor ---------------------------------------------------------------

-- `opts` fields:
--   render   (table, required) ui/render.lua
--   state    (table, required) state.lua
--   root     (string, required) state directory
--   ui       (table?) { buf, open_win }
--   task     (table?) { focus }
--   runtime  (table?) { retry }
--   reply    (function?) reply(task_id, text)
--   notify   (function?) notify(msg, level)
--   autocmd  (function?) create_autocmd(event, opts)
--   del_autocmd (function?) del_autocmd(id)
function M.new(opts)
  opts = type(opts) == "table" and opts or {}
  if type(opts.render) ~= "table" then
    return nil, "render module is required"
  end
  if type(opts.state) ~= "table" or type(opts.state.load) ~= "function" then
    return nil, "state module is required"
  end
  if not is_non_empty(opts.root) then
    return nil, "state root is required"
  end

  return {
    deps = opts,
    render = opts.render,
    state = opts.state,
    root = opts.root,
    open = false,
    win = nil,
    buf = nil,
    rows = {},
    cursor = 1,
    counts = { questions = 0, failures = 0, review = 0, progress = 0 },
    autocmds = {},
    -- Quiet mode is the Metronome default: the panel shows a spinner instead
    -- of the agent's actions and reflections. `v` switches to verbose.
    quiet = opts.quiet ~= false,
    frame = 0,
    animating = false,
    interval = tonumber(opts.interval) or 120,
    keymaps = {},
  }
end

-- State and redraw ----------------------------------------------------------

function M.load(panel)
  local ok, state = pcall(panel.state.load, panel.root)
  if not ok or type(state) ~= "table" then
    return nil, "cannot load state"
  end
  return state
end

-- Rebuild the buffer from the projection. Returns the attention counts, which
-- the bell and `a` both use.
function M.refresh(panel)
  local state, err = M.load(panel)
  if not state then
    return nil, err
  end
  local lines, rows, counts = panel.render.lines(state.tasks, {
    quiet = panel.quiet,
    frame = panel.frame,
  })
  panel.rows = rows
  panel.counts = counts
  if #rows == 0 then
    panel.cursor = 1
  else
    panel.cursor = math.max(1, math.min(panel.cursor, #rows))
  end
  if panel.buf then
    panel.buf:set_lines(lines)
  end
  if panel.win and type(panel.win.set_cursor) == "function" then
    panel.win:set_cursor(panel.cursor)
  end
  return counts
end

-- Window lifecycle ----------------------------------------------------------

function M.open(panel)
  if panel.open then
    M.refresh(panel)
    return true
  end
  local ui = ui_of(panel)
  if type(ui.buf) ~= "function" or type(ui.open_win) ~= "function" then
    return nil, "UI is not available"
  end

  panel.buf = ui.buf()
  M.refresh(panel)
  panel.win = ui.open_win(panel.buf, {
    title = "Metronome",
    anchor = "NE",
    width = "60%",
    height = "60%",
    stack = false,
    cursor_line = true,
    footer = {
      { "Enter", "focus" },
      { "Space", "peek" },
      { "a", "answer" },
      { "r", "retry" },
      { "d", "delete" },
      { "s", "stop" },
      { "v", "verbose" },
      { "q", "close" },
    },
  })
  panel.open = true

  -- `refresh` ran before the window existed, so the initial cursor row was
  -- never applied. Set it now that the window can take it.
  if type(panel.win.set_cursor) == "function" then
    panel.win:set_cursor(panel.cursor)
  end

  if type(panel.buf.on) == "function" then
    panel.buf:on("click", function(ev)
      if ev and type(ev.row) == "number" then
        M.select(panel, ev.row)
      end
    end)
  end

  M.bind(panel)
  M.bind_keys(panel)
  M.start_animation(panel)
  return true
end

function M.close(panel)
  M.stop_animation(panel)
  M.unbind(panel)
  M.unbind_keys(panel)
  if panel.win and type(panel.win.close) == "function" then
    panel.win:close()
  end
  panel.win = nil
  panel.buf = nil
  panel.open = false
  panel.rows = {}
  panel.cursor = 1
  panel.counts = { questions = 0, failures = 0, review = 0, progress = 0 }
  panel.frame = 0
  return true
end

-- Quiet mode and the spinner animation ------------------------------------

local function defer_of(panel)
  if type(panel.deps.defer) == "function" then
    return panel.deps.defer
  end
  return maki.defer_fn
end

-- Switch between quiet and verbose. Quiet hides the agent's action detail and
-- progress lines; verbose restores them for debugging. Returns the new mode.
function M.set_quiet(panel, quiet)
  panel.quiet = quiet and true or false
  if panel.open then
    if panel.quiet then
      M.start_animation(panel)
    else
      M.stop_animation(panel)
    end
    M.refresh(panel)
  end
  return panel.quiet
end

-- Advance the spinner one frame and redraw. The frame is kept even while the
-- panel is closed, so reopening resumes where it stopped.
function M.tick(panel)
  panel.frame = (panel.frame or 0) + 1
  if panel.open then
    M.refresh(panel)
  end
  return panel.frame
end

-- A single deferred loop, not a timer object: the callback re-arms itself only
-- while the panel is open and quiet, so closing stops the animation without
-- needing a cancel handle.
function M.start_animation(panel)
  if not panel.open or not panel.quiet or panel.animating then
    return false
  end
  local defer = defer_of(panel)
  if type(defer) ~= "function" then
    return false
  end
  panel.animating = true
  defer(function()
    if not panel.open or not panel.quiet then
      panel.animating = false
      return
    end
    M.tick(panel)
    panel.animating = false
    M.start_animation(panel)
  end, panel.interval)
  return true
end

function M.stop_animation(panel)
  panel.animating = false
  return true
end

function M.toggle(panel)
  if panel.open then
    M.close(panel)
  else
    local ok, err = M.open(panel)
    if not ok then
      return nil, err
    end
  end
  return panel.open
end

-- Selection -----------------------------------------------------------------

function M.select(panel, row)
  if type(row) ~= "number" then
    return nil, "row must be a number"
  end
  if row < 1 or row > #panel.rows then
    return nil, "row out of range"
  end
  panel.cursor = row
  if panel.win and type(panel.win.set_cursor) == "function" then
    panel.win:set_cursor(row)
  end
  return panel.rows[row]
end

function M.move(panel, delta)
  if #panel.rows == 0 then
    return nil
  end
  panel.cursor = math.max(1, math.min(#panel.rows, panel.cursor + delta))
  if panel.win and type(panel.win.set_cursor) == "function" then
    panel.win:set_cursor(panel.cursor)
  end
  return panel.cursor
end

function M.selected(panel)
  return panel.rows[panel.cursor]
end

-- Actions -------------------------------------------------------------------

function M.focus(panel, id)
  local task = task_of(panel)
  if type(task.focus) ~= "function" then
    return nil, "task focus is not wired"
  end
  local ok, err = task.focus(id)
  if not ok then
    return nil, tostring(err or "cannot focus task")
  end
  return true
end

function M.retry(panel, id)
  local runtime = panel.deps.runtime
  if type(runtime) ~= "table" or type(runtime.retry) ~= "function" then
    return nil, "retry is not wired"
  end
  local ok, result = pcall(runtime.retry, { id = id })
  if not ok then
    return nil, tostring(result)
  end
  if type(result) == "table" and result.ok == false then
    return nil, tostring(result.error or "retry failed")
  end
  M.refresh(panel)
  return { action = "retry", id = id }
end

-- Stop is not delete: the task keeps its journal entry and its worktree, and
-- `retry` can restart it. Deleting a running task would leave its session
-- writing to a record nobody can see.
function M.stop(panel, id)
  local runtime = panel.deps.runtime
  if type(runtime) ~= "table" or type(runtime.stop) ~= "function" then
    return nil, "stop is not wired"
  end
  local ok, result = pcall(runtime.stop, { id = id })
  if not ok then
    return nil, tostring(result)
  end
  if type(result) == "table" and result.ok == false then
    return nil, tostring(result.error or "stop failed")
  end
  M.refresh(panel)
  return { action = "stop", id = id }
end

function M.delete(panel, id)
  local runtime = panel.deps.runtime
  if type(runtime) ~= "table" or type(runtime.delete) ~= "function" then
    return nil, "delete is not wired"
  end
  local ok, result = pcall(runtime.delete, { id = id })
  if not ok then
    return nil, tostring(result)
  end
  if type(result) == "table" and result.ok == false then
    return nil, tostring(result.error or "delete failed")
  end
  M.refresh(panel)
  return { action = "delete", id = id }
end

-- Peek without attaching: the task's own record, its pending questions, its
-- notes and its findings. Nothing is focused and no transcript is moved.
function M.peek(panel, id, opts)
  opts = type(opts) == "table" and opts or {}
  local quiet = opts.quiet
  if quiet == nil then
    quiet = not opts.verbose and panel.quiet
  end
  local state, err = M.load(panel)
  if not state then
    return nil, err
  end
  local task = type(state.tasks) == "table" and state.tasks[id] or nil
  if type(task) ~= "table" then
    return nil, "unknown task: " .. tostring(id)
  end
  return {
    id = task.id,
    title = task.title,
    status = task.status,
    phase = task.phase,
    notes = (not quiet and type(task.notes) == "table") and task.notes or {},
    findings = type(task.review) == "table" and type(task.review.findings) == "table"
      and task.review.findings or {},
    questions = panel.render.pending_questions(task),
  }
end

function M.peek_text(panel, id, opts)
  local info, err = M.peek(panel, id, opts)
  if not info then
    return nil, err
  end
  local lines = {
    tostring(info.id) .. "  " .. tostring(info.title),
    "status: " .. tostring(info.status)
      .. (info.phase and ("  phase: " .. tostring(info.phase)) or ""),
  }
  for _, question in ipairs(info.questions) do
    lines[#lines + 1] = "? " .. tostring(question.text)
  end
  for _, note in ipairs(info.notes) do
    lines[#lines + 1] = "- " .. tostring(note)
  end
  for _, finding in ipairs(info.findings) do
    lines[#lines + 1] = "! " .. tostring(finding.severity) .. ": " .. tostring(finding.message)
  end
  return table.concat(lines, "\n")
end

-- Reply to a task without attaching to its transcript. The send function is
-- injected by the pipeline; the panel only guards the call.
function M.reply(panel, id, text)
  local reply = panel.deps.reply
  if type(reply) ~= "function" then
    return nil, "reply is not wired"
  end
  if not is_non_empty(text) then
    return nil, "reply text is required"
  end
  local ok, result = pcall(reply, id, text)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

-- Key handling. Returns an action name, or an action table for the caller to
-- complete (`peek`, `answer`, `rate`), or nil and a reason.
function M.handle_key(panel, key)
  if key == "q" or key == "<Esc>" then
    M.close(panel)
    return "close"
  end

  if key == "<Down>" or key == "j" then
    M.move(panel, 1)
    return "down"
  end

  if key == "<Up>" or key == "k" then
    M.move(panel, -1)
    return "up"
  end

  if key == "<CR>" or key == "Enter" then
    local row = M.selected(panel)
    if not row then
      return nil, "no task selected"
    end
    local ok, err = M.focus(panel, row.id)
    if not ok then
      return nil, err
    end
    return "focus"
  end

  if key == " " or key == "<Space>" then
    local row = M.selected(panel)
    if not row then
      return nil, "no task selected"
    end
    return { action = "peek", id = row.id }
  end

  if key == "r" then
    local row = M.selected(panel)
    if not row then
      return nil, "no task selected"
    end
    if row.status ~= "failed" and row.status ~= "stalled" and row.status ~= "abandoned" then
      return nil, "task is not failed, stalled or abandoned"
    end
    return M.retry(panel, row.id)
  end

  if key == "d" then
    local row = M.selected(panel)
    if not row then
      return nil, "no task selected"
    end
    return M.delete(panel, row.id)
  end

  if key == "s" then
    local row = M.selected(panel)
    if not row then
      return nil, "no task selected"
    end
    return M.stop(panel, row.id)
  end

  if key == "a" then
    return { action = "answer", count = panel.counts.questions }
  end

  if key == "v" then
    return M.set_quiet(panel, not panel.quiet) and "quiet" or "verbose"
  end

  if key == "+" or key == "-" then
    local row = M.selected(panel)
    if not row then
      return nil, "no task selected"
    end
    return { action = "rate", id = row.id, sign = key == "+" and 1 or -1 }
  end

  return nil, "unhandled key: " .. tostring(key)
end

-- Bind the panel keys to its buffer. A focused window takes every key, so
-- these buffer bindings are what make the footer true. They are set in normal
-- mode, the mode a focused window runs in, and removed when the panel closes.
function M.bind_keys(panel)
  local keymap = keymap_of(panel)
  if type(keymap) ~= "table" or type(keymap.set) ~= "function" then
    return nil, "keymap is not available"
  end
  if not panel.buf then
    return nil, "panel has no buffer"
  end
  panel.keymaps = {}
  for _, entry in ipairs(PANEL_KEYS) do
    local key, label = entry[1], entry[2]
    local ok = pcall(keymap.set, "n", key, function(ev)
      M.dispatch(panel, ev and ev.key or key)
    end, { buffer = panel.buf, desc = "metronome: " .. label })
    if ok then
      panel.keymaps[#panel.keymaps + 1] = key
    end
  end
  return #panel.keymaps
end

function M.unbind_keys(panel)
  local keymap = keymap_of(panel)
  local buf = panel.buf
  if type(keymap) == "table" and type(keymap.del) == "function" and buf then
    for _, key in ipairs(panel.keymaps or {}) do
      pcall(keymap.del, "n", key, { buffer = buf })
    end
  end
  panel.keymaps = {}
  return true
end

-- Run a key and complete the action it asks for. `handle_key` stays pure; this
-- is the side-effecting half the keymap handlers call.
function M.dispatch(panel, key)
  local action, err = M.handle_key(panel, key)
  if action == nil then
    if err then
      show(panel, err)
    end
    return action, err
  end
  if type(action) ~= "table" then
    return action
  end

  if action.action == "peek" then
    local text, peek_err = M.peek_text(panel, action.id)
    show(panel, peek_err or text)
  elseif action.action == "answer" then
    -- `a` must reach the user the way a background qualification does: the
    -- agent comes back with the native question prompt. Printing the text in
    -- the panel would show questions nobody can answer.
    local ask = type(panel.deps.ask) == "function" and panel.deps.ask or nil
    if ask then
      local ok, result = pcall(ask)
      if not ok then
        show(panel, tostring(result))
      elseif type(result) == "table" and result.ok == false then
        local text, questions_err = M.questions_text(panel)
        show(panel, questions_err or text)
      else
        local count = type(result) == "table" and result.asked or 0
        show(panel, string.format("%d question(s) posée(s) dans le chat", count))
      end
    else
      local text, questions_err = M.questions_text(panel)
      show(panel, questions_err or text)
    end
  elseif action.action == "rate" then
    local runtime = panel.deps.runtime
    if type(runtime) == "table" and type(runtime.feedback) == "function" then
      local ok, result = pcall(runtime.feedback, {
        id = action.id,
        vote = action.sign > 0 and "up" or "down",
      })
      if not ok then
        show(panel, result)
      elseif type(result) == "table" and result.ok == false then
        show(panel, result.error)
      end
    else
      show(panel, "feedback is not wired")
    end
  end
  return action
end

-- The pending question round, as text. `a` flashes it so the user can see what
-- is blocking without leaving the panel.
function M.questions_text(panel)
  local state, err = M.load(panel)
  if not state then
    return nil, err
  end
  local lines = {}
  for _, task in pairs(state.tasks or {}) do
    for _, question in ipairs(panel.render.pending_questions(task)) do
      lines[#lines + 1] = tostring(task.id) .. ": " .. tostring(question.text)
    end
  end
  if #lines == 0 then
    return "no pending questions"
  end
  return table.concat(lines, "\n")
end

-- Events --------------------------------------------------------------------

-- Redraw on the events that can change the list, never by polling. The
-- callback checks `panel.open` so a closed panel does not redraw.
function M.bind(panel)
  if #panel.autocmds > 0 then
    return panel.autocmds
  end
  local register = panel.deps.autocmd
  if type(register) ~= "function" then
    register = maki.api and maki.api.create_autocmd
  end
  if type(register) ~= "function" then
    return panel.autocmds
  end
  for _, event in ipairs({ "TaskStatusChanged", "TurnEnd" }) do
    local id = register(event, {
      callback = function()
        if panel.open then
          M.refresh(panel)
        end
      end,
    })
    if id ~= nil then
      panel.autocmds[#panel.autocmds + 1] = id
    end
  end
  return panel.autocmds
end

function M.unbind(panel)
  local del = panel.deps.del_autocmd
  if type(del) ~= "function" then
    del = maki.api and maki.api.del_autocmd
  end
  if type(del) == "function" then
    for _, id in ipairs(panel.autocmds) do
      pcall(del, id)
    end
  end
  panel.autocmds = {}
  return true
end

-- The bell: notify only when the count of blocked questions or failures goes
-- up, so a redraw does not spam the user.
function M.bell(panel, previous)
  local counts = panel.counts or {}
  previous = type(previous) == "table" and previous or { questions = 0, failures = 0 }
  local parts = {}
  if (counts.questions or 0) > (previous.questions or 0) then
    parts[#parts + 1] = (counts.questions or 0) .. " question(s) blocked"
  end
  if (counts.failures or 0) > (previous.failures or 0) then
    parts[#parts + 1] = (counts.failures or 0) .. " task(s) failed"
  end
  if #parts == 0 then
    return nil
  end
  local msg = table.concat(parts, ", ")
  local notify = notify_of(panel)
  if type(notify) == "function" then
    pcall(notify, msg, "warn")
  end
  return msg
end

-- Append a progress line while a task runs. A closed panel has no buffer, so
-- the caller gets a reason instead of an error.
function M.push(panel, line)
  if not panel.buf then
    return nil, "panel is not open"
  end
  -- In quiet mode the panel is a waiting indicator, not a log. The caller can
  -- keep pushing; nothing is drawn until the user asks for verbose.
  if panel.quiet then
    return nil, "quiet mode hides progress lines"
  end
  panel.buf:line(line)
  return true
end

function M.attention(panel)
  return panel.counts
end

return M
