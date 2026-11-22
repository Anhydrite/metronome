-- Tests for the background drain in maki/lua/metronome/runtime.lua.
--
-- Regression (T-20261122-002e): `dispatch_one` set `scheduler_dirty` and then
-- spawned `run_pending`, but that spawned call returned immediately because
-- `scheduler_running` was still true. The exiting drain cleared the flag and
-- returned without re-reading it, so a task that finished in the exit window
-- freed a slot nobody refilled: the scheduler stopped without an alert.
--
-- The drain now takes its decision AFTER `scheduler_running = false`: a wake
-- that landed in the exit window re-enters the drain instead of being dropped,
-- and the re-entry is bounded so a pathological dirty-setter cannot spin.
--
-- The race is made deterministic with the `deps.spawn` seam: submit hands the
-- drain to `spawn` instead of running it, and the drain hands each selected task
-- to `spawn` too. `deps.scheduler_exit` runs exactly where the window is: after
-- the drain body has drained everything (its inner loop already evaluated
-- false) and before `scheduler_running` is cleared.

return function()
  local runtime = load_module("runtime")

  local root = mktmpdir("metronome-runtime-scheduler")
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

  -- A scheduler harness: real submit/drain machinery, stubbed pipeline, task and
  -- analysis modules, and a spawn seam that can defer a callback so a test can
  -- place it exactly where it wants it.
  local function make_harness(opts)
    opts = opts or {}
    local obs = {
      gate_calls = 0,
      ticks = 0,
      dispatched = {},
      deferred = {},
      defer = true,
      exit_wakes = opts.exit_wakes or 0,
      tasks = opts.tasks or {
        T1 = { id = "T1", status = "ready", title = "un", checks = { "true" } },
        T2 = { id = "T2", status = "ready", title = "deux", checks = { "true" } },
      },
    }

    local deps = {
      config = {
        load = function()
          return {
            project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
            checks = { default = { "true" }, timeout_secs = 10 },
            merge = { method = "squash", auto_merge = false },
            deploy = { auto_deploy = false, plan_file = "deploy.md" },
          }
        end,
      },
      roles = {
        session_opts = function()
          return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
        end,
      },
      state = {
        load = function()
          return { tasks = obs.tasks }
        end,
        transition = function(_, id, status)
          return { id = id, status = status }
        end,
        set_fields = function()
          return true
        end,
      },
      qualify = {
        next_id = function()
          return "T-1"
        end,
        apply = function()
          return { ok = true, tasks = { { id = "T1", title = "un" } } }
        end,
      },
      questions = { round = function() return nil end },
      analyze = {
        gate = function()
          obs.gate_calls = obs.gate_calls + 1
          return { ok = true }
        end,
      },
      pipeline = {
        tick = function(tick_opts)
          obs.ticks = obs.ticks + 1
          return opts.tick(tick_opts, obs)
        end,
      },
      implement = {
        run = function()
          return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
        end,
        read_sheet = function() return {} end,
        slug = function(text, max)
          local out = tostring(text):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
          if max and #out > max then out = out:sub(1, max):gsub("%-+$", "") end
          return out
        end,
      },
      checks = { verify = function() return { ok = true } end, write_report = function() end },
      converge = { run = function() return { ok = true } end },
      review = { review = function() return { ok = true, approved = true } end },
      git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
      merge = { run = function() return { ok = true } end },
      deploy = { run = function() return { ok = true, deployed = true } end },
      calibrate = {}, fence = {}, mode = {},
      runner = {},
      async = true,
      wait_turn_end = false,
      paths = function() return paths end,
      spawn = function(fn)
        if obs.defer then
          obs.deferred[#obs.deferred + 1] = fn
          return {}
        end
        return fn()
      end,
    }

    if opts.exit_wakes then
      -- The exit window. A task dispatched by the drain finishes here: its
      -- completion sets `scheduler_dirty` and spawns its own `run_pending`,
      -- which is refused because the drain still holds `scheduler_running`.
      deps.scheduler_exit = function()
        if obs.exit_wakes <= 0 then
          return
        end
        obs.exit_wakes = obs.exit_wakes - 1
        if opts.exit_action then
          opts.exit_action(obs, deps)
          return
        end
        local finish = table.remove(obs.deferred, 1)
        if not finish then
          return
        end
        obs.gate_calls_at_wake = obs.gate_calls
        obs.defer = false
        finish()
        obs.defer = true
        obs.gate_calls_after_wake = obs.gate_calls
      end
    end

    return runtime.new(deps), obs
  end

  -- The race: a wake that lands while the drain is exiting is not lost ------
  --
  -- Pass 1 drains everything and dispatches T1 (the only ready task). Its inner
  -- loop then evaluates false; at that exact point T1 finishes. T1's follow-up
  -- drain is refused, so only `scheduler_dirty` is left behind. The drain must
  -- re-read it after dropping `scheduler_running` and refill the freed slot.
  local rt_race, obs_race = make_harness({
    exit_wakes = 1,
    tick = function(tick_opts, o)
      if o.ticks == 1 then
        o.dispatched[#o.dispatched + 1] = "T1"
        tick_opts.dispatch({ id = "T1" })
        return { ok = true, started = { "T1" } }
      end
      if o.ticks == 3 then
        -- The freed slot: T2 is ready now that T1 finished.
        o.dispatched[#o.dispatched + 1] = "T2"
        tick_opts.dispatch({ id = "T2" })
        return { ok = true, started = { "T2" } }
      end
      return { ok = true, started = {} }
    end,
  })
  local submitted = rt_race.submit({ intention = "one thing", fast = true }, { session = "S1" })
  eq(type(submitted), "table", "submit returns a result")
  eq(submitted and submitted.ok, true, "submit queues the work")
  -- The drain went through the spawn seam: run it by hand to control ordering.
  local drain = table.remove(obs_race.deferred, 1)
  eq(type(drain), "function", "submit hands the drain to the spawn seam")
  drain()

  eq(obs_race.gate_calls_at_wake, 1,
    "the wake lands after the first pass drained everything (one gate call)")
  eq(obs_race.gate_calls_after_wake, 1,
    "the finishing task's own drain request is refused while the drain exits")
  eq(obs_race.gate_calls, 2, "the exit-window wake re-enters the drain")
  eq(obs_race.dispatched[1], "T1", "the first pass dispatches the ready task")
  eq(#obs_race.dispatched, 2, "the freed slot is refilled instead of lost")
  eq(obs_race.dispatched[2], "T2", "the second pass dispatches the newly ready task")

  -- A normal drain still terminates ----------------------------------------
  --
  -- Nothing sets `scheduler_dirty`: the body runs once and `run_pending`
  -- returns. No extra pass, no pending work, no suspended coroutine.
  local rt_idle, obs_idle = make_harness({
    tick = function(tick_opts, o)
      if o.ticks == 1 then
        o.dispatched[#o.dispatched + 1] = "T1"
        tick_opts.dispatch({ id = "T1" })
        return { ok = true, started = { "T1" } }
      end
      return { ok = true, started = {} }
    end,
  })
  rt_idle.submit({ intention = "one thing", fast = true }, { session = "S1" })
  local idle_drain = table.remove(obs_idle.deferred, 1)
  eq(type(idle_drain), "function", "submit hands the idle drain to the spawn seam")
  idle_drain()
  eq(obs_idle.gate_calls, 1, "an idle drain runs the body exactly once")
  eq(obs_idle.ticks, 2, "an idle drain ticks until nothing is ready, then stops")
  eq(#obs_idle.dispatched, 1, "an idle drain dispatches once")
  eq(rt_idle.has_pending(), false, "an idle drain leaves nothing pending")
  eq(#obs_idle.deferred, 1,
    "the dispatched task is still queued: the drain did not wait on it or spin")

  -- A pathological dirty-setter is bounded ---------------------------------
  --
  -- A wake that re-arms the scheduler on every exit pass would spin forever.
  -- The drain stops after a fixed number of passes, logs why, and leaves the
  -- work pending for the poller instead of dropping it silently.
  local rt_spin, obs_spin = make_harness({
    tasks = { T1 = { id = "T1", status = "failed", title = "un", checks = { "true" } } },
    exit_wakes = 1000,
    -- Every pass re-arms the scheduler from a completion path: `retry` queues
    -- the task again and marks the scheduler dirty, so the queue never settles.
    exit_action = function(obs)
      obs.spin_wakes = (obs.spin_wakes or 0) + 1
      if obs.retry then
        obs.retry()
      end
    end,
    tick = function()
      return { ok = true, started = {} }
    end,
  })
  rt_spin.submit({ intention = "one thing", fast = true }, { session = "S1" })
  local spin_drain = table.remove(obs_spin.deferred, 1)
  obs_spin.retry = function()
    return rt_spin.retry({ id = "T1" }, { session = "S1" })
  end
  spin_drain()
  eq(type(obs_spin.spin_wakes), "number", "the runaway wake-up loop ran")
  eq(obs_spin.spin_wakes < 1000, true, "the drain stopped well before every wake ran")
  has(maki.fs.read(maki.fs.joinpath(root, "runtime.log")) or "",
    "background scheduler: stopping after", "a runaway wake-up loop is logged")
  eq(rt_spin.has_pending(), true, "the bounded drain leaves the work for the poller")
end
