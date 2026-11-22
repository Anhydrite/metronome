-- Tests for the sequencing rules of maki/lua/metronome/runtime.lua.
--
-- Regression: a late review verdict moved a task that had already been
-- re-dispatched. The journal refused it ("illegal transition running ->
-- changes_requested") and the runtime failed the *task* for a runtime defect:
--   * two pilots ran on the same task (a second `run_task` while the first was
--     still in `running`),
--   * an internal illegal transition was treated as a task failure,
--   * the drain stopped after a task crashed, leaving the other ready tasks
--     undispatched.
--
-- These cases pin the contract: one pilot per task, an internal illegal
-- transition is journaled and reconciled (never `failed`, never a
-- `failure_reason`), the review fix turn abandons when the task left
-- `reviewing`, and a crash in the drain never stops the other ready tasks.

return function()
  local runtime = load_module("runtime")
  local recover_mod = load_module("recover")

  local root = mktmpdir("metronome-runtime-transition")
  local config = maki.fs.joinpath(root, "config.toml")
  maki.fs.write(config, "[project]\nrepo = \"/tmp/repo\"\n")

  local paths = {
    repo = "/tmp/repo",
    root = root,
    tasks = maki.fs.joinpath(root, "tasks"),
    worktrees = maki.fs.joinpath(root, "worktrees"),
    runs = maki.fs.joinpath(root, "runs"),
    prompts = maki.fs.joinpath(root, "prompts"),
    config = config,
  }

  -- The journal, in memory: the tests need to see which transitions the
  -- runtime attempted and which notes it left, not only the final status.
  local function fake_state(tasks)
    local api = { transitions = {}, notes = {} }
    api.load = function()
      return { tasks = tasks }
    end
    api.transition = function(_, id, to, extra)
      local task = tasks[id]
      if not task then
        return nil, "unknown task: " .. tostring(id)
      end
      api.transitions[#api.transitions + 1] = { id = id, status = to, extra = extra }
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
      return task
    end
    api.append = function(_, event)
      api.notes[#api.notes + 1] = event
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

  local function transitioned_to(env, status)
    for _, move in ipairs(env.state.transitions) do
      if move.status == status then
        return true
      end
    end
    return false
  end

  local function note_text(env)
    local parts = {}
    for _, note in ipairs(env.state.notes) do
      parts[#parts + 1] = tostring(note.text or "")
    end
    return table.concat(parts, "\n")
  end

  -- A runtime wired like the one the scheduler builds, with every module that
  -- the implement -> review -> PR chain touches replaced by a stub.
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
          env.implement_calls = env.implement_calls + 1
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
      async = env.async,
      wait_turn_end = false,
      runner = {
        run = function()
          env.runner_calls = env.runner_calls + 1
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
          env.gate_calls = env.gate_calls + 1
          return { ok = true }
        end,
      },
      calibrate = {}, fence = {}, mode = {},
    })
  end

  -- A tick that dispatches the given list on its first call, then reports an
  -- empty queue: the shape of a drain that found ready tasks once.
  local function tick_dispatching(dispatch_ids)
    local calls = 0
    return function(opts)
      calls = calls + 1
      if calls == 1 then
        for _, id in ipairs(dispatch_ids) do
          opts.dispatch({ id = id })
        end
        return { ok = true, started = dispatch_ids }
      end
      return { ok = true, started = {} }
    end
  end

  -- Submit the work and drain it on the caller's turn: `spawn` is synchronous
  -- here, so every dispatched task has finished when `run_pending` returns and
  -- the drain's `results` list carries the run_task results.
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

  -- One pilot per task ------------------------------------------------------
  --
  -- A dispatch that reaches `run_task` while another driver already moved the
  -- task on (a review round, a fix round) must abandon: no session is opened,
  -- no transition is written, and the caller gets a non-failing result.
  for _, status in ipairs({ "reviewing", "changes_requested" }) do
    local tasks = { T1 = { id = "T1", status = status, title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks), implement_calls = 0, runner_calls = 0, gate_calls = 0,
      pipeline = { tick = tick_dispatching({ "T1" }) },
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain.results and drain.results[1] or nil
    eq(type(result), "table", "a dispatch on a " .. status .. " task returns a result")
    eq(result and result.error, nil, "a second pilot on a " .. status .. " task is not an error")
    eq(result and result.skipped, true, "a second pilot on a " .. status .. " task is skipped")
    eq(result and result.reason, "task already owned: status=" .. status,
      "the skip names the status that owns the task")
    eq(env.implement_calls, 0, "no implementer turn is opened while the task is " .. status)
    eq(env.runner_calls, 0, "no model session is opened while the task is " .. status)
    eq(tasks.T1.status, status, "the status of a " .. status .. " task is left alone")
    eq(#env.state.transitions, 0, "a skipped dispatch writes no transition")
  end

  -- A task that finished its own run leaves `running`: the same task dispatched
  -- again is skipped instead of racing the first pilot on the same worktree.
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks), implement_calls = 0, runner_calls = 0, gate_calls = 0,
      -- Two pilots queued the same task, as the two consecutive `running` the
      -- journal of T-20261122-002d shows.
      pipeline = { tick = tick_dispatching({ "T1", "T1" }) },
    }
    local _, drain = drive(env)
    local results = type(drain) == "table" and drain.results or {}
    local second = results[2]
    eq(env.implement_calls, 1, "the second dispatch of the same task does not implement it twice")
    eq(tasks.T1.status, "pr_open", "the first pilot carries the task to pr_open")
    eq(type(second), "table", "the second dispatch returns a result")
    eq(second and second.skipped, true, "the second dispatch is skipped")
    eq(second and second.reason, "task already owned: status=pr_open",
      "the skip names the status the first pilot reached")
    eq(second and second.error, nil, "a skipped second dispatch is not a failure")
  end

  -- An internal illegal transition never fails the task ---------------------
  --
  -- `illegal transition running -> changes_requested` is a sequencing defect of
  -- the runtime, not a fault of the task: it is logged, journaled as a note and
  -- reconciled. The task keeps its status, gets no failure and gets no
  -- failure_reason.
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks), implement_calls = 0, runner_calls = 0, gate_calls = 0,
      pipeline = { tick = tick_dispatching({ "T1" }) },
    }
    local illegal = "illegal transition running -> changes_requested for T1 "
      .. "(allowed from running: abandoned, failed, stalled, verifying)"
    env.implement_run = function()
      env.implement_calls = env.implement_calls + 1
      tasks.T1.status = "running"
      return { ok = false, error = illegal }
    end
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain.results and drain.results[1] or nil
    eq(type(result), "table", "a reconciled dispatch returns a result")
    eq(result and result.reconciled, true, "an internal illegal transition is reconciled")
    eq(result and result.ok, true, "a reconciled dispatch is not a failure")
    eq(result and result.error, nil, "a reconciled dispatch carries no error")
    eq(tasks.T1.status, "running", "an internal illegal transition leaves the status alone")
    eq(tasks.T1.failure_reason, nil, "an internal illegal transition writes no failure_reason")
    eq(tasks.T1.failure, nil, "an internal illegal transition writes no failure record")
    eq(transitioned_to(env, "failed"), false,
      "an internal illegal transition never moves the task to failed")
    has(log_text(), "illegal transition", "the reconciled transition is logged")
    has(note_text(env), "illegal transition", "the reconciled transition is journaled as a note")
  end

  -- The drain survives a crashing task and a crashing loop -----------------
  --
  -- T1 raises inside the drain and the drain loop itself then throws. T2 is
  -- still `ready` and must be dispatched in the same drain, and the scheduler
  -- must re-arm instead of leaving the rest of the queue untouched.
  do
    local tasks = {
      T1 = { id = "T1", status = "ready", title = "un", checks = { "true" } },
      T2 = { id = "T2", status = "ready", title = "deux", checks = { "true" } },
    }
    local env = {
      state = fake_state(tasks), implement_calls = 0, runner_calls = 0, gate_calls = 0,
      async = true,
    }
    local ran = {}
    local tick_calls = 0
    env.implement_run = function(opts)
      ran[#ran + 1] = opts.task.id
      if opts.task.id == "T1" then
        error("drain boom on T1")
      end
      return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "s1" }
    end
    env.pipeline = {
      tick = function(opts)
        tick_calls = tick_calls + 1
        if tick_calls == 1 then
          opts.dispatch({ id = "T1" })
          error("drain loop boom")
        elseif tick_calls == 2 then
          opts.dispatch({ id = "T2" })
          return { ok = true, started = { "T2" } }
        end
        return { ok = true, started = {} }
      end,
    }
    local rt = build(env)
    rt.submit({ intention = "x", fast = false }, { session = "S1" })
    rt.run_pending()
    eq(tasks.T2.status, "pr_open", "a ready task is still dispatched after a task crashed the drain")
    eq(ran[#ran], "T2", "the second task is the one the drain dispatched next")
    eq(tick_calls >= 3, true, "the drain loop keeps ticking after the loop itself failed")
    eq(env.gate_calls >= 2, true, "the scheduler re-arms after a failure in its own loop")
    has(log_text(), "drain loop boom", "the loop failure is logged")
    eq(transitioned_to(env, "deployed"), false, "the crashed task did not finish")
  end

  -- A review fix turn abandons when the task left `reviewing` --------------
  --
  -- The round's own verdict asked for changes, but another pilot already moved
  -- the task back to `running`: the fix turn must be dropped with a note, not
  -- re-implemented and not failed.
  do
    local tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } }
    local env = {
      state = fake_state(tasks), implement_calls = 0, runner_calls = 0, gate_calls = 0,
      pipeline = { tick = tick_dispatching({ "T1" }) },
    }
    local fix_result = nil
    env.implement_run = function()
      env.implement_calls = env.implement_calls + 1
      return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "s1" }
    end
    env.review = {
      loop = function(opts)
        -- Another pilot resumes the task while the round is being judged.
        tasks.T1.status = "running"
        fix_result = opts.fix({
          ok = false, changes_requested = true, round = 1, sha = "s1", findings = {},
        })
        return { ok = true, stale = true, discarded = true, round = 1, sha = "s1" }
      end,
    }
    local _, drain = drive(env)
    local result = type(drain) == "table" and drain.results and drain.results[1] or nil
    eq(type(fix_result), "table", "the fix callback returns a verdict")
    eq(fix_result and fix_result.discarded, true,
      "a fix turn on a task that left reviewing is discarded")
    eq(fix_result and fix_result.ok, true, "a discarded fix turn is not a failure")
    eq(env.implement_calls, 1, "a discarded fix turn opens no second implementer session")
    eq(tasks.T1.status, "running", "a discarded fix turn leaves the status alone")
    eq(tasks.T1.failure_reason, nil, "a discarded fix turn writes no failure_reason")
    eq(transitioned_to(env, "failed"), false, "a discarded fix turn never fails the task")
    has(note_text(env), "review fix turn discarded",
      "the discarded fix turn is journaled as a note")
    eq(result and result.ok, true, "the stale review result does not fail the task")
    eq(result and result.skipped, true, "the stale review result is skipped")
  end
end
