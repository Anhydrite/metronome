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

-- A task held back by the analysis gate stays `qualifying` and carries the
-- persisted `quarantine` record the runtime wrote. Name the rule the sheet
-- broke: that is what the user has to fix. The free-form reason is the
-- fallback (a gate that could not run), and a record with neither still means
-- the task is held for analysis, never that it is quietly waiting.
function M.quarantine_label(task)
  if type(task) ~= "table" or task.status ~= "qualifying" then
    return nil
  end
  local quarantine = task.quarantine
  if type(quarantine) ~= "table" then
    return nil
  end
  local rules = quarantine.rules
  if type(rules) == "table" and type(rules[1]) == "string" and rules[1] ~= "" then
    return rules[1]
  end
  if type(quarantine.reason) == "string" and quarantine.reason ~= "" then
    return quarantine.reason
  end
  return "analysis"
end

-- The detail column: what the task is doing, in the fewest words that still
-- distinguish a blocked task from a running one.
function M.detail(task, bucket)
  local quarantined = M.quarantine_label(task)
  if quarantined then
    return "blocked: " .. quarantined
  end
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
  -- A task with no phase replays as JSON null, which is a userdata in Lua:
  -- only a real string may reach the row.
  if type(task.phase) == "string" and task.phase ~= "" then
    return task.phase
  end
  return tostring(task.status or "waiting")
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

-- The one-cell glyph a request carries in the left column. A running request
-- animates with the same spinner as its tasks, so the index shows work in
-- flight without spelling it out. The word and the style come from
-- `request_status`, so the icon can never disagree with the counts.
local REQUEST_ICON = {
  questions = "?",
  failed = "✗",
  done = "✓",
  partial = "◐",
  ["not started"] = "☐",
  waiting = "…",
  empty = "·",
}

-- The request column is a quarter of the panel, so the state word is short:
-- the icon carries the nuance and the word fits beside the request name.
local REQUEST_WORD = {
  questions = "ask",
  failed = "fail",
  running = "run",
  done = "done",
  partial = "part",
  ["not started"] = "todo",
  waiting = "wait",
  empty = "empty",
}

function M.request_icon(rows, frame)
  local word, style = M.request_status(rows)
  local short = REQUEST_WORD[word] or word
  if word == "running" then
    return M.spinner(frame or 0), "run", short, style
  end
  return REQUEST_ICON[word] or "☐", style, short, style
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

-- The critical path, root to leaf, as a list of ids. A delay on any of these
-- delays the whole request, which is what the panel must make obvious. An
-- empty list means there is no dependency edge at all.
function M.critical_chain(rows)
  local info = M.critical(rows)
  local by_id = {}
  for _, row in ipairs(rows or {}) do
    by_id[row.id] = row
  end
  local last, best = nil, -1
  for id, node in pairs(info) do
    if node.critical and node.ef > best then
      last, best = id, node.ef
    end
  end
  if not last then
    return {}
  end
  local chain = { last }
  local seen = { [last] = true }
  while true do
    local row = by_id[chain[1]]
    local pick, pick_ef = nil, -1
    for _, dep in ipairs(row and row.depends_on_ids or {}) do
      local node = info[dep]
      if node and node.critical and not seen[dep] and node.ef > pick_ef then
        pick, pick_ef = dep, node.ef
      end
    end
    if not pick then
      break
    end
    table.insert(chain, 1, pick)
    seen[pick] = true
  end
  return chain
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
        blocked = #M.pending_questions(task) > 0 or task.status == "awaiting_answers"
          or M.quarantine_label(task) ~= nil,
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
      -- A dependency the panel hides (a finished task) is not drawn as an
      -- extra edge either: the schema only names nodes it actually shows.
      if by_id[dep] and dep ~= parent_of[row.id] then
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

-- PERT schema ---------------------------------------------------------------

-- The four-hex tail of an id, the label a node carries in the graph.
local function node_label(id)
  local s = tostring(id or "")
  local tail = s:match("([0-9a-zA-Z]+)$") or s
  if #tail > 4 then
    tail = tail:sub(-4)
  end
  return tail
end

local TERMINAL_STATUS = { merged = true, deployed = true, abandoned = true }

-- Statuses that are actually moving. A failed or stalled task is active (it can
-- be retried) but nothing is running, so it must not spin.
local MOVING = {
  qualifying = true,
  running = true,
  verifying = true,
  reviewing = true,
  changes_requested = true,
  merging = true,
  deploying = true,
}

-- Draw one request's dependency schema as the indented tree the README
-- describes: one node per line, indented under its first prerequisite with
-- `├─▶`/`└─▶`, carrying the status icon, the short id and the branch. The tree
-- is the schema because it always fits: unlike the retired multi-column
-- canvas it cannot be clipped away by a narrow right column.
--
-- Terminal tasks are drawn too, dimmed, so an edge to an already-merged
-- prerequisite stays visible instead of dropping out of the graph.
--
-- Returns `lines, order, node_line, layer, row_of`: styled lines, the display
-- order of the rows, the 1-based line of each row, its depth, and its 0-based
-- row. `node_line` is what lets the panel keep its cursor on a task.
function M.pert(rows, opts)
  rows = rows or {}
  opts = type(opts) == "table" and opts or {}
  local entries = M.tree(rows)
  local lines, order, node_line, layer, row_of = {}, {}, {}, {}, {}
  for i, entry in ipairs(entries) do
    local row = entry.row
    local done = TERMINAL_STATUS[row.status] == true
    local spans = {}
    spans[#spans + 1] = { entry.prefix or "", "dim" }
    -- A node that is moving carries the spinner, so the schema animates where
    -- work is in flight. A blocked or waiting node gets a distinct glyph; a
    -- finished one stays dim and static.
    local icon, icon_style
    if done then
      icon, icon_style = M.status_icon(row.status), "dim"
    elseif row.blocked then
      icon, icon_style = "?", "run"
    elseif row.waiting then
      icon, icon_style = "☐", "ready"
    elseif row.active and MOVING[row.status] then
      icon, icon_style = row.spinner or M.spinner(opts.frame or 0), "run"
    else
      icon, icon_style = M.status_icon(row.status), M.status_icon_style(row.status)
    end
    spans[#spans + 1] = { icon, icon_style }
    local id_style = done and "dim" or (entry.critical and "run" or "dim")
    spans[#spans + 1] = { M.short_id(row.id), id_style }
    -- The state comes before the title so it stays visible when the column is
    -- narrow: the user reads whether the task is qualifying, implementing,
    -- reviewing, failed or waiting before reading what it is about.
    local state_text = row.detail or row.status
    if type(state_text) == "string" and state_text ~= "" then
      local state_style = done and "dim" or M.status_icon_style(row.status)
      spans[#spans + 1] = { "  " .. M.fit(state_text, opts.state_max or 16), state_style }
    end
    if type(row.title) == "string" and row.title ~= "" then
      spans[#spans + 1] = { "  " .. M.fit(row.title, opts.title_max or 22), "dim" }
    end
    if type(row.branch) == "string" and row.branch ~= "" then
      local branch = row.branch:gsub("^metronome/", "")
      spans[#spans + 1] = { "  ⎇ " .. M.fit(branch, opts.branch_max or 20), "dim" }
    end
    if entry.extra_deps then
      spans[#spans + 1] = { "  ← " .. entry.extra_deps, "dim" }
    end
    -- The selected task is the panel's only selector: the whole node turns
    -- bold (the theme's highlight) instead of a second cursor line.
    if opts.selected_id ~= nil and row.id == opts.selected_id then
      for _, span in ipairs(spans) do
        span[2] = "bold"
      end
    end
    if type(opts.right_width) == "number" and opts.right_width > 0 then
      spans = M.fit_spans(spans, opts.right_width)
    end
    lines[#lines + 1] = spans
    order[#order + 1] = row
    node_line[row.id] = i
    layer[row.id] = entry.depth or 0
    row_of[row.id] = i - 1
  end
  return lines, order, node_line, layer, row_of
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
  }
end

-- The request's counts, on their own line under the intention. A long
-- intention must never push the counts off the panel, so they do not share
-- its line.
function M.intent_counts_line(group, total)
  local shown = #group.rows
  total = type(total) == "number" and total or shown
  local count = total .. (total == 1 and " task" or " tasks")
  if shown < total then
    count = count .. " (" .. shown .. " shown)"
  end
  local c = M.group_counts(group.rows)
  return {
    { "  " .. count, "dim" },
    { "  " .. string.format("✓%d ▶%d ✗%d ☐%d", c.done, c.running, c.failed, c.todo), "dim" },
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

-- The four counts a request line carries: finished, in flight, failed, and
-- not started. One classification, used by the request word and by the icons
-- so the two can never disagree.
function M.group_counts(rows)
  local c = { total = 0, done = 0, running = 0, failed = 0, todo = 0, blocked = 0 }
  for _, row in ipairs(rows or {}) do
    c.total = c.total + 1
    if row.blocked then
      c.blocked = c.blocked + 1
    end
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

-- The one word a request carries in the left column: is it running, failed,
-- finished, or not started yet? A request is a group of tasks, so the word
-- summarises the group by what needs the human first: a failure outranks
-- progress, progress outranks a finished task, and only a request where
-- nothing has started reads "not started".
function M.request_status(rows)
  local c = M.group_counts(rows)
  if c.total == 0 then
    return "empty", "dim"
  end
  if c.blocked > 0 then
    return "questions", "run"
  end
  if c.failed > 0 then
    return "failed", "bad"
  end
  if c.running > 0 then
    return "running", "keyword"
  end
  if c.done == c.total then
    return "done", "ok"
  end
  if c.done > 0 then
    return "partial", "dim"
  end
  if c.todo > 0 then
    return "not started", "dim"
  end
  return "waiting", "dim"
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

-- The display width of a string, in terminal cells. Exposed so a test can
-- assert that a rendered line fits the column it was given.
function M.width_of(text)
  return display_width(tostring(text or ""))
end

-- Clip a styled line to `max` display cells. The panel's right column is a
-- fixed width, so a long status, role or branch must be cut here rather than
-- spill over the window border.
function M.fit_spans(spans, max)
  if type(max) ~= "number" or max <= 0 then
    return spans
  end
  local total = 0
  for _, span in ipairs(spans or {}) do
    total = total + display_width(tostring(span[1] or ""))
  end
  if total <= max then
    return spans
  end
  local out = {}
  local used = 0
  for _, span in ipairs(spans or {}) do
    local text = tostring(span[1] or "")
    local w = display_width(text)
    if used + w > max - 1 then
      local room = max - 1 - used
      if room > 0 then
        -- `M.fit` already ends a cut string with an ellipsis.
        out[#out + 1] = { M.fit(text, room), span[2] }
      else
        out[#out + 1] = { "…", "dim" }
      end
      return out
    end
    out[#out + 1] = span
    used = used + w
  end
  return out
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
        lines[#lines + 1] = M.intent_counts_line(group, total[group.intent])
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
  -- The panel shows what still needs a human. Finished tasks are dropped from
  -- the request index and the schema, while failures, in-flight and waiting
  -- tasks stay. A caller that wants the finished ones back passes
  -- `show_done = true`; the live panel does not.
  local all = M.rows(tasks, opts)
  local groups = M.groups(all)
  local counts = M.counts(all)

  local selected = tonumber(opts.selected_intent) or 1
  if selected < 1 then
    selected = 1
  end
  if selected > #groups then
    selected = #groups
  end

  local left_width = tonumber(opts.left_width) or 40

  -- Left column: one request per line, with its status icon. The request
  -- itself is the index and the selector. The selected request is bold; the
  -- PERT node is only bold when the user explicitly clicked a task.
  local left = {}
  for i, group in ipairs(groups) do
    local marker = i == selected and "▸ " or "  "
    local label = group.intent ~= "" and group.intent or "(no intention)"
    local icon, icon_style, word, word_style = M.request_icon(group.rows, opts.frame)
    local word_text = tostring(word or "")
    local label_max = left_width - 4 - M.width_of(word_text) - 1
    if label_max < 1 then
      label_max = 1
    end
    left[#left + 1] = {
      spans = {
        { marker, i == selected and "bold" or "dim" },
        { icon .. " ", icon_style },
        { word_text .. " ", word_style },
        { M.fit(label, label_max), i == selected and "bold" or "dim" },
      },
    }
  end

  -- Right column: the selected request's PERT schema, nothing else.
  local right = {}
  local rows = {}
  local row_lines = {}
  if #groups == 0 then
    right[#right + 1] = { spans = { { "(no tasks)", "dim" } } }
  else
    local group = groups[selected]
    -- The cursor model is the active tasks of this request, in schema order.
    local active = M.rows(tasks, opts)
    local group_active = {}
    for _, row in ipairs(active) do
      if row.intent == group.intent then
        group_active[#group_active + 1] = row
      end
    end
    -- The request is the selector: no node is highlighted until the user
    -- clicks one, which is the only way to target a task explicitly.
    local selected_id = nil
    if opts.show_task_selection then
      local selected_row = tonumber(opts.selected_row) or 1
      if selected_row < 1 or selected_row > #group_active then
        selected_row = 1
      end
      selected_id = group_active[selected_row] and group_active[selected_row].id or nil
    end
    local pert_lines, _, node_line = M.pert(group.rows, {
      frame = opts.frame,
      title_max = opts.title_max,
      branch_max = opts.branch_max,
      right_width = opts.right_width,
      selected_id = selected_id,
    })
    right[#right + 1] = { spans = { { "PERT", "bold" } } }
    for _, spans in ipairs(pert_lines) do
      right[#right + 1] = { spans = spans }
    end
    -- Each task row maps to the schema line where its node sits, so a click on
    -- a node can target that task and the actions know what it points at.
    for _, row in ipairs(group_active) do
      if node_line[row.id] then
        rows[#rows + 1] = row
        row_lines[#row_lines + 1] = node_line[row.id] + 1
      end
    end
  end

  -- Join the two columns with the separator. Every line is clipped to its
  -- column so the window border never eats a character.
  local lines = {}
  local height = math.max(#left, #right)
  for i = 1, height do
    local l = left[i]
    local ltext = l and M.text(l.spans) or ""
    local fitted = M.fit(ltext, left_width)
    local pad = left_width - display_width(fitted)
    if pad < 0 then
      pad = 0
    end
    local spans = {}
    if l then
      for _, span in ipairs(l.spans) do
        spans[#spans + 1] = span
      end
      spans[#spans + 1] = { string.rep(" ", pad), "dim" }
    else
      spans[#spans + 1] = { string.rep(" ", left_width), "dim" }
    end
    spans[#spans + 1] = { " │ ", "dim" }
    local r = right[i]
    if r then
      local rspans = r.spans
      if type(opts.right_width) == "number" and opts.right_width > 0 then
        rspans = M.fit_spans(rspans, opts.right_width)
      end
      for _, span in ipairs(rspans) do
        spans[#spans + 1] = span
      end
    end
    lines[#lines + 1] = spans
  end

  return lines, rows, counts, row_lines, groups, selected
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
