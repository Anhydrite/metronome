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
local TRANSITIONS = {
  draft = { qualifying = true, abandoned = true },
  qualifying = { awaiting_answers = true, ready = true, failed = true, abandoned = true },
  awaiting_answers = { qualifying = true, abandoned = true },
  ready = { running = true, failed = true, abandoned = true },
  running = { verifying = true, failed = true, stalled = true, abandoned = true },
  verifying = { running = true, reviewing = true, failed = true, abandoned = true },
  reviewing = { changes_requested = true, pr_open = true, failed = true, abandoned = true },
  changes_requested = { running = true, failed = true, abandoned = true },
  pr_open = { merging = true, merged = true, failed = true, abandoned = true },
  merging = { merged = true, failed = true },
  merged = { deploying = true, deployed = true },
  deploying = { deployed = true, failed = true },
  deployed = {},
  failed = { running = true, abandoned = true },
  stalled = { running = true, failed = true, abandoned = true },
  abandoned = { running = true },
}

function M.can_transition(from, to)
  if from == to then
    return true
  end
  local allowed = TRANSITIONS[from]
  return allowed ~= nil and allowed[to] == true
end

-- The statuses reachable from `from`, sorted. A caller that hit a refusal
-- needs this to say what it could have asked for instead, and the panel uses
-- it to show what a task can do next.
function M.allowed_from(from)
  local allowed = TRANSITIONS[from]
  if not allowed then
    return {}
  end
  local list = {}
  for status in pairs(allowed) do
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

-- Paths ---------------------------------------------------------------------

function M.paths(root)
  return {
    root = root,
    journal = fs.joinpath(root, "state.jsonl"),
    projection = fs.joinpath(root, "state.json"),
    lock = fs.joinpath(root, "state.lock"),
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

-- Replay a journal into { tasks = { [id] = task }, events = n }.
function M.replay(text)
  local state = { tasks = {}, events = 0 }
  if not text then
    return state
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local event = M.parse_line(line)
    if event then
      state.events = state.events + 1
      local id = event.task_id
      if id then
        if event.kind == "task_created" then
          state.tasks[id] = event.task or { id = id }
          state.tasks[id].id = id
        elseif state.tasks[id] then
          local task = state.tasks[id]
          if event.kind == "status" then
            task.status = event.status
            task.phase = event.phase or task.phase
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

-- Append one event and refresh the projection.
--
-- The lock is advisory: maki's sandbox has no `io` and no flock, so there is
-- no atomic exclusive create. What actually protects the journal is its shape:
-- a torn line is dropped by parse_line on replay, so a crash mid-append costs
-- at most the event being written, never the history before it.
function M.append(root, event)
  local p = M.ensure(root)
  event.at = event.at or now_iso()

  local lock_ok = true
  local locked = fs.write(p.lock, tostring(os.time()))
  if not locked then
    lock_ok = false
  end

  local line = json.encode(event)
  local ok, err = fs.append(p.journal, line .. "\n")
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
        return state
      end
    end
  end

  return replayed or { tasks = {}, events = 0 }
end

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

function M.transition(root, task_id, to, extra)
  local state = M.load(root)
  local task = state.tasks[task_id]
  if not task then
    return nil, "unknown task: " .. task_id
  end
  if not M.can_transition(task.status, to) then
    -- Name the task, both statuses, and what was allowed instead: a bare
    -- "illegal transition" leaves the caller guessing, and a pipeline that
    -- guesses retries the same illegal move forever.
    local allowed = M.allowed_from(task.status)
    local hint = #allowed > 0 and table.concat(allowed, ", ") or "nothing (terminal)"
    return nil, string.format(
      "illegal transition %s -> %s for %s (allowed from %s: %s)",
      task.status, to, task_id, task.status, hint
    )
  end
  local event = {
    kind = "status",
    task_id = task_id,
    status = to,
    phase = extra and extra.phase or nil,
  }
  local new_state, err = M.append(root, event)
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

return M
