-- Pipeline scheduler for Metronome.
--
-- This module owns the global state machine's timing questions, not the steps
-- themselves: which tasks may start now, which must wait, which have stopped
-- making progress, and which were interrupted by a reload. The step functions
-- are injected (`dispatch`), so the scheduler is pure Lua and testable without
-- a model, a repository or a running session.
--
-- Three rules from the plan:
--   * dependencies: a task starts only once every `depends_on` task is merged
--     (or deployed);
--   * max_parallel: never more than the configured number of tasks in flight;
--   * runs alone: a task that declares no files has an unknown blast radius,
--     so it starts only when nothing else is in flight or selected.
--
-- Overlapping declared files are legal: each task works in its own branch and
-- worktree, so two tasks may touch the same file in parallel and any conflict
-- is resolved at merge time.
--
-- Stall detection is time-based, not poll-based: `stall()` compares each active
-- task's last progress with `stall_minutes`. `mark_stalled()` turns a stalled
-- `running` task into the `stalled` status (a legal transition) and flags the
-- others suspect, because their status has no `stalled` edge.

local M = {}

local ACTIVE = {
  running = true,
  verifying = true,
  reviewing = true,
  merging = true,
  deploying = true,
}

local DONE = {
  merged = true,
  deployed = true,
}

local DEAD = {
  failed = true,
  abandoned = true,
}

-- How a resumed task gets back to `running`, using only legal transitions.
-- `running` is already there and stays; the path is a no-op status event.
local RESUME_PHASE = {
  running = "implement",
  stalled = "implement",
  verifying = "verify",
  reviewing = "review",
  merging = "merge",
  deploying = "deploy",
}

local RESUME_PATH = {
  running = { "running" },
  stalled = { "running" },
  verifying = { "running" },
  reviewing = { "changes_requested", "running" },
  merging = { "failed", "running" },
  deploying = { "failed", "running" },
}

-- Helpers -------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

-- Normalise the projection to a list. state.tasks is a map; accept an array
-- too and drop anything that is not a task.
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

-- Parse an ISO-8601 UTC timestamp to a Unix epoch. The host's `os.time`
-- interprets a table as local time, so the UTC offset is added back.
function M.parse_iso(s)
  local y, mo, d, h, mi, se = tostring(s or ""):match(
    "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
  )
  if not y then
    return nil
  end
  local fields = {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(se),
    isdst = false,
  }
  local offset = os.difftime(os.time(), os.time(os.date("!*t")))
  return os.time(fields) + offset
end

-- Dependencies --------------------------------------------------------------

-- Is every dependency of `task` done? Returns true, or false and a reason.
-- A missing dependency is not done: silently starting would run against a task
-- that was never created.
function M.dependencies_met(task, tasks)
  if type(task) ~= "table" or type(task.depends_on) ~= "table" then
    return true
  end
  local by_id = {}
  for _, other in ipairs(M.collect(tasks)) do
    by_id[other.id] = other
  end
  for _, dep_id in ipairs(task.depends_on) do
    local dep = by_id[dep_id]
    if not dep then
      return false, "missing dependency: " .. tostring(dep_id)
    end
    if DEAD[dep.status] then
      return false, "blocked by " .. tostring(dep_id) .. " (" .. tostring(dep.status) .. ")"
    end
    if not DONE[dep.status] then
      return false, "waiting on " .. tostring(dep_id) .. " (" .. tostring(dep.status) .. ")"
    end
  end
  return true
end

-- Scheduling ----------------------------------------------------------------

-- Pick the tasks to start now. `running` is the tasks already in flight (a
-- list or a map). Returns `started, skipped`; every skipped task carries a
-- reason, so the panel and the logs can say why it waited.
function M.schedule(tasks, running, opts)
  opts = type(opts) == "table" and opts or {}
  local max_parallel = tonumber(opts.max_parallel) or 2
  if max_parallel < 1 then
    max_parallel = 1
  end

  local in_flight = M.collect(running)
  local selected = {}
  local skipped = {}

  local candidates = {}
  for _, task in ipairs(M.collect(tasks)) do
    if task.status == "ready" then
      candidates[#candidates + 1] = task
    end
  end
  -- Declared-file candidates are considered first so the runs-alone rule holds
  -- in both directions: an undeclared task is examined only once every task
  -- that names its blast radius had its chance to be selected.
  table.sort(candidates, function(a, b)
    local a_declared = type(a.files) == "table" and #a.files > 0
    local b_declared = type(b.files) == "table" and #b.files > 0
    if a_declared ~= b_declared then
      return a_declared
    end
    return a.id < b.id
  end)

  for _, task in ipairs(candidates) do
    local met, reason = M.dependencies_met(task, tasks)
    if not met then
      skipped[#skipped + 1] = { id = task.id, reason = reason }
    elseif #in_flight + #selected >= max_parallel then
      skipped[#skipped + 1] = { id = task.id, reason = "max_parallel reached" }
    else
      local files = type(task.files) == "table" and task.files or {}
      -- A task that declares no files has an unknown blast radius: it could
      -- touch anything, so it runs alone. It still starts on an empty
      -- pipeline; naming a file in the intention buys the parallelism back.
      if #files == 0 and (#in_flight + #selected > 0) then
        skipped[#skipped + 1] = {
          id = task.id,
          reason = "no declared files: runs alone (name a file to run it in parallel)",
        }
      else
        selected[#selected + 1] = task
      end
    end
  end

  return selected, skipped
end

-- Stall detection -----------------------------------------------------------

-- Active tasks whose last progress is older than `stall_minutes`. `now` is a
-- Unix epoch; `now_iso` is accepted for a caller holding a timestamp. The
-- result is sorted by id so a redraw is deterministic.
function M.stall(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local minutes = tonumber(opts.stall_minutes) or 20
  local now = tonumber(opts.now)
  if not now then
    now = M.parse_iso(opts.now_iso) or os.time()
  end
  local limit = minutes * 60

  local stale = {}
  for _, task in ipairs(M.collect(tasks)) do
    if ACTIVE[task.status] then
      local last_iso = type(task.stall) == "table" and task.stall.last_progress_at or nil
      last_iso = last_iso or task.updated_at or task.created_at
      local last = M.parse_iso(last_iso)
      if last and now - last > limit then
        stale[#stale + 1] = {
          id = task.id,
          status = task.status,
          idle_secs = now - last,
          last_progress_at = last_iso,
        }
      end
    end
  end
  table.sort(stale, function(a, b)
    return a.id < b.id
  end)
  return stale
end

-- Apply the stall verdict. `running` has a legal `stalled` edge, so it moves;
-- the other active statuses have none, so they are flagged suspect instead of
-- being forced through an illegal transition.
function M.mark_stalled(state, root, opts)
  opts = type(opts) == "table" and opts or {}
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return nil, "state module is required"
  end
  if not is_non_empty(root) then
    return nil, "state root is required"
  end

  local loaded, err = state.load(root)
  if not loaded then
    return nil, err or "cannot load state"
  end

  local stale = M.stall(loaded.tasks, opts)
  if opts.apply == false then
    return stale
  end

  local applied = {}
  for _, item in ipairs(stale) do
    if item.status == "running" then
      local moved, merr = state.transition(root, item.id, "stalled")
      if moved then
        applied[#applied + 1] = item
      else
        applied[#applied + 1] = { id = item.id, error = merr }
      end
    else
      local updated, uerr = state.set_fields(root, item.id, {
        stall = { last_progress_at = item.last_progress_at, suspect = true },
      })
      if updated then
        applied[#applied + 1] = item
      else
        applied[#applied + 1] = { id = item.id, error = uerr }
      end
    end
  end
  return applied
end

-- Resume after reload -------------------------------------------------------

-- Find the tasks a reload interrupted and, unless `apply = false`, walk each
-- back to `running` through legal transitions. `dispatch` is called for every
-- resumed task with `(task, phase)`.
function M.resume(state, root, opts)
  opts = type(opts) == "table" and opts or {}
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return nil, "state module is required"
  end
  if not is_non_empty(root) then
    return nil, "state root is required"
  end

  local loaded, err = state.load(root)
  if not loaded then
    return nil, err or "cannot load state"
  end

  local entries = {}
  for _, task in ipairs(M.collect(loaded.tasks)) do
    local phase = RESUME_PHASE[task.status]
    if phase then
      entries[#entries + 1] = {
        id = task.id,
        from = task.status,
        phase = phase,
        path = RESUME_PATH[task.status],
        task = task,
      }
    end
  end

  local errors = {}
  if opts.apply ~= false then
    for _, entry in ipairs(entries) do
      local moved = true
      for _, to in ipairs(entry.path) do
        local ok, merr = state.transition(root, entry.id, to, { phase = entry.phase })
        if not ok then
          moved = false
          errors[#errors + 1] = { id = entry.id, error = merr }
          break
        end
      end
      entry.applied = moved
      if moved and type(opts.dispatch) == "function" then
        local current = state.load(root)
        local task = current and current.tasks and current.tasks[entry.id] or entry.task
        pcall(opts.dispatch, task, entry.phase)
      end
    end
  end

  return { resumed = entries, errors = errors }
end

-- One scheduling tick -------------------------------------------------------

-- Load the state, mark stalls, then start what may start. With `apply = false`
-- it only reports the decision, which is what the tests and a dry run use.
function M.tick(opts)
  opts = type(opts) == "table" and opts or {}
  local state = opts.state
  local root = opts.root
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return { ok = false, error = "state module is required" }
  end
  if not is_non_empty(root) then
    return { ok = false, error = "state root is required" }
  end

  local loaded, err = state.load(root)
  if not loaded then
    return { ok = false, error = err or "cannot load state" }
  end

  local stalled = {}
  if opts.stall ~= false then
    local applied, serr = M.mark_stalled(state, root, {
      now = opts.now,
      now_iso = opts.now_iso,
      stall_minutes = opts.stall_minutes,
      apply = opts.apply,
    })
    if not applied then
      return { ok = false, error = serr }
    end
    stalled = applied
    if opts.apply ~= false then
      loaded = state.load(root) or loaded
    end
  end

  local running = {}
  for _, task in ipairs(M.collect(loaded.tasks)) do
    if ACTIVE[task.status] then
      running[#running + 1] = task
    end
  end

  local started, skipped = M.schedule(loaded.tasks, running, {
    max_parallel = opts.max_parallel,
  })

  if opts.apply ~= false then
    for _, task in ipairs(started) do
      local moved, merr = state.transition(root, task.id, "running", { phase = "implement" })
      if not moved then
        skipped[#skipped + 1] = { id = task.id, reason = merr }
      elseif type(opts.dispatch) == "function" then
        pcall(opts.dispatch, moved, "implement")
      end
    end
  end

  return {
    ok = true,
    started = started,
    skipped = skipped,
    stalled = stalled,
    running = running,
  }
end

-- The production entry point: a tick that applies its decisions.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local copy = {}
  for key, value in pairs(opts) do
    copy[key] = value
  end
  copy.apply = true
  return M.tick(copy)
end

return M
