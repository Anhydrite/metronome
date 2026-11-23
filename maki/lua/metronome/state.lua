-- Metronome state store.
--
-- The journal is append-only JSONL: one event per line, never rewritten. That
-- is what makes a crash survivable — a half-written last line is dropped on
-- replay, and everything before it still counts. state.json is a projection of
-- the journal, regenerated on every write, for the panel and for humans.
--
-- Every mutation takes the lock, appends one event, then rewrites the
-- projection. Readers never need the lock: they read the projection, and if it
-- is missing they replay the journal.

local M = {}

local json = maki.json
local fs = maki.fs

local TERMINAL = {
  merged = true,
  deployed = true,
  failed = true,
  abandoned = true,
}

-- Legal transitions. Anything else is a bug in the caller, so it raises rather
-- than silently corrupting the journal.
--
-- `ready` is a legal target from every status a task can be parked in, not
-- only from `qualifying`: `runtime.retry` and `runtime.resume` requeue a task
-- instead of starting it behind max_parallel's back, and a task recovered by
-- /reload has no pilot any more. `run_task` restarts at implement for every
-- non-epic task, so requeueing mid-pipeline costs no work.
local TRANSITIONS = {
  draft = { qualifying = true, abandoned = true },
  qualifying = { awaiting_answers = true, ready = true, failed = true, abandoned = true },
  awaiting_answers = { qualifying = true, abandoned = true },
  ready = { running = true, failed = true, abandoned = true },
  running = { verifying = true, failed = true, stalled = true, abandoned = true, ready = true },
  verifying = { running = true, reviewing = true, failed = true, abandoned = true, ready = true },
  reviewing = { changes_requested = true, pr_open = true, failed = true, abandoned = true, ready = true },
  changes_requested = { running = true, failed = true, abandoned = true },
  pr_open = { merging = true, merged = true, failed = true, abandoned = true },
  merging = { merged = true, failed = true, ready = true },
  merged = { deploying = true, deployed = true },
  deploying = { deployed = true, failed = true, ready = true },
  deployed = {},
  failed = { running = true, abandoned = true, ready = true },
  stalled = { running = true, failed = true, abandoned = true, ready = true },
  -- A retried task that re-enters review can hit the round limit while it is
  -- still abandoned; escalation must be able to fail it, not error out.
  abandoned = { running = true, failed = true, ready = true },
}

-- An epic task owns the single PR from the epic branch to the project base.
-- It has no implementation, no checks and no review of its own: the subtasks
-- already did that work on the epic branch, so the epic goes straight from
-- `running` to `pr_open`. This is an *addition* to TRANSITIONS, never a
-- replacement: a normal task still cannot skip verification and review.
local EPIC_TRANSITIONS = {
  running = { pr_open = true },
}

local function transitions_for(kind)
  if kind == "epic" then
    return EPIC_TRANSITIONS
  end
  return nil
end

function M.can_transition(from, to, kind)
  if from == to then
    return true
  end
  local allowed = TRANSITIONS[from]
  if allowed ~= nil and allowed[to] == true then
    return true
  end
  local extra = transitions_for(kind)
  local epic_allowed = extra and extra[from] or nil
  return epic_allowed ~= nil and epic_allowed[to] == true
end

-- The statuses reachable from `from`, sorted. A caller that hit a refusal
-- needs this to say what it could have asked for instead, and the panel uses
-- it to show what a task can do next.
function M.allowed_from(from, kind)
  local allowed = TRANSITIONS[from]
  local extra = transitions_for(kind)
  local epic_allowed = extra and extra[from] or nil
  if not allowed and not epic_allowed then
    return {}
  end
  local seen = {}
  for status in pairs(allowed or {}) do
    seen[status] = true
  end
  for status in pairs(epic_allowed or {}) do
    seen[status] = true
  end
  local list = {}
  for status in pairs(seen) do
    list[#list + 1] = status
  end
  table.sort(list)
  return list
end

function M.is_terminal(status)
  return TERMINAL[status] == true
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- The exact keys a persisted failure may carry. `recover.record` builds the
-- diagnosis and also carries `retryable`/`remediable`, which belong to the
-- decision it feeds, not to the task: the task schema pins the failure object
-- to these eight fields with additionalProperties = false. Filtering here is
-- what keeps any caller — recover, a test, the panel — from writing a journal
-- the schema refuses.
local FAILURE_KEYS = {
  "cause",
  "message",
  "remedy",
  "transient",
  "attempts",
  "at",
  "next_retry_at",
  "phase",
}

-- Reduce whatever the caller handed us to the documented failure shape.
-- Returns nil when there is nothing to persist, so a bogus `failure = {}` is
-- never mistaken for a diagnosis.
local function normalize_failure(failure)
  if type(failure) ~= "table" then
    return nil
  end
  local out = {}
  for _, key in ipairs(FAILURE_KEYS) do
    local value = failure[key]
    if value ~= nil then
      out[key] = value
    end
  end
  if next(out) == nil then
    return nil
  end
  return out
end

-- Statuses that mean the pipeline got moving again after a failure. They do not
-- forget the last cause — the cause is what makes the next failure readable and
-- the remedy actionable — but the pending retry is over: nothing waits for a
-- deadline any more, and the attempt budget starts again from zero.
local RESUME_STATUSES = { running = true, verifying = true, reviewing = true, merged = true }

-- A status event may carry a reason. Only a status that *is* a failure writes
-- it into `failure_reason`; a move carries why the task moved (a free-slot
-- wait, a review round), and reading that back as a cause would make the
-- status report invent an `unknown` error on a healthy task.
local REASON_AS_FAILURE = { failed = true, abandoned = true }

local function settle_failure(task)
  local failure = task.failure
  if type(failure) ~= "table" then
    return
  end
  failure.next_retry_at = nil
  failure.attempts = 0
end

-- Paths ---------------------------------------------------------------------

function M.paths(root)
  return {
    root = root,
    journal = fs.joinpath(root, "state.jsonl"),
    projection = fs.joinpath(root, "state.json"),
    lock = fs.joinpath(root, "state.lock"),
    archive = fs.joinpath(root, "archive"),
  }
end

function M.ensure(root)
  local p = M.paths(root)
  fs.mkdir(root, { parents = true })
  return p
end

-- Journal -------------------------------------------------------------------

-- Parse one journal line. Returns nil for a blank or corrupt line, which is
-- how a torn write from a crash is skipped instead of poisoning the replay.
function M.parse_line(line)
  if not line or line:match("^%s*$") then
    return nil
  end
  local ok, event = pcall(json.decode, line)
  if not ok or type(event) ~= "table" then
    return nil
  end
  if type(event.kind) ~= "string" then
    return nil
  end
  return event
end

-- A fresh projection. `deploy` is the non-task-scoped part of the state: the
-- base waiting to be deployed and the single-flight lock that says which
-- deployer is currently draining it.
local function new_state()
  return { tasks = {}, ids = {}, events = 0, deploy = { pending = nil, lock = nil } }
end

-- Replay a journal into
--   { tasks = { [id] = task }, events = n,
--     deploy = { pending = { base, at } | nil, lock = { owner, at } | nil } }.
--
-- Deploy events carry no task_id: they are about the store, not a task, so
-- they are handled before the task branch. That is also why a projection that
-- predates this feature must be normalised (see M.load) rather than trusted
-- to already have `deploy`.
function M.replay(text)
  local state = new_state()
  if not text then
    return state
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local event = M.parse_line(line)
    if event then
      state.events = state.events + 1
      local kind = event.kind
      local id = event.task_id
      if kind == "deploy_pending" then
        state.deploy.pending = { base = event.base, at = event.at }
      elseif kind == "deploy_pending_cleared" then
        state.deploy.pending = nil
      elseif kind == "deploy_lock_acquired" then
        state.deploy.lock = { owner = event.owner, at = event.at }
      elseif kind == "deploy_lock_released" then
        state.deploy.lock = nil
      elseif id then
        if kind == "task_created" then
          state.tasks[id] = event.task or { id = id }
          state.tasks[id].id = id
          -- An id is never reused, even after the task is deleted: keep every
          -- id ever created so next_id can never hand out a freed one.
          state.ids[id] = true
        elseif event.kind == "task_deleted" then
          state.tasks[id] = nil
        elseif state.tasks[id] then
          local task = state.tasks[id]
          if event.kind == "status" then
            task.status = event.status
            task.phase = event.phase or task.phase
            if type(event.reason) == "string" and event.reason ~= "" and REASON_AS_FAILURE[event.status] then
              task.failure_reason = event.reason
            end
            -- A failure is only rewritten by a failure event: branch, worktree,
            -- checkpoints and run_dir are never touched here, so a task that
            -- fails keeps every artefact a resume needs. Only `delete` drops a
            -- task, and with it those fields.
            if RESUME_STATUSES[event.status] then
              settle_failure(task)
            end
          elseif event.kind == "field" then
            for k, v in pairs(event.fields or {}) do
              task[k] = v
            end
          elseif event.kind == "note" then
            task.notes = task.notes or {}
            table.insert(task.notes, event.text)
          end
          task.updated_at = event.at or task.updated_at
        end
      end
    end
  end
  return state
end

-- Append one event, or a list of events, and refresh the projection.
--
-- A list is written in a single append so a transition that carries both a
-- field patch and the status move cannot land half-written between the two:
-- either every line is in the journal, or only a torn tail that replay drops.
--
-- The lock is advisory: maki's sandbox has no `io` and no flock, so there is
-- no atomic exclusive create. What actually protects the journal is its shape:
-- a torn line is dropped by parse_line on replay, so a crash mid-append costs
-- at most the event being written, never the history before it.
function M.append(root, event)
  local p = M.ensure(root)
  local events = event
  if type(events) ~= "table" or type(events[1]) ~= "table" then
    events = { event }
  end
  local at = now_iso()
  local lines = {}
  for _, one in ipairs(events) do
    one.at = one.at or at
    lines[#lines + 1] = json.encode(one)
  end

  local lock_ok = true
  local locked = fs.write(p.lock, tostring(os.time()))
  if not locked then
    lock_ok = false
  end

  local ok, err = fs.append(p.journal, table.concat(lines, "\n") .. "\n")
  if not ok then
    if lock_ok then
      fs.rm(p.lock)
    end
    return nil, "append failed: " .. tostring(err)
  end

  local text = fs.read(p.journal) or ""
  local state = M.replay(text)
  local wrote, werr = fs.write(p.projection, json.encode(state))
  if lock_ok then
    fs.rm(p.lock)
  end
  if not wrote then
    return nil, "projection failed: " .. tostring(werr)
  end
  return state, nil, lock_ok
end

-- Load the projection, or rebuild it from the journal when it is missing.
-- Load the current state.
--
-- The projection is a cache, never the truth. The journal is appended before
-- the projection is rewritten, so a kill between the two leaves a projection
-- that is behind — and serving it would silently lose the last event. The
-- projection therefore carries the event count it was built from, and is only
-- trusted when that count matches the journal.

-- Fill in the shape a caller may rely on. A projection written before the
-- deploy flag existed has no `deploy` key at all; serving it raw would make
-- `state.deploy.pending` raise for every reader.
local function normalize(state)
  if type(state.tasks) ~= "table" then
    state.tasks = {}
  end
  if type(state.events) ~= "number" then
    state.events = 0
  end
  if type(state.deploy) ~= "table" then
    state.deploy = {}
  end
  if type(state.ids) ~= "table" then
    -- A projection written before the id ledger existed: rebuild it from the
    -- tasks it still holds. Deleted ids are lost once, then never again.
    state.ids = {}
    for id in pairs(state.tasks) do
      state.ids[id] = true
    end
  end
  if type(state.deploy.pending) ~= "table" then
    state.deploy.pending = nil
  end
  if type(state.deploy.lock) ~= "table" then
    state.deploy.lock = nil
  end
  return state
end

function M.load(root)
  local p = M.paths(root)
  local journal = fs.read(p.journal)
  local replayed = journal and M.replay(journal) or nil

  local text = fs.read(p.projection)
  if text then
    local ok, state = pcall(json.decode, text)
    if ok and type(state) == "table" then
      -- No journal at all means the projection is all there is.
      if not replayed or state.events == replayed.events then
        return normalize(state)
      end
    end
  end

  return normalize(replayed or new_state())
end

-- Deploy state ---------------------------------------------------------------
--
-- The deploy marker is deliberately not a task field. A merge records the base
-- it just produced; the deployer, which may run in a different process, drains
-- whatever is pending. Both facts are journal events, so they replay like any
-- other, and a crash between appending and projecting loses nothing.
--
-- ``single-flight'' is the lock: one deployer at a time. The lock is advisory
-- in the same way the append lock is (maki has no flock), but because acquires
-- and releases are journal events, every process that replays sees the same
-- holder. `force` covers the one case the journal cannot model: a deployer
-- that died while still holding the lock.

local function deploy_of(state)
  return state.deploy or {}
end

-- The pending deploy, or nil. Read-only; safe without the lock.
function M.deploy_pending(root)
  return deploy_of(M.load(root)).pending
end

-- The current lock holder, or nil. Read-only; safe without the lock.
function M.deploy_lock(root)
  return deploy_of(M.load(root)).lock
end

-- Record `base` as the commit waiting to be deployed. A later merge simply
-- overwrites it: there is exactly one thing to deploy.
function M.set_deploy_pending(root, base)
  if type(base) ~= "string" or base == "" then
    return nil, "deploy pending needs a base"
  end
  local state, err = M.append(root, { kind = "deploy_pending", base = base })
  if not state then
    return nil, err
  end
  return deploy_of(state).pending
end

-- Drop the pending marker once a deployer has drained it. Refusing when there
-- is nothing pending makes a double-drain visible instead of silent.
function M.clear_deploy_pending(root)
  local current = deploy_of(M.load(root)).pending
  if not current then
    return nil, "no deploy pending"
  end
  local state, err = M.append(root, { kind = "deploy_pending_cleared" })
  if not state then
    return nil, err
  end
  return true
end

-- Take the single-flight lock for `owner`.
--
-- Re-acquiring as the same owner is a no-op: that deployer already owns the
-- right to run. Another owner is refused; `opts.force` takes over a lock left
-- behind by a crashed deployer.
function M.acquire_deploy(root, owner, opts)
  if type(owner) ~= "string" or owner == "" then
    return nil, "deploy lock needs an owner"
  end
  local held = deploy_of(M.load(root)).lock
  if held and held.owner ~= owner then
    if not (opts and opts.force) then
      return nil, string.format(
        "deploy lock held by %s since %s", tostring(held.owner), tostring(held.at)
      )
    end
  elseif held and held.owner == owner then
    return held
  end
  local state, err = M.append(root, { kind = "deploy_lock_acquired", owner = owner })
  if not state then
    return nil, err
  end
  return deploy_of(state).lock
end

-- Release the single-flight lock. Only the holder may release it unless
-- `opts.force` is set, which is how a stale lock is cleared.
function M.release_deploy(root, owner, opts)
  local held = deploy_of(M.load(root)).lock
  if not held then
    return nil, "no deploy lock held"
  end
  if held.owner ~= owner and not (opts and opts.force) then
    return nil, string.format(
      "deploy lock held by %s since %s", tostring(held.owner), tostring(held.at)
    )
  end
  local state, err = M.append(root, {
    kind = "deploy_lock_released",
    owner = held.owner,
  })
  if not state then
    return nil, err
  end
  return true
end

-- Spell the single-flight pair out for callers that prefer the longer names.
M.acquire_deploy_lock = M.acquire_deploy
M.release_deploy_lock = M.release_deploy

-- Task operations -----------------------------------------------------------

function M.create(root, task)
  if type(task) ~= "table" or type(task.id) ~= "string" or task.id == "" then
    return nil, "task needs an id"
  end
  local state = M.load(root)
  if state.tasks[task.id] then
    return nil, "task already exists: " .. task.id
  end
  task.status = task.status or "draft"
  task.created_at = task.created_at or now_iso()
  task.updated_at = task.created_at
  local new_state, err = M.append(root, {
    kind = "task_created",
    task_id = task.id,
    task = task,
  })
  if not new_state then
    return nil, err
  end
  return new_state.tasks[task.id]
end

-- Remove a task from the projection. The journal stays append-only: a
-- `task_deleted` event hides the task on replay, so the history is intact and
-- a later `task_created` with the same id would bring it back.
function M.delete(root, task_id)
  if type(task_id) ~= "string" or task_id == "" then
    return nil, "delete needs a task id"
  end
  local state = M.load(root)
  if not (state.tasks and state.tasks[task_id]) then
    return nil, "unknown task: " .. task_id
  end
  local new_state, err = M.append(root, { kind = "task_deleted", task_id = task_id })
  if not new_state then
    return nil, err
  end
  return true
end

-- Archive ---------------------------------------------------------------------

-- A deleted task keeps a self-contained snapshot under `archive/`. The journal
-- already records every event, but the projection hides the task and a human
-- should not have to replay the journal to recover what it was. The snapshot
-- carries the task record and, when the caller passes it, the sheet text.
function M.archive(root, task, opts)
  opts = type(opts) == "table" and opts or {}
  if type(task) ~= "table" or type(task.id) ~= "string" or task.id == "" then
    return nil, "archive needs a task with an id"
  end
  local p = M.ensure(root)
  fs.mkdir(p.archive, { parents = true })
  local snapshot = {
    archived_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    task = task,
    sheet = type(opts.sheet) == "string" and opts.sheet or nil,
  }
  local path = fs.joinpath(p.archive, task.id .. ".json")
  local ok, err = fs.write(path, json.encode(snapshot))
  if not ok then
    return nil, err or "cannot write archive"
  end
  return path
end

-- List the archived snapshots, newest first. A corrupt snapshot is skipped,
-- not raised: an archive that cannot be read must not break the panel.
function M.archived(root)
  local p = M.ensure(root)
  local entries = fs.dir(p.archive)
  if not entries then
    return {}
  end
  local list = {}
  for _, entry in ipairs(entries) do
    local name = entry.name or entry[1]
    if type(name) == "string" and name:match("%.json$") then
      local text = fs.read(fs.joinpath(p.archive, name))
      local ok, snapshot = pcall(json.decode, text or "")
      if ok and type(snapshot) == "table" and type(snapshot.task) == "table" then
        list[#list + 1] = {
          id = snapshot.task.id,
          title = snapshot.task.title,
          status = snapshot.task.status,
          archived_at = snapshot.archived_at,
          path = fs.joinpath(p.archive, name),
        }
      end
    end
  end
  table.sort(list, function(a, b)
    return (a.archived_at or "") > (b.archived_at or "")
  end)
  return list
end

function M.transition(root, task_id, to, extra)
  extra = type(extra) == "table" and extra or {}
  local state = M.load(root)
  local task = state.tasks[task_id]
  if not task then
    return nil, "unknown task: " .. task_id
  end
  if not M.can_transition(task.status, to, task.kind) then
    -- Name the task, both statuses, and what was allowed instead: a bare
    -- "illegal transition" leaves the caller guessing, and a pipeline that
    -- guesses retries the same illegal move forever.
    local allowed = M.allowed_from(task.status, task.kind)
    local hint = #allowed > 0 and table.concat(allowed, ", ") or "nothing (terminal)"
    return nil, string.format(
      "illegal transition %s -> %s for %s (allowed from %s: %s)",
      task.status, to, task_id, task.status, hint
    )
  end

  local events = {}
  if extra.failure ~= nil then
    if type(extra.failure) ~= "table" then
      return nil, "failure must be a table for " .. task_id
    end
    local failure = normalize_failure(extra.failure)
    if not failure then
      return nil, "failure is empty for " .. task_id
    end
    -- The typed diagnosis travels with the status move, so the failure the
    -- panel shows and the failure a resume acts on are the same record, written
    -- once. It goes in a field event because the journal's status event has no
    -- slot for a structured payload; both events land in one append, so a
    -- reader never sees the move without its diagnosis.
    events[#events + 1] = {
      kind = "field",
      task_id = task_id,
      fields = { failure = failure },
    }
  end
  -- A failure without a reason is a dead end for the user: persist it so
  -- the journal, the projection and the panel all carry it.
  events[#events + 1] = {
    kind = "status",
    task_id = task_id,
    status = to,
    phase = extra.phase or nil,
    reason = extra.reason or nil,
  }

  local new_state, err = M.append(root, events)
  if not new_state then
    return nil, err
  end
  return new_state.tasks[task_id]
end

function M.set_fields(root, task_id, fields)
  local state = M.load(root)
  if not state.tasks[task_id] then
    return nil, "unknown task: " .. task_id
  end
  local new_state, err = M.append(root, {
    kind = "field",
    task_id = task_id,
    fields = fields,
  })
  if not new_state then
    return nil, err
  end
  return new_state.tasks[task_id]
end

-- Resume helpers --------------------------------------------------------------

-- The typed failure a task carries, or nil. Never raises: an old projection
-- with no failure, or a bare string where a diagnosis should be, reads as nil
-- so a caller can branch on "is there something to act on?".
function M.failure_of(task)
  if type(task) ~= "table" then
    return nil
  end
  local failure = task.failure
  if type(failure) ~= "table" or next(failure) == nil then
    return nil
  end
  return failure
end

-- The last checkpoint written before an implementation turn, or nil. That sha
-- is the stable state a retry resumes from, which is why it must survive the
-- failure that interrupted the turn.
function M.checkpoint_of(task)
  if type(task) ~= "table" then
    return nil
  end
  local checkpoints = task.checkpoints
  if type(checkpoints) ~= "table" then
    return nil
  end
  local last = checkpoints[#checkpoints]
  if type(last) == "table" then
    last = last.sha
  end
  if type(last) ~= "string" or last == "" then
    return nil
  end
  return last
end

return M
