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

  -- The fast lane declares the files the intention names, so the scheduler can
  -- prove two tasks disjoint instead of running them one at a time.
  local listed_ref = nil
  deps.git.ls_tree = function(_, ref)
    listed_ref = ref
    return { "public/styles.css", "README.md" }
  end
  local inferred_text, inferred_files = nil, nil
  deps.qualify.infer_files = function(text, files)
    inferred_text, inferred_files = text, files
    return { "public/styles.css" }
  end
  local fast_files = rt.submit({ intention = "change public/styles.css to red" }, ctx)
  eq(fast_files and fast_files.fast, true, "a short intention still takes the fast lane")
  eq(listed_ref, "origin/main", "the fast lane reads the base ref")
  eq(inferred_text, "change public/styles.css to red", "infer_files receives the intention")
  eq(type(inferred_files), "table", "infer_files receives the base tree")
  eq(fast_applied and fast_applied.tasks[1].files and fast_applied.tasks[1].files[1],
    "public/styles.css", "the fast task declares the file the intention names")

  -- complexity: the caller's judgement overrides the wording heuristic ------
  captured = nil
  local forced_full = rt.submit({ intention = "add a red button", complexity = "full" }, ctx)
  eq(type(captured), "table", "complexity=full calls the qualifier")
  eq(forced_full and forced_full.fast, nil, "complexity=full does not take the fast lane")

  captured = nil
  local forced_fast = rt.submit({ intention = "redesign the whole checkout flow. also rework the cart", complexity = "fast" }, ctx)
  eq(captured, nil, "complexity=fast skips the qualifier even for a long intention")
  eq(forced_fast and forced_fast.fast, true, "complexity=fast takes the fast lane")

  local bad = rt.submit({ intention = "x", complexity = "weird" }, ctx)
  eq(bad and bad.ok, false, "an unknown complexity is refused")
  has(tostring(bad and bad.error), "unknown complexity", "the refusal names the problem")

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
  -- Parallelism: the drain starts every selected task, up to max_parallel ----
  local tick_parallel = nil
  local dispatched = 0
  local ticks = 0
  local deps7 = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 3 },
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
        tick_parallel = opts.max_parallel
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
    async = true,
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
  eq(tick_parallel, 3,
    "the drain ticks with the configured max_parallel, not a hardcoded 1")
  eq(ticks >= 2, true, "the drain stops once nothing else is ready")
  -- Stop: cancels the spawn and parks the task as abandoned -----------------
  local cancelled = 0
  local stop_status = "running"
  local stop_transition = nil
  local closed_pr = nil
  local deleted_branch = nil
  local stop_deps = {
    config = { load = function() return { project = { repo = "/tmp/repo", base_ref = "main" } } end },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = stop_status, branch = "metronome/t1",
          pr = { number = 7, url = "u", state = "open" } } } }
      end,
      transition = function(_, id, status, extra)
        stop_status = status
        stop_transition = { id = id, status = status, extra = extra }
        return { id = id, status = status }
      end,
      set_fields = function() return true end,
      delete = function() return true end,
    },
    paths = function() return paths end,
    spawn = function(fn)
      fn()
      return { cancel = function() cancelled = cancelled + 1 end }
    end,
    async = true,
    wait_turn_end = false,
    qualify = {}, questions = {}, analyze = {}, checks = {}, converge = {},
    review = {}, merge = {}, deploy = {}, calibrate = {}, pipeline = {},
    fence = {}, mode = {}, implement = {}, runner = {},
    git = {
      pr_close = function(ref)
        closed_pr = ref
        return { closed = true }
      end,
      delete_branch = function(_, branch)
        deleted_branch = branch
        return { ok = true }
      end,
    },
  }
  local rt8 = runtime.new(stop_deps)
  local stopped = rt8.stop({ id = "T1" })
  eq(stopped and stopped.ok, true, "stop accepts a running task")
  eq(stop_transition and stop_transition.status, "abandoned", "stop parks the task as abandoned")
  eq(stop_transition and stop_transition.extra.reason, "stopped by the user",
    "stop records why in the journal")
  eq(closed_pr, 7, "stop closes the open pull request")

  local idle = rt8.stop({ id = "T1" })
  eq(idle and idle.ok, false, "a task that is not running cannot be stopped")
  has(tostring(idle and idle.error), "not running", "the refusal says why")

  -- delete: the branch goes with the task, nobody will read it ---------------
  local archived_task = nil
  stop_deps.state.archive = function(_, task, opts)
    archived_task = { task = task, opts = opts }
    return "/tmp/archive/T1.json"
  end
  stop_deps.state.archived = function() return { { id = "T1" } } end
  stop_status = "deployed"
  local removed = rt8.delete({ id = "T1" })
  eq(removed and removed.ok, true, "delete removes the task")
  eq(archived_task and archived_task.task.id, "T1", "delete archives the task before hiding it")
  eq(removed and removed.archived, "/tmp/archive/T1.json", "delete reports the archive path")
  eq(deleted_branch, "metronome/t1", "delete removes the task branch")

  -- delete returns before the network cleanup: the spawn is deferred ---------
  local deferred = nil
  local bg_deleted, bg_closed = nil, nil
  stop_deps.spawn = function(fn)
    deferred = fn
    return {}
  end
  stop_deps.git.delete_branch = function(_, branch)
    bg_deleted = branch
    return { ok = true }
  end
  stop_deps.git.pr_close = function(ref)
    bg_closed = ref
    return { closed = true }
  end
  local rt9 = runtime.new(stop_deps)
  local bg_removed = rt9.delete({ id = "T1" })
  eq(bg_removed and bg_removed.ok, true, "delete returns while the cleanup is queued")
  eq(bg_deleted, nil, "the branch is not deleted on the caller's turn")
  eq(bg_closed, nil, "the pull request is not closed on the caller's turn")
  eq(type(deferred), "function", "the cleanup was handed to the spawn")
  deferred()
  eq(bg_deleted, "metronome/t1", "the deferred cleanup deletes the branch")
  eq(bg_closed, 7, "the deferred cleanup closes the pull request")

  local archive_list = rt9.archive({})
  eq(archive_list and archive_list.ok, true, "archive lists the snapshots")
  eq(archive_list and archive_list.count, 1, "archive counts the snapshots")
  -- Resume drains the queue even when nothing was active --------------------
  -- A task that was `ready` when the host died has no session to revive; it
  -- must still start, without waiting for the next submit.
  local ticked = false
  local resume_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 2 },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = true },
          deploy = { auto_deploy = false, plan_file = "deploy.md" },
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function() return { tasks = { T1 = { id = "T1", status = "ready", title = "t" } } } end,
      transition = function(_, id, status) return { id = id, status = status } end,
    },
    pipeline = {
      resume = function() return { ok = true, resumed = {}, errors = {} } end,
      tick = function(opts)
        ticked = true
        opts.dispatch({ id = "T1" })
        return { ok = true, started = { "T1" } }
      end,
    },
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true } end },
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = { run = function() return { ok = true } end },
    deploy = { run = function() return { ok = true } end },
    analyze = { gate = function() return { ok = true } end },
    questions = { round = function() return { questions = {} } end },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {}, qualify = {}, calibrate = {}, fence = {}, mode = {},
  }
  local rt9 = runtime.new(resume_deps)
  local resumed_ok = rt9.resume()
  eq(resumed_ok and resumed_ok.ok, true, "resume succeeds with only a queued task")
  eq(ticked, true, "resume drains the queue even when no task was active")
  -- Merge conflict: the branch goes back to the fresh base and the work is
  -- redone once, without a human ------------------------------------------
  local record = { id = "T1", status = "ready", title = "t", checks = { "true" } }
  local resets = 0
  local merge_calls = 0
  local conflict_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = true },
          deploy = { auto_deploy = false, plan_file = "deploy.md" },
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function() return { tasks = { T1 = record } } end,
      transition = function(_, id, status) record.status = status; return { id = id, status = status } end,
      set_fields = function(_, _, fields)
        for k, v in pairs(fields or {}) do record[k] = v end
        return true
      end,
    },
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true } end },
    git = {
      pr_open = function() return { number = 1, url = "u", state = "open" } end,
      rev_parse = function(_, ref)
        eq(ref, "origin/main", "the fresh base is resolved before the reset")
        return "base123"
      end,
      reset_hard = function(_, sha)
        resets = resets + 1
        eq(sha, "base123", "the branch is reset to the resolved fresh base")
        return "sha"
      end,
    },
    merge = {
      run = function()
        merge_calls = merge_calls + 1
        if merge_calls == 1 then
          return { ok = false, conflict = true, conflict_files = "routes/products.js",
            error = "rebase failed (conflicts: routes/products.js)" }
        end
        record.status = "merged"
        return { ok = true }
      end,
    },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        if ticks == 0 then
          ticks = 1
          opts.dispatch({ id = "T1" })
          return { ok = true, started = { "T1" } }
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
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
  ticks = 0
  local rt10 = runtime.new(conflict_deps)
  rt10.submit({ intention = "x", fast = false }, { session = "S1" })
  rt10.run_pending()
  eq(resets, 1, "a conflict resets the branch to the fresh base once")
  eq(merge_calls, 2, "the merge is attempted again after the repair")
  eq(record.conflict_retried, true, "the repair is recorded on the task")
  eq(record.status, "merged", "the repaired task merges")
  -- Prune: an open PR or a branch whose task is dead is an orphan -----------
  local prune_closed, prune_deleted = {}, {}
  local prune_repo = nil
  local prune_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          git = { branch_prefix = "metronome/" },
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function()
        return { tasks = {
          LIVE = { id = "LIVE", status = "running", branch = "metronome/live" },
          DEAD = { id = "DEAD", status = "failed", branch = "metronome/dead" },
        } }
      end,
    },
    git = {
      list_open_prs = function(opts)
        prune_repo = opts and opts.repo
        return {
          { number = 10, head = "metronome/live", url = "u", title = "live" },
          { number = 11, head = "metronome/dead", url = "u", title = "dead" },
          { number = 12, head = "someone/else", url = "u", title = "not ours" },
        }
      end,
      list_branches = function(_, _, opts)
        eq(opts and opts.pattern, "metronome/*", "prune lists only task branches")
        return { "metronome/live", "metronome/dead", "metronome/orphan" }
      end,
      pr_close = function(ref)
        prune_closed[#prune_closed + 1] = ref
        return { closed = true }
      end,
      delete_branch = function(_, branch)
        prune_deleted[#prune_deleted + 1] = branch
        return { ok = true }
      end,
    },
    paths = function()
      -- The plugin is loaded in another checkout; the project is the config's.
      return { root = paths.root, config = paths.config, repo = "/plugin/repo" }
    end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {}, qualify = {}, questions = {}, analyze = {}, implement = {},
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    pipeline = {}, calibrate = {}, fence = {}, mode = {},
  }
  local rt11 = runtime.new(prune_deps)
  local pruned = rt11.prune({})
  eq(pruned and pruned.ok, true, "prune succeeds")
  eq(prune_repo, "/tmp/repo",
    "git runs on the project repo from the config, not the plugin checkout")
  eq(#pruned.closed, 1, "prune closes the PR of a dead task")
  eq(pruned.closed[1] and pruned.closed[1].number, 11, "the dead task's PR is the one closed")
  eq(#pruned.kept, 1, "prune keeps the PR of a live task")
  eq(pruned.kept[1] and pruned.kept[1].task, "LIVE", "the live task keeps its PR")
  has(table.concat(pruned.deleted, ","), "metronome/dead", "the dead PR's branch is deleted")
  has(table.concat(pruned.deleted, ","), "metronome/orphan", "a branch with no task is deleted")
  eq(table.concat(pruned.deleted, ","):find("metronome/live", 1, true), nil,
    "a live task's branch is kept")
  -- config: a base branch that does not exist on origin is refused ----------
  local cfg_root = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "runtime-config")
  maki.fs.rm(cfg_root, { recursive = true })
  maki.fs.mkdir(cfg_root, { parents = true })
  local cfg_path = maki.fs.joinpath(cfg_root, "config.toml")
  maki.fs.write(cfg_path, [[
[project]
repo = "/tmp/repo"
base_ref = "main"
max_parallel = 1

[checks]
default = ["true"]

[merge]
auto_merge = true

[deploy]
auto_deploy = false
]])
  local asked_pattern = nil
  local cfg_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
          checks = { default = { "true" } },
          merge = { auto_merge = true },
          deploy = { auto_deploy = false },
          roles = {},
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = { load = function() return { tasks = {} } end },
    git = {
      list_branches = function(_, _, opts)
        asked_pattern = opts and opts.pattern
        return {}
      end,
    },
    paths = function()
      return { root = cfg_root, config = cfg_path, repo = "/tmp/repo" }
    end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {}, qualify = {}, questions = {}, analyze = {}, implement = {},
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    pipeline = {}, calibrate = {}, fence = {}, mode = {},
  }
  local rt12 = runtime.new(cfg_deps)
  local bad_base = rt12.config({ answers = { base_ref = "nope" } })
  eq(bad_base and bad_base.ok, false, "a base branch missing on origin is refused")
  has(tostring(bad_base and bad_base.error), "nope", "the refusal names the branch")
  eq(asked_pattern, "nope", "the branch is checked against origin")

  -- A review that asks for changes is the next round's work ---------------
  --
  -- The runtime must call the bounded review loop with a fix callback, hand
  -- the findings to the implementer, and ship the SHA the reviewer approved,
  -- not the first round's.
  local impl_calls = 0
  local second_feedback = nil
  local loop_opts = nil
  local transitions = {}
  local dispatched_review = false
  local deps_review = {
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
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } } }
      end,
      transition = function(_, id, status)
        transitions[#transitions + 1] = status
        return { id = id, status = status }
      end,
    },
    implement = {
      run = function(opts)
        impl_calls = impl_calls + 1
        if impl_calls == 2 then
          second_feedback = opts.feedback
        end
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "s" .. impl_calls }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = {
      loop = function(opts)
        loop_opts = opts
        local first = {
          ok = false, changes_requested = true, round = 1, sha = "s1",
          findings = { { severity = "major", message = "contrast too low", path = "a.css", line = 21 } },
        }
        local fixed = opts.fix(first)
        eq(fixed, true, "the fix callback reports success")
        return { ok = true, approved = true, round = 2, sha = "s2" }
      end,
    },
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = { run = function() return { ok = true } end },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        if not dispatched_review then
          dispatched_review = true
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {},
    qualify = {
      run = function() return { ok = true, tasks = { { title = "t", files = { "f" }, checks = { "true" } } } } end,
      next_id = function() return "T1" end,
      apply = function() return { ok = true, tasks = { { id = "T1", title = "t" } } } end,
    },
    questions = { round = function() return { questions = {} } end, answer = function() return {} end },
    analyze = { gate = function() return { ok = true } end },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_review = runtime.new(deps_review)
  rt_review.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_review.run_pending()
  eq(type(loop_opts), "table", "the runtime uses the bounded review loop")
  eq(loop_opts and loop_opts.max_rounds, 3, "the loop gets the configured round bound")
  eq(impl_calls, 2, "a changes_requested review triggers a second implementation turn")
  eq(type(second_feedback), "table", "the fix turn receives the findings")
  eq(second_feedback and second_feedback[1] and second_feedback[1].message, "contrast too low",
    "the findings reach the implementer verbatim")
  local saw_running = false
  for _, status in ipairs(transitions) do
    if status == "running" then
      saw_running = true
    end
  end
  eq(saw_running, true, "a fix round moves the task back to running")

  -- A rebase before the checks rewrites the branch: it must be pushed -------
  --
  -- The remote would otherwise keep the pre-rebase commits while the review
  -- reads the rebased SHA, and the next turn's push would be refused as
  -- non-fast-forward. The push is leased, never a blind force.
  local push_calls = {}
  local rebase_calls = 0
  local order = {}
  local dispatched_rebase = false
  local deps_rebase = {
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
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } } }
      end,
      transition = function(_, id, status) return { id = id, status = status } end,
    },
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = {
      verify = function()
        order[#order + 1] = "checks"
        return { ok = true }
      end,
      write_report = function() end,
    },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true, sha = "abc" } end },
    git = {
      pr_open = function() return { number = 1, url = "u", state = "open" } end,
      push = function(_, branch, opts)
        push_calls[#push_calls + 1] = { branch = branch, force = opts and opts.force }
        order[#order + 1] = "push"
        return true
      end,
    },
    merge = {
      rebase = function()
        rebase_calls = rebase_calls + 1
        return { ok = true, sha = "rebsha" }
      end,
      run = function() return { ok = true } end,
    },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        if not dispatched_rebase then
          dispatched_rebase = true
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {},
    qualify = {
      run = function() return { ok = true, tasks = { { title = "t", files = { "f" }, checks = { "true" } } } } end,
      next_id = function() return "T1" end,
      apply = function() return { ok = true, tasks = { { id = "T1", title = "t" } } } end,
    },
    questions = { round = function() return { questions = {} } end, answer = function() return {} end },
    analyze = { gate = function() return { ok = true } end },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_rebase = runtime.new(deps_rebase)
  rt_rebase.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_rebase.run_pending()
  eq(rebase_calls, 1, "the branch is rebased before the checks")
  eq(#push_calls, 1, "the rewritten branch is pushed")
  eq(push_calls[1] and push_calls[1].force, true, "the push leases the branch")
  eq(push_calls[1] and push_calls[1].branch, "b", "the push names the task branch")
  eq(order[1], "push", "the push happens before the checks")
  eq(order[2], "checks", "the checks run on the pushed branch")

  -- A rebase conflict on the fresh base is repaired, not fatal -------------
  --
  -- The base moved and the same lines changed. The branch is reset to the
  -- fresh base and the work is redone there, once; the second conflict is a
  -- real failure.
  local rebase_attempts = 0
  local impl_attempts = 0
  local resets = 0
  local dispatched_conflict = false
  local deps_conflict = {
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
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = "ready", title = "t", checks = { "true" } } } }
      end,
      transition = function(_, id, status) return { id = id, status = status } end,
      set_fields = function() return true end,
    },
    implement = {
      run = function()
        impl_attempts = impl_attempts + 1
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "s" .. impl_attempts }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true, sha = "s2" } end },
    git = {
      pr_open = function() return { number = 1, url = "u", state = "open" } end,
      push = function() return true end,
      rev_parse = function(_, ref)
        eq(ref, "origin/main", "the fresh base is resolved before the reset")
        return "base123"
      end,
      reset_hard = function()
        resets = resets + 1
        return "sha"
      end,
    },
    merge = {
      rebase = function()
        rebase_attempts = rebase_attempts + 1
        -- The base moves twice while the task is redone: both conflicts must be
        -- repaired, not just the first.
        if rebase_attempts <= 2 then
          return nil, "rebase failed (conflicts: public/styles.css)", { conflict = "public/styles.css" }
        end
        return { ok = true, sha = "rebsha" }
      end,
      run = function() return { ok = true } end,
    },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        if not dispatched_conflict then
          dispatched_conflict = true
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {},
    qualify = {
      run = function() return { ok = true, tasks = { { title = "t", files = { "f" }, checks = { "true" } } } } end,
      next_id = function() return "T1" end,
      apply = function() return { ok = true, tasks = { { id = "T1", title = "t" } } } end,
    },
    questions = { round = function() return { questions = {} } end, answer = function() return {} end },
    analyze = { gate = function() return { ok = true } end },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_conflict = runtime.new(deps_conflict)
  rt_conflict.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_conflict.run_pending()
  eq(resets, 2, "each rebase conflict resets the branch to the fresh base")
  eq(impl_attempts, 3, "the work is redone after each conflict")
  eq(rebase_attempts, 3, "the rebase is retried after each reset")

  -- A task that already repaired one conflict can repair the next ----------
  --
  -- The base can move more than once (several PRs merging), so the bound is a
  -- count of repairs, not a lifetime flag set by the first one.
  local second_resets = 0
  local second_impl = 0
  local second_rebases = 0
  local dispatched_second = false
  local second_task = {
    id = "T1", status = "ready", title = "t", checks = { "true" },
    conflict_retried = true, conflict_retries = 1,
  }
  local deps_second = {
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
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function() return { tasks = { T1 = second_task } } end,
      transition = function(_, id, status) second_task.status = status; return { id = id, status = status } end,
      set_fields = function(_, _, fields)
        for k, v in pairs(fields or {}) do second_task[k] = v end
        return true
      end,
    },
    implement = {
      run = function()
        second_impl = second_impl + 1
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "s" .. second_impl }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true, sha = "s2" } end },
    git = {
      pr_open = function() return { number = 1, url = "u", state = "open" } end,
      push = function() return true end,
      rev_parse = function() return "base123" end,
      reset_hard = function() second_resets = second_resets + 1; return "sha" end,
    },
    merge = {
      rebase = function()
        second_rebases = second_rebases + 1
        if second_rebases == 1 then
          return nil, "conflict", { conflict = "public/styles.css" }
        end
        return { ok = true, sha = "rebsha" }
      end,
      run = function() return { ok = true } end,
    },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        if not dispatched_second then
          dispatched_second = true
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {},
    qualify = {
      run = function() return { ok = true, tasks = { { title = "t", files = { "f" }, checks = { "true" } } } } end,
      next_id = function() return "T1" end,
      apply = function() return { ok = true, tasks = { { id = "T1", title = "t" } } } end,
    },
    questions = { round = function() return { questions = {} } end, answer = function() return {} end },
    analyze = { gate = function() return { ok = true } end },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_second = runtime.new(deps_second)
  rt_second.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_second.run_pending()
  eq(second_resets, 1, "a task with one earlier repair still repairs the next conflict")
  eq(second_impl, 2, "the work is redone on the fresh base")
  eq(second_task.conflict_retries, 2, "the repair counter grows")
end
