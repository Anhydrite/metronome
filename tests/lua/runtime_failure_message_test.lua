-- Tests for the failure message maki/lua/metronome/runtime.lua journalizes.
--
-- Regression (T-20261122-0043, T-20261122-0030, T-20261122-0042): the result
-- carried the real cause — an escalated review after 3 rounds, the files of a
-- rebase conflict, a journaled note — but no `error` field. The runtime turned
-- the result table into `tostring(...)` ("table: 0x…") or an empty string, and
-- the turn was journaled as a mute `failed` with no reason, sometimes twice:
-- once by the module that gave up, once by the runtime with "no error details".
--
-- These cases pin the contract:
--   * an escalated review without `error` produces a failed that names the
--     escalation and its rounds,
--   * a conflict without `error` produces a failed that names the files, the
--     base and the command,
--   * a result with nothing in it is a runtime defect, journaled as such, never
--     a mute task failure,
--   * a turn writes ONE `failed` transition, even when the review module already
--     wrote it, and the journal reason, the runtime.log line and `failure_reason`
--     are the same string.

return function()
  local runtime = load_module("runtime")
  local recover_mod = load_module("recover")

  -- The journal is kept under the state dir metronome-tests tree so
  -- tests/run-lua.sh can scan the runtime.log this file writes for the generic
  -- "no error details" text.
  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "runtime-failure-message")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local root = maki.fs.joinpath(base, "state")
  maki.fs.mkdir(root, { parents = true })
  local config = maki.fs.joinpath(base, "config.toml")
  maki.fs.write(config, "[project]\nrepo = \"/tmp/repo\"\n")

  local paths = {
    repo = "/tmp/repo",
    root = root,
    tasks = maki.fs.joinpath(base, "tasks"),
    worktrees = maki.fs.joinpath(base, "worktrees"),
    runs = maki.fs.joinpath(base, "runs"),
    prompts = maki.fs.joinpath(base, "prompts"),
    config = config,
  }

  -- The journal, in memory: transitions are recorded as the `status` events the
  -- real journal writes, notes as their text, so a case can count the failed
  -- events of a turn and compare their reason with the log and the projection.
  local function fake_state(tasks)
    local api = { transitions = {}, events = {}, notes = {} }
    api.load = function()
      return { tasks = tasks }
    end
    api.transition = function(_, id, to, extra)
      local task = tasks[id]
      if not task then
        return nil, "unknown task: " .. tostring(id)
      end
      local event = {
        kind = "status",
        task_id = id,
        status = to,
        reason = type(extra) == "table" and extra.reason or nil,
      }
      api.transitions[#api.transitions + 1] = { id = id, status = to, extra = extra, event = event }
      api.events[#api.events + 1] = event
      task.status = to
      if type(extra) == "table" and extra.reason ~= nil then
        task.failure_reason = extra.reason
      end
      return task
    end
    api.set_fields = function(_, id, fields)
      local task = tasks[id]
      if not task then
        return nil, "unknown task: " .. tostring(id)
      end
      for key, value in pairs(fields or {}) do
        task[key] = value
      end
      -- The real journal writes a `field` event; keep it so a case can find the
      -- reason persisted beside a module-written `status failed` event.
      api.events[#api.events + 1] = { kind = "field", task_id = id, fields = fields }
      return task
    end
    api.append = function(_, event)
      api.notes[#api.notes + 1] = event
      api.events[#api.events + 1] = event
      return { events = { event } }
    end
    api.can_transition = function()
      return true
    end
    return api
  end

  local function log_text()
    return maki.fs.read(maki.fs.joinpath(root, "runtime.log")) or ""
  end

  -- The reason the runtime.log line carries for one task's failure. The log is
  -- cumulative across the cases, so the last matching line is this turn's.
  local function log_reason(task_id)
    local found = nil
    for line in log_text():gmatch("[^\r\n]+") do
      local reason = line:match("task " .. task_id .. " failed: (.*)$")
      if reason then
        found = reason
      end
    end
    return found
  end

  -- Every `status failed` event the journal received this turn.
  local function failed_events(env)
    local out = {}
    for _, event in ipairs(env.state.events) do
      if event.kind == "status" and event.status == "failed" then
        out[#out + 1] = event
      end
    end
    return out
  end

  local function journal_text(env)
    local parts = {}
    for _, event in ipairs(env.state.events) do
      parts[#parts + 1] = tostring(event.text or "")
    end
    return table.concat(parts, "\n")
  end

  local function note_text(env)
    local parts = {}
    for _, note in ipairs(env.state.notes) do
      parts[#parts + 1] = tostring(note.text or "")
    end
    return table.concat(parts, "\n")
  end

  -- The reason the journal carries for the turn's failure. A runtime-written
  -- `status failed` event carries it inline; a module-written one has none, and
  -- the runtime persists it in a `field` event right beside it, exactly as the
  -- real state module does (which is how `failure_reason` is rebuilt).
  local function journal_reason(env)
    local found = nil
    for _, event in ipairs(env.state.events) do
      if event.kind == "status" and event.status == "failed"
        and type(event.reason) == "string" and event.reason ~= "" then
        found = event.reason
      elseif event.kind == "field" and type(event.fields) == "table"
        and type(event.fields.failure_reason) == "string"
        and event.fields.failure_reason ~= "" then
        found = event.fields.failure_reason
      end
    end
    return found
  end

  -- The journal reason, the runtime.log reason and the projection's
  -- failure_reason must be one and the same string.
  local function assert_same_reason(env, tasks, label)
    local events = failed_events(env)
    eq(#events, 1, label .. ": exactly one `status failed` event is journaled")
    local journaled = journal_reason(env)
    local logged = log_reason("T1")
    eq(type(journaled), "string", label .. ": the journaled failure carries a reason")
    eq(logged, journaled, label .. ": the runtime.log line carries the journal reason")
    eq(tasks.T1.failure_reason, journaled, label .. ": failure_reason carries the journal reason")
    return journaled
  end

  -- A runtime wired like the one the scheduler builds, with every module of the
  -- implement -> review -> PR chain stubbed.
  local function build(env)
    return runtime.new({
      config = {
        load = function()
          return {
            project = { repo = "/tmp/repo", base_ref = "main" },
            checks = { default = { "true" }, timeout_secs = 10 },
            merge = { method = "squash", auto_merge = false },
            review = { max_rounds = 3 },
            deploy = { auto_deploy = false },
          }
        end,
      },
      roles = {
        session_opts = function()
          return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
        end,
      },
      recover = recover_mod,
      state = env.state,
      implement = {
        run = env.implement_run or function()
          return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "s1" }
        end,
        read_sheet = function()
          return {}
        end,
      },
      checks = {
        verify = function()
          return { ok = true }
        end,
        write_report = function() end,
      },
      converge = { run = function() return { ok = true } end },
      review = env.review or {
        review = function() return { ok = true, approved = true, sha = "s1" } end,
      },
      git = {
        pr_open = function()
          return { number = 1, url = "u", state = "open" }
        end,
      },
      merge = { run = function() return { ok = true } end },
      deploy = { run = function() return { ok = true } end },
      pipeline = env.pipeline or {
        tick = function() return { ok = true, started = {} } end,
      },
      paths = function()
        return paths
      end,
      spawn = function(fn)
        return fn()
      end,
      async = nil,
      wait_turn_end = false,
      runner = {
        run = function()
          return { ok = true }
        end,
      },
      qualify = {
        run = function()
          return { ok = true, tasks = { { title = "t", files = { "f" }, checks = { "true" } } } }
        end,
        next_id = function() return "T1" end,
        apply = function()
          return { ok = true, tasks = { { id = "T1", title = "t" } } }
        end,
      },
      questions = {
        round = function() return { questions = {} } end,
        answer = function() return {} end,
      },
      analyze = {
        gate = function()
          return { ok = true }
        end,
      },
      calibrate = {}, fence = {}, mode = {},
    })
  end

  -- A tick that dispatches T1 on its first call, then reports an empty queue.
  local function tick_dispatching(ids)
    local calls = 0
    return function(opts)
      calls = calls + 1
      if calls == 1 then
        for _, id in ipairs(ids) do
          opts.dispatch({ id = id })
        end
        return { ok = true, started = ids }
      end
      return { ok = true, started = {} }
    end
  end

  -- Submit the work and drain it on the caller's turn (`spawn` is synchronous),
  -- so the dispatched task has finished when `run_pending` returns.
  local function drive(env)
    local rt = build(env)
    if not rt then
      fail("the runtime could not be built")
      return nil
    end
    rt.submit({ intention = "x", fast = false }, { session = "S1" })
    rt.run_pending()
    return rt, rt.last_background
  end

  -- (a) An escalated review names the escalation and its rounds, end to end
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks),
      pipeline = { tick = tick_dispatching({ "T1" }) },
      review = {
        review = function()
          -- `run_task` turns this verdict into `error = "review escalated after
          -- 3 round(s)"` before the failure policy runs, so this case pins the
          -- user-visible outcome; the synthesis branch itself is covered by (a2).
          return { ok = false, escalated = true, round = 3, approved = false }
        end,
      },
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain or {}
    eq(result.ok, false, "an escalated review fails the task")
    local reason = assert_same_reason(env, tasks, "review escalation")
    has(reason, "review escalated", "the reason names the escalation")
    has(reason, "3", "the reason names the number of rounds")
    eq(reason:find("no error details", 1, true), nil,
      "the review escalation reason is not the generic text")
    eq(log_text():find("no error details", 1, true), nil,
      "the runtime.log of the review escalation carries no generic text")
  end

  -- (a2) A result carrying only `escalated`/`round` reaches the synthesis path
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks),
      pipeline = { tick = tick_dispatching({ "T1" }) },
      -- No `error`, no `reason`: `run_and_handle` hands the result table itself
      -- to the failure policy, which is exactly where `synthesize_failure` has
      -- to name the escalation instead of `tostring(result)`.
      implement_run = function()
        return { ok = false, escalated = true, round = 3 }
      end,
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain or {}
    eq(result.ok, false, "a bare escalation fails the task")
    local reason = assert_same_reason(env, tasks, "bare escalation")
    has(reason, "review escalated after 3 round(s)",
      "the synthesized reason names the escalation and its rounds")
    eq(reason:find("table: ", 1, true), nil,
      "the reason is not a stringified table")
    eq(reason:find("no error details", 1, true), nil,
      "the synthesized escalation reason is not the generic text")
  end

  -- (b) A conflict without `error` names the files, the base and the command
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks),
      pipeline = { tick = tick_dispatching({ "T1" }) },
      implement_run = function()
        return {
          ok = false,
          conflict_files = "a.js,b.js",
          base = "origin/main",
          rebase_command = "git rebase origin/main",
        }
      end,
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain or {}
    eq(result.ok, false, "a conflict fails the task")
    local reason = assert_same_reason(env, tasks, "conflict")
    has(reason, "conflict in phase", "the reason names the conflict and its phase")
    has(reason, "a.js", "the reason names the first file in conflict")
    has(reason, "b.js", "the reason names the second file in conflict")
    has(reason, "origin/main", "the reason names the base")
    has(reason, "git rebase origin/main", "the reason names the rebase command")
    eq(reason:find("no error details", 1, true), nil,
      "the conflict reason is not the generic text")
  end

  -- (c) A completely empty result is a runtime defect, not a mute failure
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks),
      pipeline = { tick = tick_dispatching({ "T1" }) },
      implement_run = function()
        return { ok = false }
      end,
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain or {}
    eq(result.ok, false, "an empty failure still fails the task")
    local reason = assert_same_reason(env, tasks, "empty failure")
    has(reason, "runtime returned an empty failure in phase",
      "the reason names the runtime defect and its phase")
    has(note_text(env), "runtime defect: runtime returned an empty failure in phase",
      "the defect is journaled as a note")
    eq(reason:find("no error details", 1, true), nil,
      "the empty-failure reason is not the generic text")
    has(journal_text(env) .. log_text() .. note_text(env), "runtime defect",
      "the defect is visible to a reader")
  end

  -- (d) A module that already wrote `failed` with a reason owns that reason
  do
    local escalated_reason = "review escalated after 3 rounds: human review required"
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks),
      pipeline = { tick = tick_dispatching({ "T1" }) },
    }
    env.review = {
      review = function()
        -- The review module writes the one `failed` transition of the turn and
        -- persists its own reason, then reports the escalation.
        env.state.transition(paths.root, "T1", "failed", {
          reason = escalated_reason,
          phase = "review",
        })
        return { ok = false, escalated = true, round = 3 }
      end,
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain or {}
    eq(result.ok, false, "an escalated review fails the task")
    local reason = assert_same_reason(env, tasks, "single failed transition")
    eq(reason, escalated_reason,
      "the runtime adopts the reason the review module already persisted")
    local failed_count = 0
    for _, move in ipairs(env.state.transitions) do
      if move.status == "failed" then
        failed_count = failed_count + 1
      end
    end
    eq(failed_count, 1, "the runtime writes no second `failed` transition")
  end

  -- (d2) A module that wrote `failed` WITHOUT a reason — the real
  -- `review.escalate` and `merge` do exactly that — still gets one persisted
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks),
      pipeline = { tick = tick_dispatching({ "T1" }) },
    }
    env.review = {
      review = function()
        -- Mirror `review.escalate`: the transition carries only a phase.
        env.state.transition(paths.root, "T1", "failed", { phase = "review" })
        return { ok = false, escalated = true, round = 3 }
      end,
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain or {}
    eq(result.ok, false, "an escalated review fails the task")
    local reason = assert_same_reason(env, tasks, "reasonless module transition")
    has(reason, "review escalated", "the synthesized reason names the escalation")
    has(reason, "3", "the synthesized reason names the number of rounds")
    eq(reason:find("no error details", 1, true), nil,
      "the synthesized reason is not the generic text")
    eq(type(tasks.T1.failure), "table",
      "the typed failure record is persisted even when the module already failed the task")
    local failed_count = 0
    for _, move in ipairs(env.state.transitions) do
      if move.status == "failed" then
        failed_count = failed_count + 1
      end
    end
    eq(failed_count, 1, "the runtime writes no second `failed` transition")
  end

  -- (e) The generic text never reaches the journal or the log of this suite
  do
    local text = log_text()
    eq(text:find("no error details", 1, true), nil,
      "the runtime.log written by the failure-message suite has no generic text")
  end
end
