-- Tests for maki/lua/metronome/ui/panel.lua (REQ-20261114-37).
--
-- The panel is a lifecycle and key router over injected adapters: a renderer,
-- a state store, UI primitives, task focus, runtime actions and autocmds.
-- These tests drive it with fakes, so the whole panel is proven without an
-- interactive host.

return function()
  local render = load_module("ui/render")
  local panel_mod = load_module("ui/panel")

  -- Fixtures ---------------------------------------------------------------

  local tasks = {
    ["T-20261114-a3f2"] = {
      id = "T-20261114-a3f2",
      title = "export CSV",
      status = "reviewing",
      phase = "review",
      review = { round = 2, max_rounds = 3, findings = { { severity = "minor", message = "naming" } } },
    },
    ["T-20261114-b7c1"] = {
      id = "T-20261114-b7c1",
      title = "fix login redirect",
      status = "failed",
      phase = "implement",
      notes = { "check exited 1" },
    },
    ["T-20261114-c9d0"] = {
      id = "T-20261114-c9d0",
      title = "bump deps",
      status = "ready",
    },
    ["T-20261114-d1e2"] = {
      id = "T-20261114-d1e2",
      title = "answer me",
      status = "awaiting_answers",
      questions = { { id = "q1", text = "which db?" } },
    },
  }

  local state = {
    load = function(_root)
      return { tasks = tasks, events = 4 }
    end,
  }

  local function fake_buf()
    local buf = { lines = {}, handlers = {} }
    function buf:set_lines(value)
      self.lines = value
    end
    function buf:line(value)
      self.lines[#self.lines + 1] = value
    end
    function buf:on(event, callback)
      self.handlers[event] = callback
    end
    return buf
  end

  local function fake_win(buf, opts)
    local win = { buf = buf, opts = opts, closed = false, cursor = nil }
    function win:set_cursor(row)
      self.cursor = row
    end
    function win:close()
      self.closed = true
    end
    return win
  end

  local opened = {}
  local ui = {
    buf = function()
      return fake_buf()
    end,
    open_win = function(buf, opts)
      local win = fake_win(buf, opts)
      opened[#opened + 1] = win
      return win
    end,
  }

  local focused = nil
  local task = {
    focus = function(id)
      focused = id
      return true
    end,
  }

  local retried = nil
  local deleted = nil
  local stopped = nil
  local runtime = {
    retry = function(input)
      retried = input.id
      return { ok = true }
    end,
    delete = function(input)
      deleted = input.id
      return { ok = true }
    end,
    stop = function(input)
      stopped = input.id
      return { ok = true }
    end,
  }

  local notified = {}
  local function notify(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end

  local bound = {}
  local unbound = {}
  local next_id = 0
  local function autocmd(event, opts)
    next_id = next_id + 1
    bound[#bound + 1] = { id = next_id, event = event, opts = opts }
    return next_id
  end
  local function del_autocmd(id)
    unbound[#unbound + 1] = id
  end

  local replied = nil
  local function reply(id, text)
    replied = { id = id, text = text }
    return true
  end

  local scheduled = {}
  local function defer(fn, ms)
    scheduled[#scheduled + 1] = { fn = fn, ms = ms }
    return #scheduled
  end

  -- The panel must bind its keys to its own buffer. Without this the focused
  -- floating window swallows every key and the user is softlocked (q, Esc and
  -- the arrows do nothing).
  local keymaps = {}
  local keymap = {
    set = function(mode, lhs, rhs, opts)
      keymaps[#keymaps + 1] = { mode = mode, lhs = lhs, rhs = rhs, opts = opts }
    end,
    del = function(mode, lhs, opts)
      keymaps[#keymaps + 1] = { mode = mode, lhs = lhs, opts = opts, deleted = true }
    end,
  }

  local flashes = {}
  local function flash(msg)
    flashes[#flashes + 1] = msg
  end

  local function new_panel(overrides)
    local opts = {
      render = render,
      state = state,
      root = "/tmp/metronome-test",
      ui = ui,
      task = task,
      runtime = runtime,
      notify = notify,
      autocmd = autocmd,
      del_autocmd = del_autocmd,
      reply = reply,
      defer = defer,
      keymap = keymap,
      flash = flash,
    }
    for k, v in pairs(overrides or {}) do
      opts[k] = v
    end
    return panel_mod.new(opts)
  end

  -- Constructor ------------------------------------------------------------

  local panel, err = new_panel()
  eq(type(panel), "table", "new returns a panel")
  eq(err, nil, "new returns no error with every dependency")

  local missing_render, missing_render_err = panel_mod.new({ state = state, root = "/tmp" })
  eq(missing_render, nil, "new refuses without a renderer")
  eq(type(missing_render_err), "string", "the refusal names the missing renderer")

  local missing_state, missing_state_err = panel_mod.new({ render = render, root = "/tmp" })
  eq(missing_state, nil, "new refuses without a state store")
  eq(type(missing_state_err), "string", "the refusal names the missing state store")

  local missing_root, missing_root_err = panel_mod.new({ render = render, state = state })
  eq(missing_root, nil, "new refuses without a root")
  eq(type(missing_root_err), "string", "the refusal names the missing root")

  -- Open -------------------------------------------------------------------

  eq(panel.open, false, "a new panel is closed")
  eq(panel_mod.open(panel), true, "open succeeds")
  eq(panel.open, true, "open marks the panel open")
  eq(#opened, 1, "open creates exactly one window")
  eq(opened[1].opts.anchor, "NE", "the panel anchors north-east")
  eq(opened[1].opts.width, "60%", "the panel is 60% wide")
  eq(opened[1].opts.height, "60%", "the panel is 60% tall")
  eq(opened[1].opts.stack, false, "the panel does not stack")
  eq(opened[1].opts.cursor_line, true, "the panel highlights the cursor row")
  eq(opened[1].opts.title, "Metronome", "the panel is titled Metronome")
  eq(type(opened[1].opts.footer), "table", "the panel has a footer")
  eq(#opened[1].opts.footer, 8, "the footer lists every action key")
  eq(opened[1].opts.footer[7][1], "v", "the footer offers the verbose toggle")
  eq(opened[1].buf ~= nil, true, "the window shows the panel buffer")
  eq(#opened[1].buf.lines > 0, true, "the buffer is filled before the window opens")
  eq(#panel.rows, 4, "open loads every task")
  eq(panel.cursor, 1, "the cursor starts on the first row")
  eq(opened[1].cursor, 1, "the window cursor starts on the first row")

  -- Key bindings: the focused window must not swallow every key.
  local bound_keys = {}
  for _, entry in ipairs(keymaps) do
    if not entry.deleted then
      bound_keys[entry.lhs] = entry
    end
  end
  for _, key in ipairs({ "<Esc>", "q", "j", "k", "<Down>", "<Up>", "<CR>", "<Space>", "a", "r", "v", "+", "-" }) do
    eq(bound_keys[key] ~= nil, true, "open binds " .. key)
  end
  eq(bound_keys["<Esc>"] and bound_keys["<Esc>"].opts.buffer, opened[1].buf,
    "the keys are scoped to the panel buffer")
  eq(bound_keys["<Esc>"] and bound_keys["<Esc>"].mode, "n",
    "the keys fire in normal mode")

  eq(panel_mod.open(panel), true, "opening an open panel is a no-op")
  eq(#opened, 1, "opening twice does not create a second window")

  -- Rows and ordering ------------------------------------------------------

  eq(panel.rows[1].id, "T-20261114-d1e2", "the panel puts blocked questions first")
  eq(panel.rows[2].id, "T-20261114-b7c1", "the panel puts failures second")
  eq(panel.rows[3].id, "T-20261114-a3f2", "the panel puts reviews third")
  eq(panel.rows[4].id, "T-20261114-c9d0", "the panel puts progress last")
  eq(panel.counts.questions, 1, "the panel counts blocked questions")
  eq(panel.counts.failures, 1, "the panel counts failures")
  eq(panel.counts.review, 1, "the panel counts reviews")
  eq(panel.counts.progress, 1, "the panel counts progress")

  -- Selection --------------------------------------------------------------

  eq(panel_mod.selected(panel).id, "T-20261114-d1e2", "selected is the first row")
  eq(panel_mod.move(panel, 1), 2, "move down advances the cursor")
  eq(panel_mod.selected(panel).id, "T-20261114-b7c1", "the cursor moved to the failure")
  eq(opened[1].cursor, panel.row_line[2], "the window cursor follows the task line")
  eq(panel_mod.move(panel, -1), 1, "move up rewinds the cursor")
  eq(panel_mod.move(panel, -10), 1, "move up clamps at the first row")
  eq(panel_mod.move(panel, 10), 4, "move down clamps at the last row")

  eq(panel_mod.select(panel, 3).id, "T-20261114-a3f2", "select jumps to a row")
  eq(panel_mod.select(panel, 0), nil, "select refuses row zero")
  eq(panel_mod.select(panel, 99), nil, "select refuses a row past the end")
  eq(panel_mod.select(panel, "x"), nil, "select refuses a non-number")

  -- Keys -------------------------------------------------------------------

  eq(panel_mod.handle_key(panel, "j"), "down", "j moves down")
  eq(panel_mod.handle_key(panel, "k"), "up", "k moves up")

  panel_mod.select(panel, 1)
  eq(panel_mod.handle_key(panel, "<CR>"), "focus", "Enter focuses the selected task")
  eq(focused, "T-20261114-d1e2", "Enter focuses the blocked task's transcript")

  local peek_action = panel_mod.handle_key(panel, " ")
  eq(peek_action.action, "peek", "Space asks to peek")
  eq(peek_action.id, "T-20261114-d1e2", "Space peeks at the selected task")

  panel_mod.select(panel, 2)
  retried = nil
  local retry_action = panel_mod.handle_key(panel, "r")
  eq(retry_action.action, "retry", "r retries a failed task")
  eq(retried, "T-20261114-b7c1", "r retries the selected failure")

  panel_mod.select(panel, 1)
  local refused_retry, refused_retry_err = panel_mod.handle_key(panel, "r")
  eq(refused_retry, nil, "r refuses a task that is not failed")
  eq(type(refused_retry_err), "string", "the refusal explains why")

  -- an abandoned task is finished, so the panel hides it --------------------
  tasks["T-20261114-c9d0"].status = "abandoned"
  panel_mod.refresh(panel)
  local abandoned_visible = false
  for _, row in ipairs(panel.rows) do
    if row.id == "T-20261114-c9d0" then
      abandoned_visible = true
    end
  end
  eq(abandoned_visible, false, "an abandoned task is hidden from the panel")
  tasks["T-20261114-c9d0"].status = "ready"
  panel_mod.refresh(panel)

  -- The highlighted line is the selected task ------------------------------
  -- The buffer starts with one summary line per bucket plus a blank line, so
  -- row i is not buffer line i. `d` must delete the task under the cursor.
  local panel_rows = panel.rows
  local lines = panel.buf.lines
  for i, row in ipairs(panel_rows) do
    local line = render.text(lines[panel.row_line[i]])
    eq(line:find(row.id:sub(-4), 1, true) ~= nil, true,
      "row " .. i .. " maps to the buffer line that shows it")
  end
  local first_row = panel_rows[1]
  local picked = panel_mod.select(panel, panel.row_line[1])
  eq(picked and picked.id, first_row.id, "selecting a buffer line selects its task")
  eq(panel.win.cursor, panel.row_line[1], "the window cursor sits on the task line")
  panel_mod.move(panel, 1)
  eq(panel.win.cursor, panel.row_line[2], "moving down moves the cursor one task line")

  -- d deletes the selected task --------------------------------------------
  local selected_index
  for i, row in ipairs(panel.rows) do
    if row.id == "T-20261114-c9d0" then
      selected_index = i
    end
  end
  panel_mod.select(panel, selected_index)
  deleted = nil
  local delete_action = panel_mod.handle_key(panel, "d")
  eq(delete_action and delete_action.action, "delete", "d deletes the selected task")
  eq(deleted, "T-20261114-c9d0", "d deletes the selected task id")

  -- s stops an in-flight task without deleting it --------------------------
  tasks["T-20261114-a3f2"].status = "running"
  panel_mod.refresh(panel)
  local running_index
  for i, row in ipairs(panel.rows) do
    if row.id == "T-20261114-a3f2" then
      running_index = i
    end
  end
  panel_mod.select(panel, running_index)
  stopped = nil
  local stop_action = panel_mod.handle_key(panel, "s")
  eq(stop_action and stop_action.action, "stop", "s stops the selected task")
  eq(stopped, "T-20261114-a3f2", "s stops the selected task id")
  eq(deleted, "T-20261114-c9d0", "s does not delete the task")

  local answer_action = panel_mod.handle_key(panel, "a")
  eq(answer_action.action, "answer", "a asks to answer")
  eq(answer_action.count, 1, "a carries the blocked count")

  local rate_action = panel_mod.handle_key(panel, "+")
  eq(rate_action.action, "rate", "+ asks to rate a finding")
  eq(rate_action.sign, 1, "+ is a positive rating")
  eq(panel_mod.handle_key(panel, "-").sign, -1, "- is a negative rating")

  local unknown, unknown_err = panel_mod.handle_key(panel, "z")
  eq(unknown, nil, "an unknown key is refused")
  eq(type(unknown_err), "string", "the unknown key is named")

  -- Peek and reply ---------------------------------------------------------

  local info = panel_mod.peek(panel, "T-20261114-b7c1", { verbose = true })
  eq(info.id, "T-20261114-b7c1", "peek returns the task")
  eq(info.status, "failed", "peek returns the status")
  eq(info.notes[1], "check exited 1", "verbose peek returns the notes")
  eq(#info.findings, 0, "peek returns no findings for a task without review")

  local quiet_info = panel_mod.peek(panel, "T-20261114-b7c1")
  eq(#quiet_info.notes, 0, "quiet peek hides the agent's notes")

  local review_info = panel_mod.peek(panel, "T-20261114-a3f2", { verbose = true })
  eq(review_info.findings[1].severity, "minor", "peek returns the findings")
  eq(panel_mod.peek(panel, "T-missing"), nil, "peek refuses an unknown task")

  local peeked = panel_mod.peek_text(panel, "T-20261114-d1e2", { verbose = true })
  eq(type(peeked), "string", "peek_text returns text")
  eq(peeked:find("which db?", 1, true) ~= nil, true, "peek_text shows the pending question")
  eq(peeked:find("awaiting_answers", 1, true) ~= nil, true, "peek_text shows the status")

  tasks["T-20261114-b7c1"].intent = "add a real login"
  tasks["T-20261114-b7c1"].origin = "make the site usable"
  tasks["T-20261114-b7c1"].depends_on = { "T-20261114-c9d0" }
  tasks["T-20261114-b7c1"].branch = "metronome/fix-login-redirect-b7c1"
  local peeked_failed = panel_mod.peek_text(panel, "T-20261114-b7c1", { verbose = true })
  eq(peeked_failed:find("asked: add a real login", 1, true) ~= nil, true,
    "peek_text shows the intention")
  eq(peeked_failed:find("request: make the site usable", 1, true) ~= nil, true,
    "peek_text shows the submitted request")
  eq(peeked_failed:find("depends on: T-20261114-c9d0", 1, true) ~= nil, true,
    "peek_text shows the dependencies")
  eq(peeked_failed:find("branch: metronome/fix-login-redirect-b7c1", 1, true) ~= nil, true,
    "peek_text shows the branch")
  tasks["T-20261114-b7c1"].intent = nil
  tasks["T-20261114-b7c1"].origin = nil
  tasks["T-20261114-b7c1"].depends_on = nil
  tasks["T-20261114-b7c1"].branch = nil
  replied = nil
  eq(panel_mod.reply(panel, "T-20261114-b7c1", "retry with the fix"), true, "reply succeeds")
  eq(replied.id, "T-20261114-b7c1", "reply targets the task")
  eq(replied.text, "retry with the fix", "reply carries the text")
  eq(panel_mod.reply(panel, "T-1", ""), nil, "reply refuses empty text")

  local no_reply = panel_mod.new({
    render = render,
    state = state,
    root = "/tmp/metronome-test",
    ui = ui,
    task = task,
    runtime = runtime,
    notify = notify,
    autocmd = autocmd,
    del_autocmd = del_autocmd,
    defer = defer,
  })
  local no_reply_ok, no_reply_err = panel_mod.reply(no_reply, "T-1", "hello")
  eq(no_reply_ok, nil, "reply refuses when it is not wired")
  eq(type(no_reply_err), "string", "the refusal names the missing reply")

  -- Bell -------------------------------------------------------------------

  notified = {}
  local bell = panel_mod.bell(panel, { questions = 0, failures = 0 })
  eq(type(bell), "string", "the bell rings when blocked work appears")
  eq(bell:find("question", 1, true) ~= nil, true, "the bell names the questions")
  eq(bell:find("failed", 1, true) ~= nil, true, "the bell names the failures")
  eq(#notified, 1, "the bell notifies once")
  eq(notified[1].level, "warn", "the bell notifies at warn level")
  eq(panel_mod.bell(panel, { questions = 1, failures = 1 }), nil, "the bell stays quiet when nothing grew")

  -- Events ----------------------------------------------------------------

  eq(#bound, 2, "open binds two events")
  eq(bound[1].event, "TaskStatusChanged", "the panel listens to TaskStatusChanged")
  eq(bound[2].event, "TurnEnd", "the panel listens to TurnEnd")
  eq(type(bound[1].opts.callback), "function", "the event has a callback")

  local before = #opened[1].buf.lines
  bound[1].opts.callback()
  eq(#opened[1].buf.lines, before, "a refresh redraws the same task count")

  -- Push -------------------------------------------------------------------

  eq(panel_mod.push(panel, "working..."), nil, "quiet mode hides progress lines")
  eq(#opened[1].buf.lines, before, "quiet mode does not grow the buffer")
  panel_mod.set_quiet(panel, false)
  eq(panel_mod.push(panel, "working..."), true, "verbose push appends a progress line")
  eq(#opened[1].buf.lines, before + 1, "verbose push grows the buffer")
  eq(panel_mod.push({ buf = nil }, "x"), nil, "push refuses a closed panel")

  -- Quiet mode -------------------------------------------------------------

  eq(panel.quiet, false, "the verbose toggle left quiet off")
  eq(panel_mod.set_quiet(panel, true), true, "set_quiet turns quiet back on")
  eq(panel.quiet, true, "set_quiet stores the mode")
  local frame_before = panel.frame
  eq(panel_mod.tick(panel), frame_before + 1, "tick advances the spinner frame")
  eq(panel.frame, frame_before + 1, "tick stores the frame")
  eq(panel_mod.handle_key(panel, "v"), "verbose", "v switches to verbose")
  eq(panel.quiet, false, "v turned quiet off")
  eq(panel_mod.handle_key(panel, "v"), "quiet", "v switches back to quiet")
  eq(panel.quiet, true, "v turned quiet on")
  eq(#scheduled > 0, true, "opening the panel schedules the spinner")

  -- Close and toggle -------------------------------------------------------

  eq(panel_mod.close(panel), true, "close succeeds")
  eq(panel.open, false, "close marks the panel closed")
  eq(opened[1].closed, true, "close closes the window")
  eq(panel.win, nil, "close drops the window handle")
  eq(panel.buf, nil, "close drops the buffer")
  eq(#unbound, 2, "close unbinds both events")
  eq(panel_mod.push(panel, "after close"), nil, "a closed panel has no buffer")

  eq(panel_mod.toggle(panel), true, "toggle opens a closed panel")
  eq(panel.open, true, "toggle left the panel open")
  eq(#opened, 2, "toggle opened a second window")
  eq(panel_mod.toggle(panel), false, "toggle closes an open panel")
  eq(panel.open, false, "toggle left the panel closed")

  -- Bound keys actually drive the panel ------------------------------------

  keymaps = {}
  flashes = {}
  local fresh = new_panel()
  eq(panel_mod.open(fresh), true, "a fresh panel opens")
  local fresh_keys = {}
  for _, entry in ipairs(keymaps) do
    fresh_keys[entry.lhs] = entry
  end
  eq(type(fresh_keys["<Esc>"]), "table", "the fresh panel binds Esc")
  fresh_keys["<Esc>"].rhs({ key = "<Esc>" })
  eq(fresh.open, false, "Esc closes the panel through its binding")
  eq(opened[#opened].closed, true, "the Esc binding closes the window")
  local deleted = 0
  for _, entry in ipairs(keymaps) do
    if entry.deleted then
      deleted = deleted + 1
    end
  end
  eq(deleted >= 13, true, "closing removes every panel key binding")

  keymaps = {}
  flashes = {}
  local peeker = new_panel()
  eq(panel_mod.open(peeker), true, "the peek panel opens")
  panel_mod.dispatch(peeker, "<Space>")
  eq(#flashes, 1, "Space peeks through the dispatcher")
  eq(type(flashes[1]), "string", "the peek flashes text")
  eq(flashes[1]:find("which db?", 1, true) ~= nil, true, "the peek shows the pending question")

  flashes = {}
  panel_mod.dispatch(peeker, "a")
  eq(#flashes, 1, "a asks for the pending questions")
  eq(flashes[1]:find("which db?", 1, true) ~= nil, true, "the answer prompt lists the question")
  panel_mod.close(peeker)

  -- `a` with an ask adapter reaches the user the way a background
  -- qualification does: the agent comes back with the native question prompt.
  local asked = 0
  local asker = new_panel({
    ask = function()
      asked = asked + 1
      return { ok = true, asked = 2 }
    end,
  })
  flashes = {}
  panel_mod.open(asker)
  panel_mod.dispatch(asker, "a")
  eq(asked, 1, "a calls the ask adapter")
  eq(#flashes, 1, "a reports what it did")
  eq(flashes[1]:find("2 question", 1, true) ~= nil, true, "the flash counts the questions asked")
  panel_mod.close(asker)

  -- Missing UI -------------------------------------------------------------

  local headless = new_panel({ ui = {} })
  local headless_ok, headless_err = panel_mod.open(headless)
  eq(headless_ok, nil, "open refuses without UI primitives")
  eq(type(headless_err), "string", "the refusal explains the missing UI")
end
