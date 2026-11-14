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
--   * file overlap: two tasks that declare a common file never run at the same
--     time, even when `max_parallel` would allow it;
--   * max_parallel: never more than the configured number of tasks in flight.
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

-- `merged` is a completed state for scheduling: the work the scheduler hands
-- out is over, and the deploy a merge still owes is drained separately by the
-- deployer. A dependent may start once its dependency is `merged`, a merged
-- task is never a candidate to start, and a merged task cannot stall.
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

-- File overlap --------------------------------------------------------------

-- Two tasks overlap when they declare at least one common file. A task that
-- declares no files cannot be proven disjoint, so it does not block: the plan
-- makes `files` the contract, and an empty contract is the task author's call.
function M.overlaps(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  local files = {}
  for _, file in ipairs(type(a.files) == "table" and a.files or {}) do
    files[file] = true
  end
  for _, file in ipairs(type(b.files) == "table" and b.files or {}) do
    if files[file] then
      return true
    end
  end
  return false
end

local function overlaps_any(task, others)
  for _, other in ipairs(others) do
    if M.overlaps(task, other) then
      return true, other.id
    end
  end
  return false
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
  table.sort(candidates, function(a, b)
    return a.id < b.id
  end)

  for _, task in ipairs(candidates) do
    local met, reason = M.dependencies_met(task, tasks)
    if not met then
      skipped[#skipped + 1] = { id = task.id, reason = reason }
    elseif #in_flight + #selected >= max_parallel then
      skipped[#skipped + 1] = { id = task.id, reason = "max_parallel reached" }
    else
      local clash, with_id = overlaps_any(task, in_flight)
      if not clash then
        clash, with_id = overlaps_any(task, selected)
      end
      if clash then
        skipped[#skipped + 1] = { id = task.id, reason = "files overlap with " .. tostring(with_id) }
      else
        selected[#selected + 1] = task
      end
    end
  end

  return selected, skipped
end

-- Deploy selection ----------------------------------------------------------

-- A merge records the base it produced and leaves the task at `merged`; a
-- deployer drains that hand-off separately from the scheduler. The pending
-- flag may reach the projection in more than one shape: `task.deploy_pending`
-- as a boolean, a base string, or a table carrying `base`/`at`, or the merge
-- result's table under `task.deploy.pending`. Only an explicit false or an
-- empty flag means "nothing owed".
local function deploy_flag(task)
  if type(task) ~= "table" then
    return nil
  end
  local flag = task.deploy_pending
  if flag == nil and type(task.deploy) == "table" then
    flag = task.deploy.pending
  end
  return flag
end

local function deploy_pending_set(task)
  local flag = deploy_flag(task)
  if type(flag) == "boolean" then
    return flag
  end
  if type(flag) == "string" then
    return is_non_empty(flag)
  end
  if type(flag) == "table" then
    if flag.pending == false then
      return false
    end
    return is_non_empty(flag.base) or flag.pending == true or is_non_empty(flag.at)
  end
  return false
end

local function deploy_pending_base(task)
  local flag = deploy_flag(task)
  if type(flag) == "string" then
    return is_non_empty(flag) and flag or nil
  end
  if type(flag) == "table" and is_non_empty(flag.base) then
    return flag.base
  end
  return nil
end

local function pending_base_opts(opts)
  if is_non_empty(opts.pending_base) then
    return opts.pending_base
  end
  if type(opts.pending) == "string" and is_non_empty(opts.pending) then
    return opts.pending
  end
  if type(opts.pending) == "table" and is_non_empty(opts.pending.base) then
    return opts.pending.base
  end
  return nil
end

-- The tasks a deployer may drain now: status `merged` and the deploy-pending
-- flag set, sorted by id. `merged` is completed for the scheduler, so these
-- tasks are never runnable and never stall; this is the only list they appear
-- on. `opts.is_pending(task)` overrides how the flag is read. `opts.pending`
-- (or `opts.pending_base`) is the store-level pending base and narrows the
-- list to the task that names it, when the flag names a base at all.
--
-- Pure: no state, no fs, no runner. Returns `(list)`, or `(nil, err)` on bad
-- input, like the rest of the module.
function M.deployable(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  if type(tasks) ~= "table" then
    return nil, "tasks are required"
  end
  local is_pending = deploy_pending_set
  if type(opts.is_pending) == "function" then
    is_pending = opts.is_pending
  end
  local base = pending_base_opts(opts)

  local selected = {}
  for _, task in ipairs(M.collect(tasks)) do
    if task.status == "merged" then
      local called, pending = pcall(is_pending, task)
      if not called then
        return nil, "cannot read the deploy-pending flag of " .. tostring(task.id)
      end
      if pending then
        local named = deploy_pending_base(task)
        if not base or not named or named == base then
          selected[#selected + 1] = task
        end
      end
    end
  end
  table.sort(selected, function(a, b)
    return a.id < b.id
  end)
  return selected
end

-- The single-flight selection: at most one task per call, so a drain loop that
-- calls this cannot start two deploys at once. Returns `(task)` when one is
-- owed, `(nil)` when none is, and `(nil, err)` on bad input.
function M.next_deploy(tasks, opts)
  local list, err = M.deployable(tasks, opts)
  if not list then
    return nil, err
  end
  return list[1]
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
