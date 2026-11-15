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

-- A dependency is usually a task id, but an older sheet may still carry the
-- title the qualifier wrote. Shorten an id, keep a title readable, and drop
-- anything empty.
local function short_dep(dep)
  local s = tostring(dep or "")
  if s == "" then
    return nil
  end
  if s:match("^T%-") then
    return M.short_id(s)
  end
  return s
end

function M.short_deps(deps)
  if type(deps) ~= "table" then
    return nil
  end
  local out = {}
  for _, dep in ipairs(deps) do
    local short = short_dep(dep)
    if short then
      out[#out + 1] = short
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, ",")
end

-- The one-cell status glyph a row and a PERT node carry.
local STATUS_ICON = {
  merged = "✓", deployed = "✓",
  running = "▶", verifying = "▶", reviewing = "▶",
  merging = "▶", deploying = "▶", changes_requested = "▶",
  failed = "✗", stalled = "✗", abandoned = "✗",
}

function M.status_icon(status)
  return STATUS_ICON[status] or "☐"
end

function M.status_icon_style(status)
  if status == "failed" or status == "stalled" or status == "abandoned" then
    return "bad"
  end
  if status == "merged" or status == "deployed" then
    return "ok"
  end
  if STATUS_ICON[status] == "▶" then
    return "run"
  end
  return "ready"
end

-- Earliest/latest start and finish for every task of one intention, plus the
-- slack. A task is on the critical path when its slack is zero: any delay to
-- it delays the whole request. Durations are unit unless `row.estimate` is a
-- positive number. A cycle leaves the unreached tasks without info, and the
-- caller draws them flat.
function M.critical(rows)
  local by_id, deps, succ = {}, {}, {}
  for _, row in ipairs(rows or {}) do
    by_id[row.id] = row
    deps[row.id] = {}
    succ[row.id] = {}
  end
  for _, row in ipairs(rows or {}) do
    for _, dep in ipairs(row.depends_on_ids or {}) do
      if by_id[dep] and dep ~= row.id then
        deps[row.id][#deps[row.id] + 1] = dep
        succ[dep][#succ[dep] + 1] = row.id
      end
    end
  end

  local indeg, queue = {}, {}
  for id in pairs(by_id) do
    indeg[id] = #deps[id]
    if indeg[id] == 0 then
      queue[#queue + 1] = id
    end
  end
  table.sort(queue)
  local order = {}
  while #queue > 0 do
    local id = table.remove(queue, 1)
    order[#order + 1] = id
    for _, s in ipairs(succ[id]) do
      indeg[s] = indeg[s] - 1
      if indeg[s] == 0 then
        queue[#queue + 1] = s
      end
    end
  end

  local duration_of = function(row)
    local n = tonumber(row and row.estimate)
    if n and n > 0 then
      return n
    end
    return 1
  end

  local info = {}
  local total = 0
  for _, id in ipairs(order) do
    local es = 0
    for _, dep in ipairs(deps[id]) do
      if info[dep] then
        es = math.max(es, info[dep].ef)
      end
    end
    local ef = es + duration_of(by_id[id])
    info[id] = { es = es, ef = ef }
    if ef > total then
      total = ef
    end
  end
  for i = #order, 1, -1 do
    local id = order[i]
    local lf = total
    for _, s in ipairs(succ[id]) do
      if info[s] then
        lf = math.min(lf, info[s].ls)
      end
    end
    info[id].lf = lf
    info[id].ls = lf - duration_of(by_id[id])
    info[id].slack = info[id].ls - info[id].es
    info[id].critical = info[id].slack == 0
  end
  return info
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
-- The request a task belongs to. A submission is identified by the intention
-- the user typed (`origin`), not by the qualifier's per-task detail (`intent`):
-- one ask split into eight tasks must stay one request in the panel. Tasks
-- created before `origin` existed fall back to `intent`.
function M.request_of(task)
  if type(task) ~= "table" then
    return ""
  end
  if type(task.origin) == "string" and task.origin ~= "" then
    return task.origin
  end
  return type(task.intent) == "string" and task.intent or ""
end

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
        intent = M.request_of(task),
        depends_on = M.short_deps(task.depends_on),
        depends_on_ids = type(task.depends_on) == "table" and task.depends_on or {},
        branch = type(task.branch) == "string" and task.branch ~= "" and task.branch or nil,
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

-- Group rows by the intention they came from. The user asked one thing; the
-- qualifier may have split it into several tasks, and the panel must show that
-- relationship instead of a flat list. Groups are ordered by their most urgent
-- row, so a blocked task still pulls its whole intention to the top. Rows keep
-- their urgency order inside a group.
function M.groups(rows)
  local order = {}
  local by_intent = {}
  for _, row in ipairs(rows or {}) do
    local intent = row.intent or ""
    local group = by_intent[intent]
    if not group then
      group = { intent = intent, rows = {}, urgency = row.urgency }
      by_intent[intent] = group
      order[#order + 1] = group
    end
    group.rows[#group.rows + 1] = row
    if row.urgency < group.urgency then
      group.urgency = row.urgency
    end
  end
  table.sort(order, function(a, b)
    if a.urgency ~= b.urgency then
      return a.urgency < b.urgency
    end
    return a.intent < b.intent
  end)
  return order
end

-- A dependency tree for one intention's rows. A task is drawn under the first
-- of its dependencies that is present in the group; any other dependency is
-- kept as an extra edge on the row. Roots (no dependency in the group) start at
-- the left margin. The result is the schema the panel shows: indentation and
-- `├─▶`/`└─▶` say who waits for whom, in the order the work will run.
--
-- Returns a list of `{ row, prefix, depth, extra_deps }` in display order.
-- `seen` guards a malformed graph: a cycle must not hang the panel.
function M.tree(rows)
  local by_id = {}
  for _, row in ipairs(rows or {}) do
    by_id[row.id] = row
  end
  local crit = M.critical(rows)

  local children = {}
  local parent_of = {}
  for _, row in ipairs(rows or {}) do
    for _, dep in ipairs(row.depends_on_ids or {}) do
      if by_id[dep] and dep ~= row.id then
        parent_of[row.id] = dep
        children[dep] = children[dep] or {}
        children[dep][#children[dep] + 1] = row
        break
      end
    end
  end

  local function order(a, b)
    if a.urgency ~= b.urgency then
      return a.urgency < b.urgency
    end
    if a.title ~= b.title then
      return a.title < b.title
    end
    return a.id < b.id
  end
  for _, list in pairs(children) do
    table.sort(list, order)
  end

  local roots = {}
  for _, row in ipairs(rows or {}) do
    if not parent_of[row.id] then
      roots[#roots + 1] = row
    end
  end
  table.sort(roots, order)

  local out = {}
  local seen = {}
  local function walk(row, line_prefix, child_prefix, depth)
    if seen[row.id] then
      return
    end
    seen[row.id] = true
    local extra = {}
    for _, dep in ipairs(row.depends_on_ids or {}) do
      if dep ~= parent_of[row.id] then
        local short = short_dep(dep)
        if short then
          extra[#extra + 1] = short
        end
      end
    end
    out[#out + 1] = {
      row = row,
      prefix = line_prefix,
      depth = depth,
      extra_deps = #extra > 0 and table.concat(extra, ",") or nil,
      icon = M.status_icon(row.status),
      critical = crit[row.id] and crit[row.id].critical or false,
    }
    local kids = children[row.id] or {}
    for i, kid in ipairs(kids) do
      local last = i == #kids
      local branch = last and "└─▶ " or "├─▶ "
      local next_child = child_prefix .. (last and "   " or "│  ")
      walk(kid, child_prefix .. branch, next_child, depth + 1)
    end
  end
  for _, root in ipairs(roots) do
    walk(root, "", "", 0)
  end
  -- A cycle leaves rows unreached; draw them flat rather than hide them.
  for _, row in ipairs(rows or {}) do
    if not seen[row.id] then
      walk(row, "", "", 0)
    end
  end
  return out
end
function M.intent_line(group, opts, total)
  opts = type(opts) == "table" and opts or {}
  local text = M.fit(group.intent, opts.intent_max or 70)
  local shown = #group.rows
  total = type(total) == "number" and total or shown
  local count = total .. (total == 1 and " task" or " tasks")
  if shown < total then
    count = count .. " (" .. shown .. " shown)"
  end
  return {
    { "▸ ", "dim" },
    { '"' .. text .. '"', "bold" },
    { "  " .. count, "dim" },
  }
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
  local spans = {}
  if row.prefix and row.prefix ~= "" then
    spans[#spans + 1] = { row.prefix, "dim" }
  end
  local icon = row.icon or M.status_icon(row.status)
  spans[#spans + 1] = { icon, M.status_icon_style(row.status) }
  spans[#spans + 1] = { row.short_id, row.critical and "run" or "dim" }
  spans[#spans + 1] = { "  " }
  spans[#spans + 1] = { M.fit(row.title, opts.title_max or 26) }
  spans[#spans + 1] = { "  " }
  spans[#spans + 1] = { tostring(row.status or ""), "keyword" }
  if detail ~= nil and detail ~= "" and tostring(detail) ~= tostring(row.status) then
    spans[#spans + 1] = { "  " }
    spans[#spans + 1] = { detail, "dim" }
  end
  spans[#spans + 1] = { "  " }
  spans[#spans + 1] = { role, "dim" }
  if row.extra_deps then
    -- The tree already draws the primary dependency; this is the other edge a
    -- task also waits on.
    spans[#spans + 1] = { "  ← " .. row.extra_deps, "dim" }
  end
  if row.branch then
    -- The branch is what a human checks out; the `metronome/` prefix is noise
    -- the panel can drop, and a long slug is cut so it cannot push the row.
    local branch = row.branch:gsub("^metronome/", "")
    spans[#spans + 1] = { "  ⎇ " .. M.fit(branch, opts.branch_max or 28), "dim" }
  end
  return spans
end

-- The whole panel body: bell header, a spacer, then the tasks grouped by the
-- intention that produced them. A group with an intention gets a header line
-- naming the ask and the number of tasks it produced; a group without one
-- (older tasks) is rendered flat, as before.
--
-- Returns `lines, rows, counts, row_lines`: `rows` is in display order and
-- `row_lines[i]` is the buffer line of the i-th row, so the panel's cursor and
-- its highlight stay on the same task even with group headers interleaved.
function M.lines(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local rows = M.rows(tasks, opts)
  local lines, counts = M.summary_lines(rows)
  lines[#lines + 1] = ""

  -- Count every task per intention, including the finished ones the panel
  -- hides, so the header shows the real size of the split.
  local total = {}
  for _, task in ipairs(M.collect(tasks)) do
    local intent = M.request_of(task)
    total[intent] = (total[intent] or 0) + 1
  end

  local display = {}
  local row_lines = {}
  if #rows == 0 then
    lines[#lines + 1] = { { "(no tasks)", "dim" } }
  else
    for _, group in ipairs(M.groups(rows)) do
      if group.intent ~= "" then
        lines[#lines + 1] = M.intent_line(group, opts, total[group.intent])
      end
      for _, entry in ipairs(M.tree(group.rows)) do
        local row = entry.row
        row.prefix = entry.prefix
        row.extra_deps = entry.extra_deps
        lines[#lines + 1] = M.row_line(row, opts)
        display[#display + 1] = row
        row_lines[#display] = #lines
      end
    end
  end
  return lines, display, counts, row_lines
end

-- A short state summary for an intention, used in the left column.
function M.intent_summary(group)
  local counts = M.counts(group and group.rows or {})
  local parts = {}
  if counts.questions > 0 then parts[#parts + 1] = counts.questions .. " blocked" end
  if counts.failures > 0 then parts[#parts + 1] = counts.failures .. " failed" end
  if counts.review > 0 then parts[#parts + 1] = counts.review .. " review" end
  if counts.progress > 0 then parts[#parts + 1] = counts.progress .. " progress" end
  if #parts == 0 then
    return "nothing to do"
  end
  return table.concat(parts, " · ")
end

-- Two columns: the requests on the left, the detail of the selected one on the
-- right. The left is an index of intentions with their state; the right is the
-- schema of the selected intention: its dependency tree, each task with its
-- status and progress. `opts.selected_intent` picks the detail (1-based).
--
-- Returns `lines, rows, counts, row_lines, groups, selected`. `rows` are the
-- selected intention's tasks in display order, so the panel's cursor and its
-- actions keep working on a task. `row_lines[i]` is the buffer line of row i.
function M.panes(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local rows = M.rows(tasks, opts)
  local groups = M.groups(rows)
  local counts = M.counts(rows)

  local total = {}
  for _, task in ipairs(M.collect(tasks)) do
    local intent = M.request_of(task)
    total[intent] = (total[intent] or 0) + 1
  end

  local selected = tonumber(opts.selected_intent) or 1
  if selected < 1 then selected = 1 end
  if selected > #groups then selected = #groups end

  local left_width = tonumber(opts.left_width) or 40

  -- Left column: one compact line per intention, with the four status icons.
  local function status_counts(group)
    local c = { done = 0, running = 0, failed = 0, todo = 0 }
    for _, row in ipairs(group.rows or {}) do
      local s = row.status
      if s == "merged" or s == "deployed" then
        c.done = c.done + 1
      elseif s == "failed" or s == "stalled" or s == "abandoned" then
        c.failed = c.failed + 1
      elseif s == "running" or s == "verifying" or s == "reviewing"
        or s == "merging" or s == "deploying" or s == "changes_requested" then
        c.running = c.running + 1
      else
        c.todo = c.todo + 1
      end
    end
    return c
  end

  local left = {}
  left[#left + 1] = { text = "REQUESTS", style = "bold" }
  for i, group in ipairs(groups) do
    local c = status_counts(group)
    local marker = i == selected and "▸ " or "  "
    local label = group.intent ~= "" and ('"' .. group.intent .. '"') or "(no intention)"
    local icons = string.format("✓%d ▶%d ✗%d ☐%d", c.done, c.running, c.failed, c.todo)
    left[#left + 1] = {
      text = marker .. M.fit(label, left_width - 17) .. "  " .. icons,
      style = i == selected and "bold" or "dim",
    }
  end

  -- Right column: the selected intention's schema.
  local right = {}
  if #groups == 0 then
    right[#right + 1] = { spans = { { "(no tasks)", "dim" } } }
  else
    local group = groups[selected]
    if group.intent ~= "" then
      right[#right + 1] = { spans = M.intent_line(group, opts, total[group.intent]) }
    end
    for _, entry in ipairs(M.tree(group.rows)) do
      local row = entry.row
      row.prefix = entry.prefix
      row.extra_deps = entry.extra_deps
      row.icon = entry.icon
      row.critical = entry.critical
      right[#right + 1] = { spans = M.row_line(row, opts), row = row }
    end
  end

  local lines = {}
  for _, line in ipairs((M.summary_lines(rows))) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ""

  local display = {}
  local row_lines = {}
  local height = math.max(#left, #right)
  for i = 1, height do
    local l = left[i]
    local ltext = l and l.text or ""
    local lstyle = l and l.style or "dim"
    local fitted = M.fit(ltext, left_width)
    local pad = left_width - display_width(fitted)
    if pad < 0 then pad = 0 end
    local spans = {
      { fitted .. string.rep(" ", pad), lstyle },
      { " │ ", "dim" },
    }
    local r = right[i]
    if r then
      for _, span in ipairs(r.spans) do
        spans[#spans + 1] = span
      end
    end
    lines[#lines + 1] = spans
    if r and r.row then
      display[#display + 1] = r.row
      row_lines[#display] = #lines
    end
  end

  return lines, display, counts, row_lines, groups, selected
end

-- Draw into a maki buffer. The buffer is injected so the tests can pass a
-- plain table and the panel can pass a real `maki.ui.buf()`.
function M.render(buf, tasks, opts)
  local lines, rows, counts, row_lines = M.lines(tasks, opts)
  if buf and type(buf.set_lines) == "function" then
    buf:set_lines(lines)
  end
  return lines, rows, counts, row_lines
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
