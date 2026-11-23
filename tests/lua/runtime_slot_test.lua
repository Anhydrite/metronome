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
--     goes back to `ready` and the drain dispatches it;
--   * the drain (`pipeline.tick`) is the single dispatch authority and moves a
--     task to `running` before spawning it, so admission is atomic — two
--     retries cannot both take the last slot;
--   * the requeue keeps every artefact a restart needs and is journaled with the
--     named reason, without adding a task field;
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

  local function journal_has(task_id, status, reason)
    for line in journal_text():gmatch("[^\n]+") do
      local event = state.parse_line(line)
      if event and event.kind == "status" and event.task_id == task_id
        and event.status == status and type(event.reason) == "string"
        and event.reason:find(reason, 1, true) then
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
            if other.status == "running" or other.status == "verifying"
              or other.status == "reviewing" or other.status == "merging" then
              busy = busy + 1
            end
          end
          if busy > env.peak then
            env.peak = busy
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

  local function new_env()
    return { calls = {}, queue = {}, peak = 0 }
  end

  local function create_running(id, title)
    local task, err = state.create(root, {
      id = id,
      title = title,
      status = "running",
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
      files = { "src/" .. id:sub(-4) .. ".lua" },
      checks = { "true" },
      branch = "metronome/" .. id,
      worktree = "/tmp/wt-" .. id,
      run_dir = "/tmp/runs/" .. id,
      checkpoints = { "abcdef1" },
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
  -- retry must not open an implementer turn; the task waits in `ready`, and the
  -- drain that runs once the slot frees starts it exactly once.
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
  eq(retried and retried.requeued, true, "the retry requeues the task instead of starting it")
  eq(retried and retried.waiting, true, "the retry reports that it is waiting")
  has(tostring(retried and retried.wait_reason), pipeline.WAIT_SLOT,
    "the retry names the slot wait")

  local queued = state.load(root).tasks
  eq(queued[B].status, "ready", "the retried task is back in the queue")
  eq(queued[B].phase, "implement", "the requeue asks for the implement phase")
  eq(queued[B].branch, "metronome/" .. B, "the requeue keeps the branch")
  eq(queued[B].worktree, "/tmp/wt-" .. B, "the requeue keeps the worktree")
  eq(queued[B].run_dir, "/tmp/runs/" .. B, "the requeue keeps the run directory")
  eq(queued[B].checkpoints and queued[B].checkpoints[1], "abcdef1",
    "the requeue keeps the checkpoints")
  eq(queued[B].failure and queued[B].failure.attempts, 0,
    "a human retry resets the attempt budget")
  eq(journal_has(B, "ready", pipeline.WAIT_SLOT), true,
    "the waiting transition is journaled with the named reason")

  -- metronome_status names the wait for a human -----------------------------
  --
  -- No task field was added for it: the view computes it from the projection.
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
  eq(state.load(root).tasks[B].status, "ready", "the task waits for the slot")

  -- The slot frees. A resume (the reload-time entry point) drains, and must not
  -- spawn anything on its own either.
  state.transition(root, A, "failed", { reason = "fini", phase = "implement" })
  local resumed = rt1.resume()
  eq(resumed and resumed.ok, true, "the resume drains the queue")
  eq(#env1.calls, 0, "the resume spawns no task by itself")
  pump_all(env1)
  eq(#env1.calls, 1, "one drain after the slot frees starts the retried task exactly once")
  eq(env1.calls[1], B, "the task that starts is the retried one")
  eq(env1.peak <= 1, true, "never more than max_parallel tasks in flight")

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
  eq(#env2.calls, 0, "neither retry opens an implementer turn on its own")
  local both = state.load(root).tasks
  eq(both[C].status, "ready", "the first retried task is queued")
  eq(both[E].status, "ready", "the second retried task is queued")
  eq(journal_has(C, "ready", "requeued for dispatch"), true,
    "a requeue with a free slot is journaled as a plain hand-off")

  -- One drain: the cap admits one candidate and the scheduler spawns only it.
  pump_one(env2)
  eq(#env2.calls, 0, "the drain spawns the task, it does not run it on its turn")
  local after_tick = state.load(root).tasks
  local started = nil
  for _, id in ipairs({ C, E }) do
    if after_tick[id].status == "running" then
      started = started or id
    end
  end
  eq(started ~= nil, true, "exactly one of the two retried tasks is dispatched")
  local other = started == C and E or C
  eq(after_tick[other].status, "ready", "the other retry stays in the queue")

  -- The second drain armed by the two retries finds no slot.
  pump_one(env2)
  eq(#env2.calls, 0, "the second drain admits nothing: the slot is taken")

  -- The dispatched task runs: the two retries produced one implementer turn,
  -- and the other task is still queued.
  pump_one(env2)
  eq(#env2.calls, 1, "the two retries produce exactly one implementer turn")
  eq(env2.calls[1], started, "the turn belongs to the dispatched task")
  eq(state.load(root).tasks[other].status, "ready",
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
  eq(#env3.calls, 0, "the retry still does not start the task itself")
  eq(state.load(root).tasks[F].status, "ready", "the task is queued for the drain")
  pump_all(env3)
  eq(#env3.calls, 1, "the retry is dispatched exactly once")
  eq(env3.calls[1], F, "the task that starts is the retried one")
  eq(env3.peak <= 1, true, "one task at a time is enough and all it needs")

  -- A retry on a task the scheduler already dispatched is refused -----------
  --
  -- The validation the tool always had is untouched by the requeue.
  local again = rt3.retry({ id = F }, { session = "S1" })
  eq(again and again.ok, false, "a task that already left the queue cannot be retried again")
  has(tostring(again and again.error), "not failed", "the refusal names the status problem")

  -- A resume that cannot admit a task requeues it, it does not spawn it -----
  --
  -- Two interrupted tasks, cap 1: the resume walks them back through legal
  -- transitions, but the dispatch must go through the drain. One is requeued
  -- with the named slot wait and reported as such in the result.
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
  eq(type(resume4 and resume4.requeued), "table", "the resume reports the requeues")
  eq(#(resume4 and resume4.requeued or {}), 2, "both interrupted tasks are requeued")
  local refused = (resume4 and resume4.waiting) or {}
  eq(#refused, 1, "one resumed task cannot be admitted: the cap is already taken")
  local by_id = {}
  for _, entry in ipairs((resume4 and resume4.resumed) or {}) do
    by_id[entry.id] = entry
  end
  local waiting_id = refused[1]
  eq(by_id[waiting_id] and by_id[waiting_id].waiting, true,
    "the resume result marks the waiting task")
  has(tostring(by_id[waiting_id] and by_id[waiting_id].wait_reason), pipeline.WAIT_SLOT,
    "the resume result names the slot wait")
  local resumed_status = state.load(root).tasks
  eq(resumed_status[waiting_id].status, "ready",
    "the task without a slot is back in the queue, not started")
  eq(journal_has(waiting_id, "ready", pipeline.WAIT_SLOT), true,
    "the resume requeue is journaled with the named reason")

  pump_all(env4)
  eq(env4.peak <= 1, true, "a resume never exceeds max_parallel")
  eq(#env4.calls >= 1, true, "the drain the resume armed starts a task")
end
