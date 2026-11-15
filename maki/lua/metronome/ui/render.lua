-- Rendering for the Metronome live panel.
--
-- This module is pure: it turns the task projection into styled buffer lines
-- and never touches a window, a file or a model. That is what lets the panel
-- be tested without an interactive host, and it keeps the urgency rules in one
-- place instead of scattering them through key handlers.
--
-- The attention bell is the ordering rule from the plan: blocked questions
-- first, then failures, then reviews ready to read, then everything still in
-- progress. A task with an unanswered question outranks its status: a task
-- that is nominally `qualifying` but still owes an answer is blocked, and the
-- user is the one who unblocks it.

local M = {}

-- Buckets, in urgency order. `mark` is the one-cell glyph the header uses.
M.BUCKETS = {
  { key = "questions", label = "questions", mark = "!", hint = "a to answer" },
  { key = "failures", label = "failures", mark = "!", hint = "r to retry" },
  { key = "review", label = "review ready", mark = "~", hint = "Enter to read" },
  { key = "progress", label = "in progress", mark = ".", hint = "" },
  { key = "done", label = "done", mark = "✓", hint = "d to delete" },
}

-- Statuses that still have work ahead. Everything else is finished or
-- archived, so it must not spin: a spinner on a deployed or abandoned task
-- told the user work was moving when nothing was.
local TERMINAL = { deployed = true, merged = true, abandoned = true }

local RANK = {}
for i, bucket in ipairs(M.BUCKETS) do
  RANK[bucket.key] = i
end

-- Status to role, used when a task has no explicit phase. The panel shows who
-- owns the task so the user knows which transcript Enter will open.
local PHASE_ROLE = {
  qualify = "qualifier",
  analyze = "analyst",
  implement = "implementer",
  verify = "implementer",
  converge = "implementer",
  review = "reviewer",
  merge = "reviewer",
  deploy = "deployer",
}

local STATUS_ROLE = {
  draft = "qualifier",
  qualifying = "qualifier",
  awaiting_answers = "qualifier",
  ready = "implementer",
  running = "implementer",
  verifying = "implementer",
  reviewing = "reviewer",
  changes_requested = "implementer",
  pr_open = "reviewer",
  merging = "reviewer",
  merged = "deployer",
  deploying = "deployer",
  deployed = "deployer",
  failed = "implementer",
  stalled = "implementer",
}

-- Orchestra names, mirrored from roles.lua. The panel reads this table so it
-- does not need the filesystem-backed roles module; roles_test asserts the two
-- tables agree.
local ROLE_NAMES = {
  qualifier = "chef de pupitre",
  analyst = "harmoniste",
  implementer = "instrumentiste",
  reviewer = "critique",
  deployer = "timbalier",
}

function M.role_name(role)
  return ROLE_NAMES[role] or role
end

-- Quiet mode: while the Metronome panel is open, the user asked to stop seeing
-- the agent's actions and reflections. The panel keeps what needs a human
-- (blocked questions, failures, reviews) and replaces the running task's phase
-- with a spinner, so the panel still shows that work is moving without
-- narrating it. The frames are braille glyphs, one cell wide.
M.SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.spinner(frame)
  local n = #M.SPINNER
  local index = math.floor(tonumber(frame) or 0) % n
  return M.SPINNER[index + 1]
end

-- The unanswered questions on a task. An empty string counts as unanswered so
-- a form that posts an empty field does not silently close the question.
function M.pending_questions(task)
  local list = {}
  if type(task) ~= "table" or type(task.questions) ~= "table" then
    return list
  end
  for _, question in ipairs(task.questions) do
    if type(question) == "table"
      and type(question.text) == "string"
      and (question.answer == nil or question.answer == "") then
      list[#list + 1] = question
    end
  end
  return list
end

-- Which attention bucket a task belongs to.
function M.bucket(task)
  if type(task) ~= "table" then
    return "progress"
  end
  if #M.pending_questions(task) > 0 or task.status == "awaiting_answers" then
    return "questions"
  end
  if task.status == "failed" or task.status == "stalled" then
    return "failures"
  end
  if TERMINAL[task.status] then
    return "done"
  end
  if task.status == "reviewing" or task.status == "changes_requested" or task.status == "pr_open" then
    return "review"
  end
  return "progress"
end

function M.urgency(task)
  return RANK[M.bucket(task)] or RANK.progress
end

-- `T-20261114-a3f2` becomes `T-…a3f2`: the date is noise in a narrow panel,
-- the four-character suffix is what the user types in commands.
function M.short_id(id)
  local s = tostring(id or "")
  if s == "" then
    return "?"
  end
  local tail = s:match("([^-]+)$") or s
  if #s <= 8 then
    return s
  end
  return "T-…" .. tail
end

-- The detail column: what the task is doing, in the fewest words that still
-- distinguish a blocked task from a running one.
function M.detail(task, bucket)
  bucket = bucket or M.bucket(task)
  if bucket == "questions" then
    local pending = #M.pending_questions(task)
    if pending > 0 then
      return pending .. (pending == 1 and " blocked" or " blocked")
    end
    return "awaiting answers"
  end
  if bucket == "failures" then
    return tostring(task.status or "failed")
  end
  if bucket == "review" then
    local review = task.review
    if type(review) == "table" and type(review.round) == "number" then
      return string.format("review %d/%d", review.round, review.max_rounds or 3)
    end
    return tostring(task.status or "reviewing")
  end
  return tostring(task.phase or task.status or "waiting")
end

function M.role_for(task)
  if type(task) ~= "table" then
    return nil
  end
  if type(task.phase) == "string" and PHASE_ROLE[task.phase] then
    return M.role_name(PHASE_ROLE[task.phase])
  end
  return M.role_name(STATUS_ROLE[task.status])
end

-- Normalise the projection to a list. state.tasks is a map, but the tests and
-- a future scheduler may hand us an array; accept both and drop anything that
-- is not a task.
function M.collect(tasks)
  local list = {}
  if type(tasks) ~= "table" then
    return list
  end
  if tasks[1] ~= nil then
    for _, task in ipairs(tasks) do
      if type(task) == "table" and type(task.id) == "string" then
        list[#list + 1] = task
      end
    end
    return list
  end
  local ids = {}
  for id, task in pairs(tasks) do
    if type(task) == "table" and type(task.id) == "string" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    list[#list + 1] = tasks[id]
  end
  return list
end

-- Build the row model the panel navigates. Sorting is deterministic: urgency,
-- then title, then id, so a redraw never reorders rows under the cursor.
--
-- Finished tasks (merged, deployed, abandoned) are hidden by default: they
-- need nothing from the user and only push what does off the panel. Pass
-- `opts.show_done = true` to bring the `done` bucket back.
function M.rows(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local frame = opts.frame or 0
  local show_done = opts.show_done == true
  local rows = {}
  for _, task in ipairs(M.collect(tasks)) do
    local bucket = M.bucket(task)
    if show_done or bucket ~= "done" then
      rows[#rows + 1] = {
        id = task.id,
        short_id = M.short_id(task.id),
        title = task.title or "",
        status = task.status,
        phase = task.phase,
        bucket = bucket,
        urgency = RANK[bucket] or RANK.progress,
        detail = M.detail(task, bucket),
        role = M.role_for(task),
        spinner = M.spinner(frame),
        active = not TERMINAL[task.status],
        waiting = bucket == "progress" and (task.status == "ready" or task.status == "draft"),
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.urgency ~= b.urgency then
      return a.urgency < b.urgency
    end
    if a.title ~= b.title then
      return a.title < b.title
    end
    return a.id < b.id
  end)
  return rows
end

function M.counts(rows)
  local counts = { questions = 0, failures = 0, review = 0, progress = 0, done = 0 }
  for _, row in ipairs(rows or {}) do
    if counts[row.bucket] ~= nil then
      counts[row.bucket] = counts[row.bucket] + 1
    end
  end
  return counts
end

-- The attention bell: one line per non-empty bucket, in urgency order. Empty
-- buckets are omitted so the header stays short.
function M.summary_lines(rows)
  local counts = M.counts(rows)
  local lines = {}
  for _, bucket in ipairs(M.BUCKETS) do
    local n = counts[bucket.key]
    if n > 0 then
      local line = {
        { bucket.mark .. " " .. bucket.label, "bold" },
        { "  " .. n .. (n == 1 and " task" or " tasks"), "dim" },
      }
      if bucket.hint ~= "" then
        line[#line + 1] = { "  " .. bucket.hint, "dim" }
      end
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then
    lines[1] = { { "nothing needs you", "dim" } }
  end
  return lines, counts
end

-- Cut a string to at most `max` display cells, ending with an ellipsis. A long
-- task title must never push the status and the phase off the panel.
local function display_width(s)
  if maki and maki.ui and type(maki.ui.display_width) == "function" then
    local ok, width = pcall(maki.ui.display_width, s)
    if ok and type(width) == "number" then
      return width
    end
  end
  return #s
end

function M.fit(text, max)
  text = tostring(text or "")
  if type(max) ~= "number" or max <= 0 then
    return text
  end
  if display_width(text) <= max then
    return text
  end
  local out = {}
  local used = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i) or 0
    local len = 1
    if byte >= 240 then
      len = 4
    elseif byte >= 224 then
      len = 3
    elseif byte >= 192 then
      len = 2
    end
    local ch = text:sub(i, i + len - 1)
    local width = display_width(ch)
    if used + width > max - 1 then
      break
    end
    out[#out + 1] = ch
    used = used + width
    i = i + len
  end
  return table.concat(out) .. "…"
end

function M.row_line(row, opts)
  opts = type(opts) == "table" and opts or {}
  local role = row.role and ("▸ " .. row.role) or "(waiting)"
  -- The status is always visible: the user asked to read a task's state from
  -- the panel, not only its phase. Quiet mode hides what the agent is doing on
  -- a running task (the phase) behind the spinner, never the status.
  local detail = row.detail
  if opts.quiet and row.bucket == "progress" and row.active then
    detail = row.spinner or M.spinner(0)
  end
  local spans = {
    { row.short_id, "dim" },
    { "  " },
    { M.fit(row.title, opts.title_max or 26) },
    { "  " },
    { tostring(row.status or ""), "keyword" },
  }
  if detail ~= nil and detail ~= "" and tostring(detail) ~= tostring(row.status) then
    spans[#spans + 1] = { "  " }
    spans[#spans + 1] = { detail, "dim" }
  end
  spans[#spans + 1] = { "  " }
  spans[#spans + 1] = { role, "dim" }
  return spans
end

-- The whole panel body: bell header, a spacer, then one line per task.
function M.lines(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local rows = M.rows(tasks, opts)
  local lines, counts = M.summary_lines(rows)
  lines[#lines + 1] = ""
  if #rows == 0 then
    lines[#lines + 1] = { { "(no tasks)", "dim" } }
  else
    for _, row in ipairs(rows) do
      lines[#lines + 1] = M.row_line(row, opts)
    end
  end
  return lines, rows, counts
end

-- Draw into a maki buffer. The buffer is injected so the tests can pass a
-- plain table and the panel can pass a real `maki.ui.buf()`.
function M.render(buf, tasks, opts)
  local lines, rows, counts = M.lines(tasks, opts)
  if buf and type(buf.set_lines) == "function" then
    buf:set_lines(lines)
  end
  return lines, rows, counts
end

-- Flatten a styled line back to text. Tests and logs use it; the UI does not.
function M.text(line)
  if type(line) == "string" then
    return line
  end
  if type(line) ~= "table" then
    return tostring(line)
  end
  local parts = {}
  for _, span in ipairs(line) do
    if type(span) == "string" then
      parts[#parts + 1] = span
    elseif type(span) == "table" then
      parts[#parts + 1] = tostring(span[1] or "")
    end
  end
  return table.concat(parts)
end

return M
