-- Tests for the slot contract of retry and resume in runtime.lua.
--
-- Regression: `runtime.retry` pushed its run straight into the scheduler's
-- extra queue and `runtime.resume` re-dispatched through `pipeline.resume`'s
-- callback, so neither consulted how many tasks were already in flight. Four
-- tasks ended up active at once with `project.max_parallel = 1`, their checks
-- raced on the harness's fixed paths, and healthy tasks failed with
-- "checks_failed" for no reason of their own.
--
-- The contract these cases pin:
--   * neither a retry nor a resume starts a task on its own authority: the task
--     is parked with the persisted `slot_wait` / `slot_wait_since` fields and
--     the drain (`pipeline.tick`) dispatches it once a slot is free;
--   * the task keeps its original status and phase while it waits, so a task
--     interrupted in `reviewing` stays `reviewing`; the wait is not a failure
--     and never writes `failure_reason`;
--   * the wait is journaled and survives a replay, and the dispatch clears both
--     fields in the same transition;
--   * the drain is the single dispatch authority and moves a task to `running`
--     before spawning it, so two retries cannot both take the last slot;
--   * `metronome_status` names the wait for a human: the unmet dependency
--     first, then the slot.
--
-- `spawn` queues its job instead of running it: the test decides when a drain
-- or a task runs, which is what makes "not before the slot frees" observable.

return function()
  local runtime = load_module("runtime")
  local pipeline = load_module("pipeline")
  local state = load_module("state")
  local recover_mod = load_module("recover")

  local base = maki.env.state_dir()
  local root = maki.fs.joinpath(base, "metronome-tests", "runtime-slot")
  local config = maki.fs.joinpath(root, "config.toml")

  local paths = {
    repo = "/tmp/repo",
    root = root,
    tasks = maki.fs.joinpath(root, "tasks"),
    worktrees = maki.fs.joinpath(root, "worktrees"),
    runs = maki.fs.joinpath(root, "runs"),
    prompts = maki.fs.joinpath(root, "prompts"),
    config = config,
  }

  -- A journal per case: the tests read the events the runtime wrote, so each
  -- case starts from an empty state.
  local function reset()
    local entries = maki.fs.dir(root)
    if entries then
      for _, entry in ipairs(entries) do
        maki.fs.rm(maki.fs.joinpath(root, entry[1]), { recursive = true })
      end
    end
    maki.fs.mkdir(root, { parents = true })
    maki.fs.write(config, "[project]\nrepo = \"/tmp/repo\"\nmax_parallel = 1\n")
  end

  local function journal_text()
    return maki.fs.read(maki.fs.joinpath(root, "state.jsonl")) or ""
  end

  local function journal_slot_wait(task_id)
    for line in journal_text():gmatch("[^\n]+") do
      local event = state.parse_line(line)
      if event and event.kind == "field" and event.task_id == task_id
        and type(event.fields) == "table" and event.fields.slot_wait == true then
        return event.fields.slot_wait_since
      end
    end
    return nil
  end

  local function journal_note(task_id, reason)
    for line in journal_text():gmatch("[^\n]+") do
      local event = state.parse_line(line)
      if event and event.kind == "note" and event.task_id == task_id
        and type(event.text) == "string" and event.text:find(reason, 1, true) then
        return true
      end
    end
    return false
  end

  -- A runtime wired like the scheduler's, with every step of the chain stubbed
  -- and a spawn queue the test pumps by hand.
  local function build(env)
    return runtime.new({
      config = {
        load = function()
          return {
            project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
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
      state = state,
      implement = {
        run = function(opts)
          local id = opts.task and opts.task.id or "?"
          env.calls[#env.calls + 1] = id
          -- What the cap actually protects: how many tasks are in flight at the
          -- moment the implementer opens its turn.
          local snapshot = state.load(root)
          local busy = 0
          for _, other in pairs(snapshot.tasks or {}) do
            if not other.slot_wait and (other.status == "running" or other.status == "verifying"
              or other.status == "reviewing" or other.status == "merging") then
              busy = busy + 1
            end
          end
          if busy > env.peak then
            env.peak = busy
          end
          -- A scripted failure, so a case can drive the real failure policy
          -- (the automatic retry and its backoff) without a real error.
          if type(env.fail_calls) == "number" and env.fail_calls > 0 then
            env.fail_calls = env.fail_calls - 1
            return { ok = false, error = env.fail_error or "timed out after 30s" }
          end
          return {
            ok = true,
            ctx = { worktree = "/tmp/wt-" .. id, branch = "metronome/" .. id },
            sha = "0123456",
          }
        end,
        read_sheet = function()
          return {}
        end,
      },
      checks = {
        verify = function() return { ok = true } end,
        write_report = function() end,
      },
      converge = { run = function() return { ok = true } end },
      review = {
        review = function() return { ok = true, approved = true, sha = "0123456" } end,
      },
      git = {
        pr_open = function()
          return { number = 1, url = "https://example.test/pr/1", state = "open" }
        end,
      },
      merge = { run = function() return { ok = true } end },
      deploy = { run = function() return { ok = true } end },
      pipeline = pipeline,
      paths = function() return paths end,
      spawn = function(fn)
        env.queue[#env.queue + 1] = fn
        return { cancel = function() end }
      end,
      -- A timer the test owns: an automatic retry's backoff lands here and fires
      -- only when the case decides, which is what makes the race with a human
      -- retry observable. Without a case-supplied timer the real fallback (an
      -- immediate retry) is left in place.
      defer = type(env.defer) == "table" and function(fn, ms)
        env.defer[#env.defer + 1] = { fn = fn, ms = ms }
        return { cancel = function() end }
      end or nil,
      async = true,
      wait_turn_end = false,
      runner = { run = function() return { ok = true } end },
      qualify = {},
      questions = { round = function() return { questions = {} } end },
      analyze = { gate = function() return { ok = true } end },
      calibrate = {}, fence = {}, mode = {},
    })
  end

  -- Run exactly one queued spawn: a drain, or one task's run.
  local function pump_one(env)
    local fn = table.remove(env.queue, 1)
    if not fn then
      return false
    end
    fn()
    return true
  end

  local function pump_all(env)
    local guard = 0
    while pump_one(env) do
      guard = guard + 1
      if guard > 200 then
        fail("the scheduler queue never emptied")
        return
      end
    end
  end

  -- Pump until the implementer has been called `target` times, so a test can
  -- observe the one call without letting the whole pipeline run on.
  local function pump_calls(env, target)
    local guard = 0
    while #env.calls < target and pump_one(env) do
      guard = guard + 1
      if guard > 200 then
        fail("the implementer was never called " .. target .. " time(s)")
        return
      end
    end
  end

  local function new_env()
    return { calls = {}, queue = {}, peak = 0 }
  end

  local function create_running(id, title)
    local task, err = state.create(root, {
      id = id,
      title = title,
      status = "running",
      phase = "implement",
      files = { "src/" .. id:sub(-4) .. ".lua" },
      checks = { "true" },
      branch = "metronome/" .. id,
      worktree = "/tmp/wt-" .. id,
    })
    eq(task ~= nil, true, "a running task is seeded: " .. tostring(err))
    return task
  end

  local function create_failed(id, title)
    local task, err = state.create(root, {
      id = id,
      title = title,
      status = "failed",
      phase = "review",
      files = { "src/" .. id:sub(-4) .. ".lua" },
      checks = { "true" },
      branch = "metronome/" .. id,
      worktree = "/tmp/wt-" .. id,
      run_dir = "/tmp/runs/" .. id,
      checkpoints = { "abcdef1" },
      failure_reason = "checks exited 1",
      failure = {
        cause = "network",
        message = "boom",
        remedy = "retry once the network is back",
        transient = true,
        attempts = 2,
      },
    })
    eq(task ~= nil, true, "a failed task is seeded: " .. tostring(err))
    return task
  end

  -- A retry while another task is in flight waits for the slot --------------
  --
  -- The reproduction: one task running, one retried, `max_parallel = 1`. The
  -- retry must not open an implementer turn; the task is parked with its
  -- original status and phase and the persisted `slot_wait` flag, and the drain
  -- that runs once the slot frees starts it exactly once.
  reset()
  local env1 = new_env()
  local rt1 = build(env1)
  local A = "T-20261122-0001"
  local B = "T-20261122-0002"
  create_running(A, "deja en vol")
  create_failed(B, "a reprendre")

  local retried = rt1.retry({ id = B }, { session = "S1" })
  eq(type(retried), "table", "the retry returns a result")
  eq(retried and retried.ok, true, "the retry is accepted")
  eq(#env1.calls, 0, "the retry opens no implementer turn on its own authority")
  eq(retried and retried.requeued, true, "the retry queues the task instead of starting it")
  eq(retried and retried.waiting, true, "the retry reports that it is waiting")
  has(tostring(retried and retried.wait_reason), pipeline.WAIT_SLOT,
    "the retry names the slot wait")

  local queued = state.load(root).tasks
  eq(queued[B].status, "failed", "the waiting task keeps its original status")
  eq(queued[B].phase, "review", "the waiting task keeps its original phase")
  eq(queued[B].slot_wait, true, "the wait is persisted as a task field")
  eq(type(queued[B].slot_wait_since), "string", "the wait carries its timestamp")
  eq(queued[B].failure_reason, "checks exited 1",
    "a slot wait never overwrites the failure reason")
  eq(queued[B].branch, "metronome/" .. B, "the wait keeps the branch")
  eq(queued[B].worktree, "/tmp/wt-" .. B, "the wait keeps the worktree")
  eq(queued[B].run_dir, "/tmp/runs/" .. B, "the wait keeps the run directory")
  eq(queued[B].checkpoints and queued[B].checkpoints[1], "abcdef1",
    "the wait keeps the checkpoints")
  eq(queued[B].failure and queued[B].failure.attempts, 0,
    "a human retry resets the attempt budget")
  eq(type(journal_slot_wait(B)), "string", "the wait is journaled as a field event")
  eq(journal_note(B, pipeline.WAIT_SLOT), true,
    "the wait is journaled with the named reason")

  -- The wait survives a replay: nothing about it is kept in memory.
  local replayed = state.replay(journal_text()).tasks[B]
  eq(replayed and replayed.slot_wait, true, "the replay finds the slot wait again")
  eq(replayed and type(replayed.slot_wait_since), "string",
    "the replay keeps the wait timestamp")
  eq(replayed and replayed.status, "failed", "the replay keeps the original status")
  eq(replayed and replayed.phase, "review", "the replay keeps the original phase")

  -- metronome_status names the wait for a human -----------------------------
  local waiting_view = rt1.status({ id = B })
  eq(waiting_view and waiting_view.ok, true, "status reads the waiting task")
  local view = waiting_view and waiting_view.task or {}
  has(tostring(view.wait_reason), pipeline.WAIT_SLOT, "the status names the slot wait")
  has(tostring(view.wait_reason), "max_parallel 1", "the status names the cap")
  has(tostring(view.wait_reason), "1 in flight", "the status names how many are in flight")
  eq(type(view.slot_wait), "table", "the status carries the structured slot wait")
  eq(view.slot_wait and view.slot_wait.reason, pipeline.WAIT_SLOT,
    "the structured wait carries the named reason")
  eq(view.slot_wait and view.slot_wait.in_flight, 1, "the structured wait counts what is in flight")
  eq(view.slot_wait and view.slot_wait.max_parallel, 1, "the structured wait names the cap")

  -- A dependency is named before the slot: it would hold the task even with an
  -- empty pipeline.
  local D = "T-20261122-0004"
  state.create(root, {
    id = D,
    title = "depend de A",
    status = "ready",
    files = { "src/0004.lua" },
    checks = { "true" },
    depends_on = { A },
  })
  local dependent = rt1.status({ id = D })
  has(tostring(dependent and dependent.task and dependent.task.wait_reason),
    "waiting on " .. A, "the status names the unmet dependency")
  eq(dependent and dependent.task and dependent.task.slot_wait, nil,
    "a dependency wait is not a slot wait")

  -- An active task does not claim a wait.
  local active = rt1.status({ id = A })
  eq(active and active.task and active.task.wait_reason, nil,
    "a running task reports no wait")
  eq(active and active.task and active.task.slot_wait, nil,
    "a running task reports no slot wait")

  -- The drain the retry armed finds no free slot: the task waits, no turn.
  pump_all(env1)
  eq(#env1.calls, 0, "a drain with no free slot opens no implementer turn")
  local still = state.load(root).tasks[B]
  eq(still.status, "failed", "the task still waits with its original status")
  eq(still.slot_wait, true, "the task still carries its persisted wait")

  -- The slot frees. A resume (the reload-time entry point) drains, and must not
  -- spawn anything on its own either.
  state.transition(root, A, "abandoned", { reason = "termine" })
  local resumed = rt1.resume()
  eq(resumed and resumed.ok, true, "the resume drains the queue")
  eq(#env1.calls, 0, "the resume spawns no task by itself")
  pump_calls(env1, 1)
  eq(#env1.calls, 1, "one drain after the slot frees starts the retried task exactly once")
  eq(env1.calls[1], B, "the task that starts is the retried one")
  eq(env1.peak <= 1, true, "never more than max_parallel tasks in flight")
  local dispatched = state.load(root).tasks[B]
  eq(dispatched.slot_wait, nil, "the dispatch clears slot_wait")
  eq(dispatched.slot_wait_since, nil, "the dispatch clears slot_wait_since")
  eq(dispatched.branch, "metronome/" .. B, "the dispatch keeps the branch")

  -- Two retries admitted with one free slot start exactly one --------------
  reset()
  local env2 = new_env()
  local rt2 = build(env2)
  local C = "T-20261122-0003"
  local E = "T-20261122-0005"
  create_failed(C, "premier retry")
  create_failed(E, "second retry")

  local first = rt2.retry({ id = C }, { session = "S1" })
  local second = rt2.retry({ id = E }, { session = "S1" })
  eq(first and first.ok, true, "the first retry is accepted")
  eq(second and second.ok, true, "the second retry is accepted")
  eq(first and first.waiting, nil, "the first retry finds a free slot")
  eq(second and second.waiting, nil, "the second retry finds a free slot")
  eq(first and first.wait_reason, nil,
    "a retry with a free slot is a plain hand-off, not a wait")
  eq(journal_note(C, "requeued for dispatch"), true,
    "the plain hand-off is journaled with its reason")
  eq(#env2.calls, 0, "neither retry opens an implementer turn on its own")
  local both = state.load(root).tasks
  eq(both[C].slot_wait, true, "the first retried task carries the wait field")
  eq(both[E].slot_wait, true, "the second retried task carries the wait field")
  eq(both[C].status, "failed", "the first task waits with its original status")
  eq(both[E].status, "failed", "the second task waits with its original status")

  -- One drain: the cap admits one candidate and the scheduler spawns only it.
  pump_one(env2)
  eq(#env2.calls, 0, "the drain spawns the task, it does not run it on its turn")
  local after_tick = state.load(root).tasks
  local started = nil
  for _, id in ipairs({ C, E }) do
    if after_tick[id].slot_wait == nil then
      started = started or id
    end
  end
  eq(started ~= nil, true, "exactly one of the two retried tasks is dispatched")
  local other = started == C and E or C
  eq(after_tick[started].status, "running", "the dispatched task is running")
  eq(after_tick[other].slot_wait, true, "the other retry still waits for the slot")
  eq(after_tick[other].status, "failed", "the other retry keeps its original status")

  -- The dispatched task runs: the two retries produced exactly one implementer
  -- turn so far, and the other task still waits.
  pump_calls(env2, 1)
  eq(#env2.calls, 1, "the two retries produce exactly one implementer turn")
  eq(env2.calls[1], started, "the turn belongs to the dispatched task")
  eq(state.load(root).tasks[other].slot_wait, true,
    "the second task still waits while the first one owns the slot")

  -- The slot frees, and the drain that follows starts the queued task.
  pump_all(env2)
  eq(#env2.calls, 2, "both retried tasks ran, one after the other")
  eq(env2.peak <= 1, true, "the two retries never run at the same time")

  -- A retry with nothing active starts on the drain it triggers -------------
  reset()
  local env3 = new_env()
  local rt3 = build(env3)
  local F = "T-20261122-0006"
  create_failed(F, "seul")

  local alone = rt3.retry({ id = F }, { session = "S1" })
  eq(alone and alone.ok, true, "the retry of an idle project is accepted")
  eq(alone and alone.waiting, nil, "a retry with nothing active does not wait")
  eq(alone and alone.wait_reason, nil,
    "an idle retry is a plain hand-off to the drain")
  eq(journal_note(F, "requeued for dispatch"), true,
    "the idle hand-off is journaled with its reason")
  eq(#env3.calls, 0, "the retry still does not start the task itself")
  eq(state.load(root).tasks[F].slot_wait, true, "the task is marked for dispatch")
  pump_calls(env3, 1)
  eq(#env3.calls, 1, "the retry is dispatched exactly once")
  eq(env3.calls[1], F, "the task that starts is the retried one")
  eq(env3.peak <= 1, true, "one task at a time is enough and all it needs")

  -- A retry on a task the scheduler already dispatched is refused -----------
  --
  -- The validation the tool always had is untouched by the wait.
  local again = rt3.retry({ id = F }, { session = "S1" })
  eq(again and again.ok, false, "a task that already left the queue cannot be retried again")
  has(tostring(again and again.error), "not failed", "the refusal names the status problem")

  -- A resume cannot admit two interrupted tasks for one slot ----------------
  --
  -- The resume keeps every interrupted task's original status and phase, marks
  -- the wait, and lets the drain dispatch one at a time.
  reset()
  local env4 = new_env()
  local rt4 = build(env4)
  local G = "T-20261122-0007"
  local H = "T-20261122-0008"
  create_running(G, "interrompu un")
  create_running(H, "interrompu deux")

  local resume4 = rt4.resume()
  eq(resume4 and resume4.ok, true, "the resume succeeds")
  eq(#env4.calls, 0, "the resume opens no implementer turn on its own")
  eq(type(resume4 and resume4.requeued), "table", "the resume reports the queued tasks")
  eq(#(resume4 and resume4.requeued or {}), 2, "both interrupted tasks are queued")
  eq(#(resume4 and resume4.waiting or {}) >= 1, true,
    "an interrupted task that finds no slot reports the wait")
  local resume_state = state.load(root).tasks
  eq(resume_state[G].status, "running", "the first task keeps its original status")
  eq(resume_state[H].status, "running", "the second task keeps its original status")
  eq(resume_state[G].slot_wait, true, "the first task carries the wait")
  eq(resume_state[H].slot_wait, true, "the second task carries the wait")
  local by_id = {}
  for _, entry in ipairs((resume4 and resume4.resumed) or {}) do
    by_id[entry.id] = entry
  end
  has(tostring(by_id[G] and by_id[G].wait_reason), pipeline.WAIT_SLOT,
    "the resume result names the slot wait")

  pump_calls(env4, 1)
  eq(#env4.calls, 1, "the drain starts exactly one resumed task")
  local resumed_state = state.load(root).tasks
  local started_resume = nil
  for _, id in ipairs({ G, H }) do
    if resumed_state[id].slot_wait == nil then
      started_resume = started_resume or id
    end
  end
  eq(started_resume ~= nil, true, "one resumed task is dispatched")
  local other_resume = started_resume == G and H or G
  eq(resumed_state[other_resume].slot_wait, true,
    "the other resumed task still waits for the slot")

  pump_all(env4)
  eq(env4.peak <= 1, true, "a resume never exceeds max_parallel")
  eq(#env4.calls >= 2, true, "the drain starts the other task once the slot frees")

  -- A parked retry disarms the automatic retry that was still armed ---------
  --
  -- A transient failure arms a deferred automatic retry. A human retry then
  -- parks the task as `failed` + `slot_wait` while another task holds the only
  -- slot. The delayed job must not walk the task to `running` and spawn it
  -- itself: that is the exact `max_parallel` bypass this task fixes, and it
  -- would also leave a running task still claiming the wait.
  reset()
  local env5 = new_env()
  env5.defer = {}
  env5.fail_calls = 1
  local rt5 = build(env5)
  local I = "T-20261122-0009"
  local J = "T-20261122-0010"
  create_failed(I, "echec transitoire")

  local retried5 = rt5.retry({ id = I }, { session = "S1" })
  eq(retried5 and retried5.ok, true, "the first retry is accepted")
  pump_calls(env5, 1)
  eq(#env5.calls, 1, "the retried task ran once and failed transiently")
  local failed_once = state.load(root).tasks[I]
  eq(failed_once.status, "failed", "the transient failure leaves the task failed")
  eq(#env5.defer, 1, "the transient failure arms one deferred automatic retry")
  eq(env5.defer[1].ms > 0, true, "the automatic retry waits for its backoff")
  eq(env5.defer[1].fn ~= nil, true, "the backoff job is held for the test to fire")

  -- Another task now occupies the only slot.
  create_running(J, "occupe le seul slot")

  -- The human retry parks the failed task: its status stays `failed`, so the
  -- delayed job's status-only guard would let it through.
  local parked = rt5.retry({ id = I }, { session = "S1" })
  eq(parked and parked.ok, true, "the human retry is accepted")
  eq(parked and parked.waiting, true, "the human retry waits for the slot")
  local parked_task = state.load(root).tasks[I]
  eq(parked_task.status, "failed", "the parked task keeps its original status")
  eq(parked_task.slot_wait, true, "the parked task carries the persisted wait")

  -- Fire the armed automatic retry: it must stand down. The timer only enqueues
  -- the job; the drain the enqueue arms is what would run it, so pump it.
  env5.defer[1].fn()
  pump_all(env5)
  eq(#env5.calls, 1, "the delayed automatic retry opens no implementer turn")
  local after_job = state.load(root).tasks[I]
  eq(after_job.status, "failed", "the delayed automatic retry does not move the task to running")
  eq(after_job.slot_wait, true, "the delayed automatic retry does not clear the wait")
  eq(after_job.failure_reason, parked_task.failure_reason,
    "the delayed automatic retry does not rewrite the failure reason")

  -- The slot frees: the drain dispatches the parked task exactly once and the
  -- dispatch clears both wait fields in the same transition.
  state.transition(root, J, "abandoned", { reason = "termine" })
  rt5.resume()
  pump_all(env5)
  eq(#env5.calls, 2, "the parked task starts exactly once when the slot frees")
  eq(env5.calls[2], I, "the task that starts is the parked one")
  eq(env5.peak <= 1, true, "the parked retry never exceeds max_parallel")
  local dispatched5 = state.load(root).tasks[I]
  eq(dispatched5.slot_wait, nil, "the dispatch clears slot_wait")
  eq(dispatched5.slot_wait_since, nil, "the dispatch clears slot_wait_since")
end
