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
--
-- A failure is not a scheduling dead end. A `failed` task that carries a
-- transient diagnosis, is under its attempt bound and whose backoff has elapsed
-- is a retry candidate exactly like a `ready` task: `retry_ready()` selects it,
-- `tick()` starts it again through the legal `failed -> running` edge, and a
-- dependent waits for it ("retrying") instead of being declared blocked. The
-- module stays pure Lua: the clock comes from `opts.now` and the recovery
-- policy from `opts.recover` (falling back to the `recover` module).

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
  failed = "implement",
}

local RESUME_PATH = {
  running = { "running" },
  stalled = { "running" },
  verifying = { "running" },
  reviewing = { "changes_requested", "running" },
  merging = { "failed", "running" },
  deploying = { "failed", "running" },
  failed = { "running" },
}

-- Used only when neither `opts.max_attempts` nor the recover module's defaults
-- are available, so the scheduler never loses its bound.
local DEFAULT_MAX_ATTEMPTS = 3

-- Helpers -------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

-- The recovery policy: injected through `opts.recover` so the scheduler stays
-- testable without loading the module. When it is not injected, load it once
-- and cache it; a missing module is not an error, only a fallback to the
-- failure fields the task already carries.
local cached_recover
local function recover_module(opts)
  if type(opts) == "table" and type(opts.recover) == "table" then
    return opts.recover
  end
  if cached_recover ~= nil then
    return cached_recover or nil
  end
  local ok, mod = pcall(require, "metronome.recover")
  if ok and type(mod) == "table" then
    cached_recover = mod
    return mod
  end
  cached_recover = false
  return nil
end

-- The attempt bound for one call: per-call opts, then the recover defaults.
local function max_attempts(opts)
  local value = tonumber(type(opts) == "table" and opts.max_attempts or nil)
  if value then
    return value
  end
  local rec = recover_module(opts)
  if rec and type(rec.DEFAULTS) == "table" then
    value = tonumber(rec.DEFAULTS.max_attempts)
    if value then
      return value
    end
  end
  return DEFAULT_MAX_ATTEMPTS
end

-- The clock for one call: an explicit `opts.now`, else the host clock.
local function clock(opts)
  local now = tonumber(type(opts) == "table" and opts.now or nil)
  if now then
    return now
  end
  return os.time()
end

-- A failure is due when it carries no deadline yet or its backoff has elapsed.
-- Kept apart from `retryable` so a dependent waits on a not-yet-due retry
-- ("retrying") instead of calling it blocked, while only a due retry starts.
local function failure_due(failure, now)
  local next_at = tonumber(failure.next_retry_at)
  if next_at == nil then
    return true
  end
  return now >= next_at
end

-- Is the task allowed to retry at all (ignoring the backoff clock)? A transient
-- cause under the attempt bound. Uses recover.decide when the module is
-- available so the policy has a single authority, and falls back to the
-- persisted failure fields otherwise.
local function retryable(task, opts)
  if type(task) ~= "table" or task.status ~= "failed" then
    return false
  end
  local failure = task.failure
  if type(failure) ~= "table" or next(failure) == nil then
    return false
  end
  local limit = max_attempts(opts)
  local rec = recover_module(opts)
  if rec and type(rec.decide) == "function" then
    local decision = rec.decide(failure, { max_attempts = limit })
    if type(decision) ~= "table" or decision.action ~= "auto_retry" then
      return false
    end
    return true
  end
  if failure.transient ~= true then
    return false
  end
  local attempts = tonumber(failure.attempts) or 0
  return attempts < limit
end

-- Start candidates -----------------------------------------------------------

-- The failed tasks that may start again now: transient, under the attempt
-- bound, and due. Sorted by id so a redraw is deterministic.
function M.retry_ready(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local now = clock(opts)
  local ready = {}
  for _, task in ipairs(M.collect(tasks)) do
    if retryable(task, opts) and failure_due(task.failure, now) then
      ready[#ready + 1] = task
    end
  end
  table.sort(ready, function(a, b)
    return a.id < b.id
  end)
  return ready
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
-- that was never created. A failed dependency is blocked only when it cannot
-- retry; while a transient retry is pending (or due) the dependent waits on it
-- like on any in-flight task, so a recoverable failure never condemns the
-- workflow downstream.
function M.dependencies_met(task, tasks, opts)
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
      if retryable(dep, opts) then
        return false, "waiting on " .. tostring(dep_id) .. " (retrying)"
      end
      return false, "blocked by " .. tostring(dep_id) .. " (" .. tostring(dep.status) .. ")"
    end
    if not DONE[dep.status] then
      return false, "waiting on " .. tostring(dep_id) .. " (" .. tostring(dep.status) .. ")"
    end
  end
  return true
end

-- Scheduling ----------------------------------------------------------------

-- Pick the tasks to start from an already-filtered candidate list. `running`
-- is the tasks already in flight (a list or a map). Returns `started, skipped`;
-- every skipped task carries a reason, so the panel and the logs can say why it
-- waited. Shared by `schedule` (ready tasks) and `tick` (ready + retries).
local function pick(candidates, tasks, running, opts)
  opts = type(opts) == "table" and opts or {}
  local max_parallel = tonumber(opts.max_parallel) or 2
  if max_parallel < 1 then
    max_parallel = 1
  end

  local in_flight = M.collect(running)
  local selected = {}
  local skipped = {}

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
    local met, reason = M.dependencies_met(task, tasks, opts)
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

-- Pick the `ready` tasks to start now. `running` is the tasks already in
-- flight (a list or a map). Returns `started, skipped`; every skipped task
-- carries a reason, so the panel and the logs can say why it waited.
function M.schedule(tasks, running, opts)
  opts = type(opts) == "table" and opts or {}
  local candidates = {}
  for _, task in ipairs(M.collect(tasks)) do
    if task.status == "ready" then
      candidates[#candidates + 1] = task
    end
  end
  return pick(candidates, tasks, running, opts)
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
    -- A failed task is resumed only when it is actually retryable: a red
    -- permanent failure (auth, checks red, budget exhausted) stays failed until
    -- a human acts, so a reload does not loop it forever.
    if phase and (task.status ~= "failed" or retryable(task, opts)) then
      if task.status == "failed" and type(task.failure) == "table" and is_non_empty(task.failure.phase) then
        phase = task.failure.phase
      end
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

  local schedule_opts = {
    max_parallel = opts.max_parallel,
    now = opts.now,
    max_attempts = opts.max_attempts,
    recover = opts.recover,
  }

  -- A failed but retryable task is a start candidate exactly like a ready one.
  -- Both compete for the same max_parallel budget and obey the same runs-alone
  -- rule, so a retry never wedges the drain.
  local retries = M.retry_ready(loaded.tasks, schedule_opts)
  local retry_ids = {}
  local candidates = {}
  for _, task in ipairs(M.collect(loaded.tasks)) do
    if task.status == "ready" then
      candidates[#candidates + 1] = task
    end
  end
  for _, task in ipairs(retries) do
    retry_ids[task.id] = true
    candidates[#candidates + 1] = task
  end

  local started, skipped = pick(candidates, loaded.tasks, running, schedule_opts)

  if opts.apply ~= false then
    for _, task in ipairs(started) do
      local phase = "implement"
      if retry_ids[task.id] and type(task.failure) == "table" and is_non_empty(task.failure.phase) then
        phase = task.failure.phase
      end
      local moved, merr = state.transition(root, task.id, "running", { phase = phase })
      if not moved then
        -- A task that cannot move is reported, never fatal: the tick succeeded
        -- and the next one can try again.
        skipped[#skipped + 1] = { id = task.id, reason = merr }
      elseif type(opts.dispatch) == "function" then
        pcall(opts.dispatch, moved, phase)
      end
    end
  end

  return {
    ok = true,
    started = started,
    skipped = skipped,
    stalled = stalled,
    retrying = retries,
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
