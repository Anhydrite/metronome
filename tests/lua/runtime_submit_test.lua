-- Tests for the submit context plumbing in maki/lua/metronome/runtime.lua.
--
-- Regression: tools.lua forwards the maki `ctx` as the *second* argument to
-- the runtime method, but `runtime.submit` only accepted `input` and read
-- `input.ctx` (always nil). The qualifier then called `maki.agent.session(nil,
-- ...)` and every submit died with "error converting Lua nil to
-- Either<UserDataRef<LuaCtx>, Table>". These tests pin the contract: the
-- positional ctx wins, `input.ctx` is a fallback, and a missing ctx does not
-- crash the run.

return function()
  local runtime = load_module("runtime")

  local root = mktmpdir("metronome-runtime-submit")
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

  local captured
  local ticked = false
  local deps = {
    config = {
      load = function()
        return { project = { repo = "/tmp/repo", base_ref = "main" } }
      end,
    },
    roles = {
      session_opts = function()
        return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
      end,
    },
    qualify = {
      run = function(opts)
        captured = opts
        return { ok = false, error = "stop after capture" }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    questions = {
      answer = function()
        return { applied = 1, answered = 1, tasks = { "T-20261114-0001" } }
      end,
    },
    analyze = {
      gate = function()
        return { ok = true }
      end,
    },
    pipeline = {
      tick = function()
        ticked = true
        return { ok = true, started = {} }
      end,
    },
    state = {
      load = function()
        return { tasks = {} }
      end,
    },
    runner = {}, git = {}, implement = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {},
  }

  local rt = runtime.new(deps)
  eq(type(rt), "table", "runtime wires with injected deps")

  -- Positional ctx (the tools.lua path) -------------------------------------

  local ctx = { marker = "positional" }
  captured = nil
  local res = rt.submit({ intention = "add an icon", fast = false }, ctx)
  eq(type(res), "table", "submit returns a result table")
  eq(res and res.error, "stop after capture",
    "submit waits for qualification and returns its result")
  eq(type(captured), "table", "qualify.run was called")
  eq(captured and captured.ctx, ctx, "submit forwards the positional ctx to qualify")

  -- Fast lane: a short, unambiguous intention skips the qualifier ----------

  local fast_applied
  deps.qualify.next_id = function()
    return "T-fast"
  end
  deps.qualify.apply = function(_, _, result)
    fast_applied = result
    return { ok = true, tasks = { { id = "T-fast", title = result.tasks[1].title } } }
  end
  captured = nil
  local fast = rt.submit({ intention = "add a red button" }, ctx)
  eq(fast and fast.fast, true, "short intention uses the fast lane")
  eq(captured, nil, "fast lane does not call the qualifier")
  eq(fast_applied and fast_applied.tasks and #fast_applied.tasks, 1, "fast lane creates one task")
  eq(fast_applied and fast_applied.tasks[1].files and #fast_applied.tasks[1].files, 0,
    "fast task declares no files, the implementer chooses them")
  eq(fast_applied and fast_applied.tasks[1].checks and #fast_applied.tasks[1].checks, 0,
    "fast task uses the project default checks")

  -- wait = false returns at once with queued = true -------------------------

  captured = nil
  local queued = rt.submit({ intention = "add an icon", wait = false, fast = false }, ctx)
  eq(queued and queued.queued, true, "wait=false returns at once with queued=true")

  -- input.ctx fallback ------------------------------------------------------

  local input_ctx = { marker = "input" }
  captured = nil
  rt.submit({ intention = "add an icon", ctx = input_ctx, fast = false })
  eq(captured and captured.ctx, input_ctx, "submit falls back to input.ctx")

  -- No ctx at all must not crash -------------------------------------------

  captured = nil
  local bare = rt.submit({ intention = "add an icon", fast = false })
  eq(type(bare), "table", "submit without a ctx returns a result table")
  eq(rt.last_submit and rt.last_submit.error, "stop after capture",
    "submit without a ctx still reaches the qualifier")

  -- resolve_ctx is the pure seam -------------------------------------------

  eq(type(runtime.resolve_ctx), "function", "runtime exposes resolve_ctx")
  eq(runtime.resolve_ctx({}, ctx), ctx, "resolve_ctx prefers the positional ctx")
  eq(runtime.resolve_ctx({ ctx = input_ctx }), input_ctx, "resolve_ctx reads input.ctx")

  -- Answering resumes the pipeline -----------------------------------------

  local ans = rt.answer({ answers = { q1 = "yes" } }, ctx)
  rt.run_pending()
  eq(ans and ans.ok, true, "answer resumes the pipeline")
  eq(ans and ans.applied and ans.applied.applied, 1, "answer reports the applied count")
  eq(ticked, true, "answer runs the scheduler instead of leaving tasks in qualifying")

  -- Qualification remaps dependency titles to task ids ---------------------

  local set_fields = {}
  local deps2 = {
    config = {
      load = function()
        return { project = { repo = "/tmp/repo", base_ref = "main" } }
      end,
    },
    roles = {
      session_opts = function()
        return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
      end,
    },
    qualify = {
      run = function()
        return { ok = true, tasks = {
          { title = "Icon", intent = "i", files = { "a" }, checks = {}, acceptance = {}, depends_on = {} },
          { title = "Page", intent = "p", files = { "b" }, checks = {}, acceptance = {}, depends_on = { "Icon" } },
        } }
      end,
      next_id = function()
        return "T-1"
      end,
      apply = function()
        return { ok = true, tasks = {
          { id = "T-1", title = "Icon" },
          { id = "T-2", title = "Page", depends_on = { "Icon" } },
        } }
      end,
    },
    questions = {
      round = function()
        return nil
      end,
    },
    analyze = {
      gate = function()
        return { ok = true }
      end,
    },
    pipeline = {
      tick = function()
        return { ok = true, started = {} }
      end,
    },
    state = {
      load = function()
        return { tasks = {} }
      end,
      set_fields = function(_, id, fields)
        set_fields[id] = fields
        return { id = id }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    runner = {}, git = {}, implement = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {},
  }
  local rt2 = runtime.new(deps2)
  local res2 = rt2.submit({ intention = "x", fast = false }, ctx)
  rt2.run_pending()
  eq(type(res2), "table", "submit with dependencies returns a result")
  eq(set_fields["T-2"] and set_fields["T-2"].depends_on and set_fields["T-2"].depends_on[1], "T-1",
    "dependency titles are remapped to task ids")

  -- Retry re-dispatches the task -------------------------------------------

  local implemented = false
  local deps3 = {
    config = {
      load = function()
        return { project = { repo = "/tmp/repo", base_ref = "main" } }
      end,
    },
    roles = {
      session_opts = function()
        return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
      end,
    },
    implement = {
      run = function()
        implemented = true
        return { ok = false, error = "stop after dispatch" }
      end,
    },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = "failed" } } }
      end,
      transition = function(_, id, status)
        return { id = id, status = status }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    runner = {}, git = {}, qualify = {}, questions = {}, analyze = {},
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    calibrate = {}, pipeline = {}, fence = {}, mode = {},
  }
  local rt3 = runtime.new(deps3)
  local retried = rt3.retry({ id = "T1" }, ctx)
  rt3.run_pending()
  eq(type(retried), "table", "retry returns a result")
  eq(retried and retried.background, true, "retry returns before the dispatch finishes")
  eq(rt3.last_background and rt3.last_background.error, "stop after dispatch",
    "retry reports the dispatch result on the background record")
  eq(implemented, true, "retry re-dispatches the task instead of only moving its status")

  -- The role runner receives the background ctx of the task it runs ---------
  --
  -- Regression: `real_runner` was built once in `prepare`, before
  -- `background_ctx` turned the tool ctx into `{ session = sid }`, and read
  -- only the captured `opts.ctx`. The implementer then opened its session with
  -- the tool's LuaCtx, which the turn cancelled at once (duration_ms 0). The
  -- ctx carried by the request must win.
  local runner_ctx
  local retry_status = "failed"
  local deps4 = {
    config = {
      load = function()
        return { project = { repo = "/tmp/repo", base_ref = "main" } }
      end,
    },
    roles = {
      session_opts = function()
        return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
      end,
    },
    runner = {
      run = function(opts)
        runner_ctx = opts.ctx
        return { ok = false, error = "stop after capture" }
      end,
    },
    implement = {
      run = function(opts)
        opts.runner({ role = "implementer", task_id = "T1", phase = "implement", ctx = opts.ctx })
        return { ok = false, error = "stop after dispatch" }
      end,
    },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = retry_status } } }
      end,
      transition = function(_, id, status)
        return { id = id, status = status }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    qualify = {}, questions = {}, analyze = {},
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    calibrate = {}, pipeline = {}, fence = {}, mode = {}, git = {},
  }
  local rt4 = runtime.new(deps4)
  rt4.retry({ id = "T1" }, { session = "S1" })
  rt4.run_pending()
  eq(type(runner_ctx), "table", "the role runner receives a ctx table")
  eq(runner_ctx and runner_ctx.session, "S1",
    "the role runner receives the background session id, not the tool ctx")

  -- Retry also revives an abandoned task -----------------------------------
  retry_status = "abandoned"
  runner_ctx = nil
  rt4.retry({ id = "T1" }, { session = "S1" })
  rt4.run_pending()
  eq(type(runner_ctx), "table", "retry re-dispatches an abandoned task")

  -- Auto-deploy: the merger redeploys right after a green merge -------------
  local deploy_called = false
  local merge_called = false
  local auto_merge_flag = true
  local tick_count = 0
  local deps5 = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = auto_merge_flag },
          deploy = { auto_deploy = true, plan_file = "deploy.md" },
        }
      end,
    },
    roles = {
      session_opts = function()
        return { system = "", model_spec = "m", thinking = "low", tools = {} }
      end,
    },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } } }
      end,
      transition = function(_, id, status)
        return { id = id, status = status }
      end,
    },
    implement = {
      run = function()
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
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
    review = { review = function() return { ok = true, approved = true } end },
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = {
      run = function()
        merge_called = true
        return { ok = true }
      end,
    },
    deploy = {
      run = function()
        deploy_called = true
        return { ok = true, deployed = true }
      end,
    },
    pipeline = {
      tick = function(opts)
        tick_count = tick_count + 1
        if tick_count == 1 then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = tick_count == 1 and { "T1" } or {} }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    runner = {},
    qualify = {
      run = function()
        return { ok = true, tasks = { { title = "t", files = { "f" }, checks = { "true" } } } }
      end,
      next_id = function()
        return "T1"
      end,
      apply = function()
        return { ok = true, tasks = { { id = "T1", title = "t" } } }
      end,
    },
    questions = {
      round = function()
        return { questions = {} }
      end,
      answer = function()
        return {}
      end,
    },
    analyze = {
      gate = function()
        return { ok = true }
      end,
    },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt5 = runtime.new(deps5)
  rt5.submit({ intention = "x", fast = false }, { session = "S1" })
  rt5.run_pending()
  eq(deploy_called, true, "auto_deploy redeploys right after the merge")

  -- auto_merge off: the task stops at pr_open and nothing merges or deploys --
  auto_merge_flag = false
  deploy_called = false
  merge_called = false
  tick_count = 0
  local rt6 = runtime.new(deps5)
  rt6.submit({ intention = "x", fast = false }, { session = "S1" })
  rt6.run_pending()
  eq(merge_called, false, "auto_merge off does not merge the pull request")
  eq(deploy_called, false, "auto_merge off does not deploy")
  -- Parallelism: the drain hands every selected task to `join` as one batch --
  local join_batches = {}
  local ticks = 0
  local deps7 = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          max_parallel = 3,
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = true },
          deploy = { auto_deploy = false, plan_file = "deploy.md" },
        }
      end,
    },
    roles = {
      session_opts = function()
        return { system = "", model_spec = "m", thinking = "low", tools = {} }
      end,
    },
    state = {
      load = function()
        return { tasks = {
          T1 = { id = "T1", status = "ready", title = "un", checks = { "true" } },
          T2 = { id = "T2", status = "ready", title = "deux", checks = { "true" } },
        } }
      end,
      transition = function(_, id, status)
        return { id = id, status = status }
      end,
    },
    implement = {
      run = function()
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true } end },
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = { run = function() return { ok = true } end },
    deploy = { run = function() return { ok = true, deployed = true } end },
    pipeline = {
      tick = function(opts)
        ticks = ticks + 1
        if ticks == 1 then
          opts.dispatch({ id = "T1" })
          opts.dispatch({ id = "T2" })
          return { ok = true, started = { "T1", "T2" } }
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    join = function(n, fns)
      join_batches[#join_batches + 1] = { n = n, count = #fns }
      for _, fn in ipairs(fns) do fn() end
    end,
    wait_turn_end = false,
    runner = {},
    qualify = {
      run = function() return { ok = true, tasks = {} } end,
      next_id = function() return "T1" end,
      apply = function() return { ok = true, tasks = { { id = "T1", title = "t" } } } end,
    },
    questions = { round = function() return { questions = {} } end, answer = function() return {} end },
    analyze = { gate = function() return { ok = true } end },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt7 = runtime.new(deps7)
  rt7.submit({ intention = "x", fast = false }, { session = "S1" })
  rt7.run_pending()
  eq(join_batches[1] and join_batches[1].n, 3,
    "the drain joins with the configured max_parallel, not a hardcoded 1")
  eq(join_batches[1] and join_batches[1].count, 2,
    "both selected tasks run as one batch")
end
