-- Metronome question loop.
--
-- The qualifier raises questions; this module is the loop that turns them into
-- a round a human can actually answer. It de-duplicates the same question
-- asked by several tasks, ranks the ones that unblock other work first, caps
-- the round, and redistributes each answer to every task that asked it.
--
-- Every function returns (value, err) and never raises. The state module is
-- injected, so this file is pure Lua and the loop is testable without a real
-- journal.

local M = {}

local fs = maki.fs

M.MAX_PER_ROUND_DEFAULT = 15

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- dedup_key ----------------------------------------------------------------

-- Two questions are the same question when they read the same once case,
-- whitespace and trailing punctuation are normalised away. "Which AUTH?" and
-- "which auth" must land in the same group, or the user answers it twice.
function M.dedup_key(text)
  if type(text) ~= "string" then
    return ""
  end
  local key = text:lower():gsub("%s+", " ")
  key = key:gsub("^%s+", "")
  key = key:gsub("%s+$", "")
  key = key:gsub("[%?%.!%s]+$", "")
  return key
end

-- collect ------------------------------------------------------------------

-- Walk every task in sorted id order and keep the questions still waiting for
-- an answer. `only_awaiting` is what separates the public collect (a task that
-- is not awaiting answers is not in the round) from the answer path, which
-- must still resolve a question on a task that already moved on.
local function collect_items(state, only_awaiting)
  local items = {}
  if type(state) ~= "table" or type(state.tasks) ~= "table" then
    return items
  end
  for _, task_id in ipairs(sorted_keys(state.tasks)) do
    local task = state.tasks[task_id]
    if type(task) == "table" and (not only_awaiting or task.status == "awaiting_answers") then
      local questions = task.questions
      if type(questions) == "table" then
        for index, question in ipairs(questions) do
          if type(question) == "table"
            and is_non_empty(question.text)
            and not is_non_empty(question.answer) then
            items[#items + 1] = {
              task_id = task_id,
              question_id = tostring(question.id or ("q" .. index)),
              text = question.text,
              index = index,
              created_at = task.created_at or "",
            }
          end
        end
      end
    end
  end
  return items
end

function M.collect(state)
  return collect_items(state, true)
end

-- How many tasks depend on each task. A question asked by a task that unblocks
-- other work is worth asking first.
local function blocker_counts(state)
  local counts = {}
  if type(state) ~= "table" or type(state.tasks) ~= "table" then
    return counts
  end
  for _, task in pairs(state.tasks) do
    local deps = type(task) == "table" and task.depends_on or nil
    if type(deps) == "table" then
      for _, dep in ipairs(deps) do
        if type(dep) == "string" then
          counts[dep] = (counts[dep] or 0) + 1
        end
      end
    end
  end
  return counts
end

-- synthesize ---------------------------------------------------------------

-- Group pending questions by dedup key, rank the groups, and cap the round.
-- The group keeps the first text it saw as canonical, so the user reads the
-- wording of the first task that asked, not an arbitrary one.
function M.synthesize(pending, opts)
  opts = opts or {}
  local blockers = type(opts.blockers) == "table" and opts.blockers or {}

  local groups = {}
  local order = {}
  for _, item in ipairs(type(pending) == "table" and pending or {}) do
    if type(item) == "table" then
      local key = M.dedup_key(item.text)
      local group = groups[key]
      if not group then
        group = {
          text = item.text,
          created_at = item.created_at or "",
          priority = 0,
          sources = {},
        }
        groups[key] = group
        order[#order + 1] = group
      end
      group.sources[#group.sources + 1] = {
        task_id = item.task_id,
        question_id = item.question_id,
      }
      local count = (item.task_id ~= nil and blockers[item.task_id]) or 0
      if count > group.priority then
        group.priority = count
      end
    end
  end

  table.sort(order, function(x, y)
    if x.priority ~= y.priority then
      return x.priority > y.priority
    end
    if x.created_at ~= y.created_at then
      return x.created_at < y.created_at
    end
    local xs, ys = x.sources[1], y.sources[1]
    local xt, yt = tostring(xs.task_id or ""), tostring(ys.task_id or "")
    if xt ~= yt then
      return xt < yt
    end
    return tostring(xs.question_id or "") < tostring(ys.question_id or "")
  end)

  local total = #order
  local max = opts.max_questions or M.MAX_PER_ROUND_DEFAULT
  local kept = {}
  for _, group in ipairs(order) do
    if #kept >= max then
      break
    end
    local first = group.sources[1]
    kept[#kept + 1] = {
      id = tostring(first.task_id or "") .. "/" .. tostring(first.question_id or ""),
      text = group.text,
      sources = group.sources,
      blocking = group.priority > 0,
      priority = group.priority,
    }
  end

  return {
    questions = kept,
    total = total,
    truncated = total - #kept,
  }
end

-- round --------------------------------------------------------------------

-- The round the user is shown: every pending question, deduped and ranked,
-- capped at max_questions.
function M.round(state, root, opts)
  opts = opts or {}
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return nil, "state module is required"
  end
  if type(root) ~= "string" or root == "" then
    return nil, "state root is required"
  end
  local ok, loaded = pcall(state.load, root)
  if not ok or type(loaded) ~= "table" then
    return nil, "cannot load state"
  end
  return M.synthesize(M.collect(loaded), {
    blockers = blocker_counts(loaded),
    max_questions = opts.max_questions or M.MAX_PER_ROUND_DEFAULT,
  })
end

-- answer -------------------------------------------------------------------

-- Answers arrive either as a map { [round_id] = "text" } (what a form posts)
-- or as a list of { id = round_id, answer = "text" } (what a script builds).
-- Both become one list, sorted by id, so the journal is deterministic.
local function normalize_answers(answers)
  if type(answers) ~= "table" then
    return nil, "answers must be a table"
  end
  local list = {}
  if answers[1] ~= nil then
    for i, entry in ipairs(answers) do
      if type(entry) ~= "table" then
        return nil, string.format("answer %d: not an object", i)
      end
      list[#list + 1] = { id = entry.id, answer = entry.answer }
    end
  else
    for _, id in ipairs(sorted_keys(answers)) do
      list[#list + 1] = { id = id, answer = answers[id] }
    end
  end
  return list
end

-- Apply answers to every task that asked the same question, then move each
-- affected task back to qualifying, and rewrite the sheet of every task whose
-- questions changed.
--
-- The whole batch is validated before the first write: a form with one bad
-- answer must not leave half its answers in the journal.
--
-- `opts.qualify` is required: the sheet is rendered by qualify.sheet_markdown
-- only, so a second renderer cannot drift from the sheet apply wrote. A sheet
-- that cannot be written fails the call — an answer applied in the journal but
-- invisible in the sheet is worse than a refused answer, because the
-- implementer reads only the sheet.
function M.answer(state, root, answers, opts)
  opts = opts or {}
  if type(state) ~= "table"
    or type(state.load) ~= "function"
    or type(state.set_fields) ~= "function"
    or type(state.transition) ~= "function" then
    return nil, "state module is required"
  end
  if type(root) ~= "string" or root == "" then
    return nil, "state root is required"
  end
  local qualify = opts.qualify
  if type(qualify) ~= "table" or type(qualify.sheet_markdown) ~= "function" then
    return nil, "answer needs opts.qualify (the sheet renderer)"
  end
  local tasks_dir = opts.tasks_dir or fs.joinpath(root, "tasks")

  local list, lerr = normalize_answers(answers)
  if not list then
    return nil, lerr
  end

  local ok, loaded = pcall(state.load, root)
  if not ok or type(loaded) ~= "table" then
    return nil, "cannot load state"
  end

  -- Build the FULL round, with no cap: a question that was truncated out of
  -- the round the user saw must still resolve. Every task is walked, not just
  -- the ones still awaiting answers, so a remaining question on a task that
  -- already moved to qualifying is answerable too.
  local full = M.synthesize(collect_items(loaded, false), {
    blockers = blocker_counts(loaded),
    max_questions = math.huge,
  })
  local index = {}
  for _, question in ipairs(full.questions) do
    for _, source in ipairs(question.sources) do
      index[tostring(source.task_id) .. "/" .. tostring(source.question_id)] = question
    end
  end

  for i, entry in ipairs(list) do
    local id = entry.id
    if type(id) ~= "string" or trim(id) == "" then
      return nil, string.format("answer %d: id is required", i)
    end
    id = trim(id)
    entry.id = id
    if not index[id] then
      return nil, string.format("answer %d: unknown question id: %s", i, id)
    end
    if not is_non_empty(entry.answer) then
      return nil, string.format("answer %d (%s): answer must be a non-empty string", i, id)
    end
  end

  table.sort(list, function(x, y)
    return x.id < y.id
  end)

  -- One answer per question id per task; a group's sources can name the same
  -- task-question twice when a task repeats a question verbatim.
  local updates = {}
  for _, entry in ipairs(list) do
    local group = index[entry.id]
    for _, source in ipairs(group.sources) do
      local task_id = tostring(source.task_id)
      local question_id = tostring(source.question_id)
      updates[task_id] = updates[task_id] or {}
      updates[task_id][question_id] = entry.answer
    end
  end

  local now = opts.now or now_iso()
  local applied = 0
  local affected = {}
  for _, task_id in ipairs(sorted_keys(updates)) do
    local task = loaded.tasks[task_id]
    if type(task) == "table" then
      local wanted = updates[task_id]
      local updated = {}
      local wrote = 0
      for position, question in ipairs(task.questions or {}) do
        local copy = {}
        if type(question) == "table" then
          for k, v in pairs(question) do
            copy[k] = v
          end
        end
        local question_id = tostring(
          (type(question) == "table" and question.id) or ("q" .. position)
        )
        if copy.id == nil then
          copy.id = question_id
        end
        if wanted[question_id] ~= nil then
          copy.answer = wanted[question_id]
          copy.answered_at = now
          wrote = wrote + 1
        end
        updated[#updated + 1] = copy
      end
      if wrote > 0 then
        local wrote_ok, saved, serr = pcall(state.set_fields, root, task_id, { questions = updated })
        if not wrote_ok then
          return nil, "cannot write questions for " .. task_id .. ": " .. tostring(saved)
        end
        if not saved then
          return nil, serr
        end
        applied = applied + wrote
        affected[#affected + 1] = task_id
      end
    end
  end

  local after_ok, after = pcall(state.load, root)
  if not after_ok or type(after) ~= "table" then
    return nil, "cannot load state"
  end

  local moved = {}
  for _, task_id in ipairs(affected) do
    local current = after.tasks and after.tasks[task_id] or nil
    if type(current) == "table" and current.status == "awaiting_answers" then
      local moved_ok, transitioned, terr = pcall(
        state.transition, root, task_id, "qualifying", { phase = "qualify" }
      )
      if not moved_ok then
        return nil, "cannot move " .. task_id .. " to qualifying: " .. tostring(transitioned)
      end
      if not transitioned then
        return nil, terr
      end
      moved[#moved + 1] = task_id
    end
  end

  -- Rewrite the sheet of every task that received an answer, from the reloaded
  -- projection and through the one renderer. A task whose questions were left
  -- untouched is not rewritten, so its sheet bytes stay identical.
  if #affected > 0 then
    local latest_ok, latest = pcall(state.load, root)
    if not latest_ok or type(latest) ~= "table" then
      return nil, "cannot load state"
    end
    for _, task_id in ipairs(affected) do
      local projected = latest.tasks and latest.tasks[task_id] or nil
      if type(projected) ~= "table" then
        return nil, "cannot write sheet for " .. task_id .. ": task is missing from the projection"
      end
      local rendered, sheet = pcall(qualify.sheet_markdown, projected)
      if not rendered or type(sheet) ~= "string" then
        return nil, "cannot write sheet for " .. task_id .. ": " .. tostring(sheet)
      end
      local write_ok, wrote, werr = pcall(
        fs.write, fs.joinpath(tasks_dir, task_id .. ".md"), sheet
      )
      if not write_ok then
        return nil, "cannot write sheet for " .. task_id .. ": " .. tostring(wrote)
      end
      if not wrote then
        return nil, "cannot write sheet for " .. task_id .. ": " .. tostring(werr)
      end
    end
  end

  return {
    answered = #list,
    applied = applied,
    tasks = moved,
  }
end

return M
