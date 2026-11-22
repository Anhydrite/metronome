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
    runner = {}, git = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {},
    -- The real slugger: the epic branch is named after the intention.
    implement = { slug = function(text, max)
      local out = tostring(text):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
      if max and #out > max then out = out:sub(1, max):gsub("%-+$", "") end
      return out
    end },
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

  -- Each qualification gets its own run directory: two concurrent qualifiers
  -- must not share runs/qualify/qualify/1.
  local first_key = captured and captured.task_id
  eq(type(first_key), "string", "the qualifier receives a run key")
  rt.submit({ intention = "add another icon", fast = false }, ctx)
  eq(captured and captured.task_id ~= first_key, true,
    "each qualification gets its own run key")

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
    runner = {}, git = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {},
    -- The real slugger: the epic branch is named after the intention.
    implement = { slug = function(text, max)
      local out = tostring(text):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
      if max and #out > max then out = out:sub(1, max):gsub("%-+$", "") end
      return out
    end },
  }
  -- Two tasks from one intention: the epic branch is created and pushed before
  -- the tasks exist, and qualify.apply receives the epic options.
  local created_branch, pushed_branch, epic_opts
  deps2.git = {
    branch_create = function(repo, name, from_ref)
      created_branch = { repo = repo, name = name, from = from_ref }
      return { ok = true, branch = name, created = true }
    end,
    push_branch = function(repo, name)
      pushed_branch = { repo = repo, name = name }
      return true
    end,
  }
  local apply_opts
  local base_apply = deps2.qualify.apply
  deps2.qualify.apply = function(state_mod, root, result, opts)
    apply_opts = opts
    epic_opts = opts and opts.epic
    return base_apply(state_mod, root, result, opts)
  end
  local rt2 = runtime.new(deps2)
  local res2 = rt2.submit({ intention = "x", fast = false }, ctx)
  rt2.run_pending()
  eq(type(res2), "table", "submit with dependencies returns a result")
  eq(set_fields["T-2"] and set_fields["T-2"].depends_on and set_fields["T-2"].depends_on[1], "T-1",
    "dependency titles are remapped to task ids")
  eq(type(created_branch), "table", "a multi-task intention creates an epic branch")
  eq(created_branch and created_branch.from, "origin/main",
    "the epic branch is cut from the fresh project base")
  eq(created_branch and created_branch.name
    and created_branch.name:match("^metronome/epic/x%-[0-9a-f]+$") ~= nil,
    true, "the epic branch is named after the intention, with the task suffix")
  eq(pushed_branch and pushed_branch.name, created_branch and created_branch.name,
    "the epic branch is pushed before the tasks are created")
  eq(epic_opts and epic_opts.branch, created_branch and created_branch.name,
    "qualify.apply receives the epic branch")
  eq(epic_opts and epic_opts.base, "main", "qualify.apply receives the project base")

  -- Qualification remaps dependency batch positions to task ids ------------

  local set_fields_idx = {}
  local deps2b = {
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
          { title = "Alpha", intent = "a", files = { "a" }, checks = {}, acceptance = {}, depends_on = {} },
          { title = "Beta", intent = "b", files = { "b" }, checks = {}, acceptance = {}, depends_on = { "2" } },
        } }
      end,
      next_id = function()
        return "T-1"
      end,
      apply = function()
        return { ok = true, tasks = {
          { id = "T-1", title = "Alpha" },
          { id = "T-2", title = "Beta", depends_on = { "2" } },
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
        set_fields_idx[id] = fields
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
    runner = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {},
    git = {
      branch_create = function(repo, name, from_ref)
        return { ok = true, branch = name, created = true }
      end,
      push_branch = function()
        return true
      end,
    },
    implement = { slug = function(text, max)
      local out = tostring(text):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
      if max and #out > max then out = out:sub(1, max):gsub("%-+$", "") end
      return out
    end },
  }
  local rt2b = runtime.new(deps2b)
  rt2b.submit({ intention = "x", fast = false }, ctx)
  rt2b.run_pending()
  eq(set_fields_idx["T-2"] and set_fields_idx["T-2"].depends_on
    and set_fields_idx["T-2"].depends_on[1], "T-2",
    "dependency batch positions are remapped to task ids")


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

  -- Stop and abandon prune the dead task's GitHub debris automatically ------
  local auto_tasks = {
    STOPME = { id = "STOPME", status = "running", branch = "metronome/stopme" },
    ABANDONME = { id = "ABANDONME", status = "failed", branch = "metronome/abandonme" },
  }
  local auto_closed, auto_deleted = {}, {}
  local auto_deps = {
    config = prune_deps.config,
    roles = prune_deps.roles,
    state = {
      load = function() return { tasks = auto_tasks } end,
      transition = function(_, id, status) auto_tasks[id].status = status; return auto_tasks[id] end,
      set_fields = function() return true end,
    },
    git = {
      list_open_prs = function()
        return {
          { number = 21, head = "metronome/stopme" },
          { number = 22, head = "metronome/abandonme" },
        }
      end,
      list_branches = function() return { "metronome/stopme", "metronome/abandonme" } end,
      pr_close = function(ref) auto_closed[#auto_closed + 1] = ref; return { closed = true } end,
      delete_branch = function(_, branch) auto_deleted[#auto_deleted + 1] = branch; return { ok = true } end,
    },
    paths = prune_deps.paths,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {}, qualify = {}, questions = {}, analyze = {}, implement = {},
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    pipeline = {}, calibrate = {}, fence = {}, mode = {},
  }
  local rt12 = runtime.new(auto_deps)
  local stopped = rt12.stop({ id = "STOPME" })
  eq(stopped.ok, true, "stop succeeds")
  eq(stopped.stopped, true, "stop marks the task stopped")
  eq(auto_tasks.STOPME.status, "abandoned", "stop parks the task as abandoned")
  eq(stopped.prune and stopped.prune.ok, true, "stop prunes automatically")
  has(table.concat(auto_closed, ","), "21", "stop closes the orphan PR")
  has(table.concat(auto_deleted, ","), "metronome/stopme", "stop deletes the dead branch")

  local abandoned = rt12.abandon({ id = "ABANDONME" })
  eq(abandoned.ok, true, "abandon succeeds")
  eq(auto_tasks.ABANDONME.status, "abandoned", "abandon parks the task as abandoned")
  eq(abandoned.prune and abandoned.prune.ok, true, "abandon prunes automatically")
  has(table.concat(auto_closed, ","), "22", "abandon closes the orphan PR")
  has(table.concat(auto_deleted, ","), "metronome/abandonme", "abandon deletes the dead branch")

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
    -- A green preflight: this case pins the origin/base-branch guard, which
    -- must still fire before any preflight refusal.
    preflight = {
      run = function() return { ok = true, checks = {}, failures = {} } end,
      format = function() return "" end,
    },
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
  -- Epic branches ----------------------------------------------------------
  --
  -- The base a task is cut from, merged into and diffed against is per task:
  -- a subtask of an epic carries `base_ref = <epic branch>`, everything else
  -- falls back to the project base.

  eq(runtime.task_base({ base_ref = "metronome/epic/x" }, { project = { base_ref = "main" } }),
    "metronome/epic/x", "task_base prefers the task's own base")
  eq(runtime.task_base({}, { project = { base_ref = "main" } }), "main",
    "task_base falls back to the project base")
  eq(runtime.task_base({ base_ref = "" }, { project = { base_ref = "main" } }), "main",
    "an empty base_ref falls back to the project base")
  eq(runtime.task_base({ base_ref = "epic" }, nil), "epic", "task_base works without a config")

  -- A subtask runs the whole normal pipeline, but on the epic branch, and it
  -- never deploys: the epic owns the deploy.
  local seen = {}
  local subtask = {
    id = "T1", status = "ready", title = "sub", checks = { "true" },
    base_ref = "metronome/epic/demo-0001",
  }
  local subtask_deploy = false
  local subtask_merge_opts = nil
  local dispatched_sub = false
  local deps_sub = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = true },
          deploy = { auto_deploy = true, plan_file = "deploy.md" },
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function() return { tasks = { T1 = subtask } } end,
      transition = function(_, id, status) subtask.status = status; return { id = id, status = status } end,
      set_fields = function(_, _, fields)
        for k, v in pairs(fields or {}) do subtask[k] = v end
        return true
      end,
    },
    implement = {
      run = function(opts)
        seen.implement_base = opts.base_ref
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function(opts) seen.converge_base = opts.base; return { ok = true } end },
    review = { review = function(opts) seen.review_base = opts.base; return { ok = true, approved = true } end },
    git = {
      pr_open = function(_, _, _, opts) seen.pr_base = opts.base; return { number = 1, url = "u", state = "open" } end,
    },
    merge = {
      rebase = function(opts) seen.rebase_base = opts.base; return { ok = true, sha = "r" } end,
      run = function(opts)
        subtask_merge_opts = opts
        -- The real merger owns the pr_open -> merging -> merged walk.
        subtask.status = "merged"
        return { ok = true }
      end,
    },
    deploy = { run = function() subtask_deploy = true; return { ok = true, deployed = true } end },
    pipeline = {
      tick = function(opts)
        if not dispatched_sub then
          dispatched_sub = true
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
  local rt_sub = runtime.new(deps_sub)
  rt_sub.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_sub.run_pending()
  eq(seen.implement_base, "metronome/epic/demo-0001", "the implementer cuts the worktree from the epic branch")
  eq(seen.rebase_base, "metronome/epic/demo-0001", "the rebase targets the epic branch")
  eq(seen.converge_base, "origin/metronome/epic/demo-0001", "the converge diff is read against the epic branch")
  eq(seen.review_base, "origin/metronome/epic/demo-0001", "the review diff is read against the epic branch")
  eq(seen.pr_base, "metronome/epic/demo-0001", "the subtask PR targets the epic branch")
  eq(subtask_merge_opts and subtask_merge_opts.base, "metronome/epic/demo-0001",
    "the subtask merges into the epic branch")
  eq(subtask_merge_opts and subtask_merge_opts.deploy_pending, false,
    "a subtask does not mark the epic branch as a deployable base")
  eq(subtask_deploy, false, "a subtask never deploys")
  eq(subtask.status, "merged", "a subtask stops at merged")

  -- An epic task skips implement, converge and review: it pushes the branch,
  -- opens the single PR to the project base, merges it and deploys.
  local epic_record = {
    id = "T1", status = "ready", title = "epic: two things", kind = "epic",
    branch = "metronome/epic/demo-0001", base_ref = "main", checks = { "true" },
  }
  local epic_seen = { implement = 0, review = 0, converge = 0, deploy = 0 }
  local epic_merge_opts = nil
  local dispatched_epic = false
  local deps_epic = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = true, auto_rebase = true },
          deploy = { auto_deploy = true, plan_file = "deploy.md" },
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    state = {
      load = function() return { tasks = { T1 = epic_record } } end,
      transition = function(_, id, status) epic_record.status = status; return { id = id, status = status } end,
      set_fields = function(_, _, fields)
        for k, v in pairs(fields or {}) do epic_record[k] = v end
        return true
      end,
    },
    implement = {
      run = function() epic_seen.implement = epic_seen.implement + 1; return { ok = false } end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() epic_seen.converge = epic_seen.converge + 1; return { ok = true } end },
    review = { review = function() epic_seen.review = epic_seen.review + 1; return { ok = true } end },
    git = {
      -- The epic branch already exists on the remote after the subtask merges:
      -- the local ref is aligned to it instead of pushing a stale tip.
      fetch = function() epic_seen.fetched = true; return true end,
      rev_parse = function(_, ref) epic_seen.rev_parse = ref; return "abc123" end,
      branch_reset = function(_, name, ref)
        epic_seen.reset = { name = name, ref = ref }
        return true
      end,
      push_branch = function(repo, name) epic_seen.pushed = name; return true end,
      pr_open = function(_, _, _, opts)
        epic_seen.pr = opts
        return { number = 7, url = "https://example.test/pr/7", state = "open" }
      end,
      worktree_add = function(repo, wt, branch) epic_seen.worktree = wt; return wt end,
      worktree_remove = function() return true end,
    },
    merge = {
      run = function(opts) epic_merge_opts = opts; return { ok = true } end,
    },
    deploy = {
      run = function()
        epic_seen.deploy = epic_seen.deploy + 1
        -- The real deployer owns the merged -> deploying -> deployed walk.
        epic_record.status = "deployed"
        return { ok = true, deployed = true }
      end,
    },
    pipeline = {
      tick = function(opts)
        if not dispatched_epic then
          dispatched_epic = true
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
  local rt_epic = runtime.new(deps_epic)
  rt_epic.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic.run_pending()
  eq(epic_seen.implement, 0, "an epic never calls the implementer")
  eq(epic_seen.converge, 0, "an epic never converges a diff")
  eq(epic_seen.review, 0, "an epic never enters the review loop")
  eq(epic_seen.fetched, true, "the epic fetches the remote before touching its branch")
  eq(epic_seen.rev_parse, "origin/metronome/epic/demo-0001",
    "the epic reads the remote tip of its branch")
  eq(epic_seen.reset and epic_seen.reset.name, "metronome/epic/demo-0001",
    "the epic aligns its local branch with the remote")
  eq(epic_seen.reset and epic_seen.reset.ref, "origin/metronome/epic/demo-0001",
    "the local branch is moved to the remote tip")
  eq(epic_seen.pushed, nil, "an existing remote branch is not pushed again")
  eq(epic_seen.pr and epic_seen.pr.base, "main", "the epic PR targets the project base")
  eq(epic_seen.pr and epic_seen.pr.head, "metronome/epic/demo-0001", "the epic PR head is the epic branch")
  eq(epic_seen.pr and epic_seen.pr.attach_only, true, "the epic opens the PR before moving the task")
  eq(epic_merge_opts and epic_merge_opts.base, "main", "the epic merges into the project base")
  eq(epic_merge_opts and epic_merge_opts.worktree, maki.fs.joinpath(paths.worktrees, "T1"),
    "the epic is rebased in an isolated worktree, not the project checkout")
  eq(epic_merge_opts and epic_merge_opts.auto_rebase, true, "the epic honours the configured auto_rebase")
  eq(epic_seen.deploy, 1, "the epic deploys after its merge")
  eq(epic_record.status, "deployed", "the epic ends deployed")

  -- Failure policy and unblockable drain ------------------------------------
  --
  -- A failed task and a stopped workflow are the worst outcomes: every failure
  -- is typed, persisted on the task (worktree, branch, checkpoints and
  -- transcript untouched), retried automatically when the cause is transient,
  -- and escalated only when a retry cannot help. No task ever runs on the
  -- scheduler's turn: the drain must return while the tasks are in flight.

  -- The typed failure policy the production wiring injects.
  local recover_mod = load_module("recover")

  -- A stub state that behaves like the journal for one task: a status move
  -- keeps every artefact, a failure field event replaces the diagnosis, and a
  -- move back to `running` resets the attempt budget.
  local function mem_state(record)
    return {
      load = function()
        return { tasks = { [record.id] = record } }
      end,
      transition = function(_, id, status, extra)
        extra = extra or {}
        if type(extra.failure) == "table" then
          record.failure = extra.failure
        end
        if extra.reason then
          record.failure_reason = extra.reason
        end
        if extra.phase then
          record.phase = extra.phase
        end
        record.status = status
        if status == "running" and type(record.failure) == "table" then
          record.failure.attempts = 0
          record.failure.next_retry_at = nil
        end
        return { id = id, status = status }
      end,
      set_fields = function(_, id, fields)
        for key, value in pairs(fields or {}) do
          record[key] = value
        end
        return record
      end,
    }
  end

  -- Capture the human-facing notifications without touching the real chat:
  -- maki.session is a table, so the two entry points can be swapped and put
  -- back. A transient failure must produce none until the budget is spent.
  local notified = {}
  local saved_notify = maki.session.notify
  local saved_prompt = maki.session.prompt
  maki.session.notify = function(text)
    notified[#notified + 1] = tostring(text)
    return true
  end
  maki.session.prompt = function(text)
    notified[#notified + 1] = tostring(text)
    return true
  end

  -- A transient failure: typed diagnosis, deferred bounded retry, no wake-up.
  local deferred = {}
  local transient_record = {
    id = "T1", status = "ready", title = "t", checks = { "true" },
    branch = "metronome/t1", worktree = "/tmp/wt-t1", run_dir = "/tmp/runs/T1",
    checkpoints = { "c1", "c2" },
    pr = { number = 3, url = "u", state = "open" },
  }
  local transient_impl = 0
  local transient_tick_opts = nil
  local transient_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = false },
          review = { max_rounds = 3 },
          deploy = { auto_deploy = false },
          recover = { max_attempts = 2, backoff_base_secs = 30 },
        }
      end,
    },
    roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
    recover = recover_mod,
    state = mem_state(transient_record),
    implement = {
      run = function()
        transient_impl = transient_impl + 1
        return { ok = false, error = "fatal: unable to access 'https://github.com/x/y': could not resolve host: github.com" }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true } end },
    git = {
      pr_open = function() return { number = 1, url = "u", state = "open" } end,
      pr_close = function() error("a retryable failure must not close the PR") end,
    },
    merge = { run = function() return { ok = true } end },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        transient_tick_opts = opts
        if transient_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    defer = function(fn, ms)
      deferred[#deferred + 1] = { fn = fn, ms = ms }
      return {}
    end,
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
  notified = {}
  local rt_transient = runtime.new(transient_deps)
  rt_transient.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_transient.run_pending()
  eq(transient_impl, 1, "the failing task ran once")
  eq(transient_record.status, "failed", "the failure is persisted on the task")
  eq(type(transient_record.failure), "table", "the failure is a typed record, not a string")
  eq(transient_record.failure and transient_record.failure.cause, "network",
    "a fetch/network error is diagnosed as a transient cause")
  eq(transient_record.failure and transient_record.failure.transient, true,
    "the diagnosis is marked transient")
  eq(transient_record.failure and transient_record.failure.attempts, 1, "the attempt is counted")
  eq(#notified, 0, "a transient failure does not wake a human")
  eq(#deferred, 1, "the automatic retry is scheduled after the backoff")
  eq(deferred[1] and deferred[1].ms, 30000, "the retry waits the policy's backoff")
  eq(transient_record.branch, "metronome/t1", "the failure keeps the branch")
  eq(transient_record.worktree, "/tmp/wt-t1", "the failure keeps the worktree")
  eq(transient_record.run_dir, "/tmp/runs/T1", "the failure keeps the run directory")
  eq(#(transient_record.checkpoints or {}), 2, "the failure keeps the checkpoints")
  eq(transient_record.pr and transient_record.pr.state, "open", "the failure leaves the PR open")
  has(tostring(transient_record.failure_reason), "network",
    "the persisted reason names the cause")
  eq(transient_tick_opts and transient_tick_opts.max_attempts, 0,
    "the drain tick never retries a failed task: schedule_retry is the only authority")
  eq(type(transient_tick_opts and transient_tick_opts.recover), "table",
    "the drain tick still receives the recovery policy")
  local typed_result = type(rt_transient.last_background) == "table"
    and type(rt_transient.last_background.results) == "table"
    and rt_transient.last_background.results[1] or nil
  eq(type(typed_result), "table", "the drain result keeps the per-task record")
  eq(typed_result and typed_result.failure and typed_result.failure.cause, "network",
    "the per-task result carries the typed failure")
  eq(typed_result and typed_result.decision and typed_result.decision.action, "auto_retry",
    "the per-task result carries the resume decision")
  eq(typed_result and typed_result.retrying, true,
    "the per-task result says the task is being retried")
  eq(type(typed_result and typed_result.error), "string",
    "the per-task result keeps the raw step error")
  -- Fire the deferred retry: it runs the task again, and the second failure
  -- exhausts the budget, which is the only thing that escalates.
  deferred[1].fn()
  rt_transient.run_pending()
  eq(transient_impl, 2, "the automatic retry re-dispatches the task")
  eq(#notified, 1, "the exhausted budget escalates exactly once")
  has(tostring(notified[1]), "network", "the escalation names the cause")
  has(tostring(notified[1]), "check the network", "the escalation names the remedy")
  eq(transient_record.failure and transient_record.failure.attempts, 2,
    "the second failure is counted on the task")

  -- An auth failure is not transient: one attempt, then a human is told, with
  -- the remedy in the text. Nothing is retried behind the user's back.
  local auth_record = {
    id = "T1", status = "ready", title = "t", checks = { "true" },
    branch = "metronome/t1", worktree = "/tmp/wt-t1",
  }
  local auth_impl = 0
  local auth_deferred = 0
  local auth_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(auth_record),
    implement = {
      run = function()
        auth_impl = auth_impl + 1
        return { ok = false, error = "fatal: Authentication failed for 'https://github.com/x/y.git/'" }
      end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = transient_deps.git,
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if auth_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    defer = function()
      auth_deferred = auth_deferred + 1
      return {}
    end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_auth = runtime.new(auth_deps)
  rt_auth.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_auth.run_pending()
  eq(auth_impl, 1, "an auth failure is not retried automatically")
  eq(auth_deferred, 0, "no retry is scheduled for an auth failure")
  eq(auth_record.failure and auth_record.failure.cause, "auth", "the auth failure is typed")
  eq(auth_record.failure and auth_record.failure.transient, false, "auth is not transient")
  eq(#notified, 1, "an auth failure escalates to the human")
  has(tostring(notified[1]), "auth", "the escalation names the auth cause")
  has(tostring(notified[1]), "credentials", "the escalation names the remedy")
  eq(auth_record.branch, "metronome/t1", "the auth failure keeps the branch")

  -- A late automatic retry must not run a task a human already resumed -----
  --
  -- The backoff timer and a human retry can both decide to restart the same
  -- task. Only the first may run it: `running -> running` is a legal no-op, so
  -- without a status guard the same worktree would get two run_tasks (and two
  -- sessions) at once.
  local guard_record = { id = "T1", status = "ready", title = "t", checks = { "true" } }
  local guard_impl = 0
  local guard_deferred = {}
  local guard_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(guard_record),
    implement = {
      run = function()
        guard_impl = guard_impl + 1
        if guard_impl == 1 then
          return { ok = false, error = "could not resolve host: github.com" }
        end
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
      end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = transient_deps.git,
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if guard_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    defer = function(fn, ms)
      guard_deferred[#guard_deferred + 1] = { fn = fn, ms = ms }
      return {}
    end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_guard = runtime.new(guard_deps)
  rt_guard.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_guard.run_pending()
  eq(guard_impl, 1, "the transient failure happened once")
  eq(guard_record.status, "failed", "the task is parked for its automatic retry")
  eq(#guard_deferred, 1, "the automatic retry is armed")
  -- The user resumes before the backoff elapses; this run succeeds.
  local guard_retry = rt_guard.retry({ id = "T1" }, { session = "S1" })
  eq(guard_retry and guard_retry.ok, true, "the human retry is accepted")
  rt_guard.run_pending()
  eq(guard_impl, 2, "the human retry runs the task once")
  eq(guard_record.status, "pr_open", "the human retry carried the task forward")
  -- The armed automatic retry fires late: the task is no longer failed.
  guard_deferred[1].fn()
  rt_guard.run_pending()
  eq(guard_impl, 2, "a late automatic retry is skipped instead of running the task twice")

  -- The drain never runs a task on its own turn -----------------------------
  --
  -- `spawn` is the seam: a host that queues it (maki.async.spawn) must let
  -- `run_pending` return while the run_task is still in flight. The test counts
  -- the spawn calls and proves the dispatch happens inside one of them.
  local queued = {}
  local spawn_calls = 0
  local drain_record = {
    id = "T1", status = "ready", title = "t", checks = { "true" },
  }
  local drain_impl = 0
  local drain_dispatched = false
  local drain_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    state = mem_state(drain_record),
    implement = {
      run = function()
        drain_impl = drain_impl + 1
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
      end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = transient_deps.git,
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if not drain_dispatched then
          drain_dispatched = true
          -- The real tick moves the task to `running` before dispatching.
          drain_record.status = "running"
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = { "T1" } }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn)
      spawn_calls = spawn_calls + 1
      queued[#queued + 1] = fn
      return { cancel = function() end }
    end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_drain = runtime.new(drain_deps)
  rt_drain.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_drain.run_pending()
  eq(spawn_calls >= 1, true, "the drain dispatches through spawn")
  eq(drain_impl, 0, "run_pending returns before the task runs")
  eq(#queued >= 1, true, "the run_task is still queued when the drain returns")
  -- Run the queued spawns: the task completes off the drain's turn.
  local guard = 0
  while #queued > 0 and guard < 50 do
    guard = guard + 1
    local fn = table.remove(queued, 1)
    fn()
  end
  eq(drain_impl, 1, "the queued spawn runs the task")
  eq(drain_record.status, "pr_open", "the queued task ran its whole pipeline off the drain's turn")

  -- feedback relaunches the workflow ----------------------------------------
  local feedback_ticked = false
  local feedback_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    state = mem_state({ id = "T1", status = "ready", title = "t" }),
    calibrate = {
      feedback = function(_, input)
        return { total = 1, entries = { { rule = "no-console", vote = input and input.vote } } }
      end,
    },
    pipeline = {
      tick = function()
        feedback_ticked = true
        return { ok = true, started = {} }
      end,
    },
    implement = {}, checks = {}, converge = {}, review = {}, git = {}, merge = {},
    deploy = {}, qualify = {}, questions = {},
    analyze = { gate = function() return { ok = true } end },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {}, fence = {}, mode = {},
  }
  local rt_feedback = runtime.new(feedback_deps)
  local fed = rt_feedback.feedback({ id = "T1", vote = "down" })
  eq(fed and fed.ok, true, "feedback is ingested")
  eq(fed and fed.background, true, "feedback reports the drain it started")
  eq(feedback_ticked, true, "feedback drains the workflow instead of waiting for a submit")

  -- The fresh base the rebase reports is the base of the convergence diff ---
  local fresh_seen = { converge = nil, review = nil, rebase = 0 }
  local fresh_record = { id = "T1", status = "ready", title = "t", checks = { "true" } }
  local fresh_deps = {
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
    roles = transient_deps.roles,
    state = mem_state(fresh_record),
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function(opts) fresh_seen.converge = opts.base; return { ok = true } end },
    review = { review = function(opts) fresh_seen.review = opts.base; return { ok = true, approved = true } end },
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = {
      rebase = function()
        fresh_seen.rebase = fresh_seen.rebase + 1
        return { ok = true, base = "origin/main@fresh", sha = "rebsha" }
      end,
      run = function() return { ok = true } end,
    },
    deploy = { run = function() return { ok = true } end },
    pipeline = {
      tick = function(opts)
        if fresh_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_fresh = runtime.new(fresh_deps)
  rt_fresh.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_fresh.run_pending()
  eq(fresh_seen.rebase, 1, "the fresh base is fetched before the checks")
  eq(fresh_seen.converge, "origin/main@fresh",
    "the convergence diff uses the base the rebase reported")
  eq(fresh_seen.review, "origin/main@fresh",
    "the review diff uses the same fresh base")

  -- A fetch failure is a transient diagnosis, not a permanent string --------
  local fetch_record = { id = "T1", status = "ready", title = "t", checks = { "true" } }
  local fetch_converged = false
  local fetch_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = false },
          review = { max_rounds = 3 },
          deploy = { auto_deploy = false },
          recover = { max_attempts = 3, backoff_base_secs = 0 },
        }
      end,
    },
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(fetch_record),
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() fetch_converged = true; return { ok = true } end },
    review = transient_deps.review,
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = {
      rebase = function()
        return nil, "fatal: could not resolve host: github.com"
      end,
      run = function() return { ok = true } end,
    },
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if fetch_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_fetch = runtime.new(fetch_deps)
  rt_fetch.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_fetch.run_pending()
  eq(fetch_converged, false, "a fetch failure stops before the convergence diff")
  eq(type(fetch_record.failure), "table", "the fetch failure is typed")
  eq(fetch_record.failure and fetch_record.failure.cause, "network",
    "a fetch failure is diagnosed as a network cause")
  eq(fetch_record.failure and fetch_record.failure.transient, true,
    "a fetch failure is transient, so it stays retryable")
  has(tostring(fetch_record.failure_reason), "network", "the reason names the cause")

  -- A git_lock is replayed, bounded, before the task is failed ------------
  --
  -- Two maki processes on the same clone can race for a ref lock even though
  -- fetch is single-flight in process. The runtime replays the failed git step
  -- with a short bounded backoff (three attempts, ~200 ms jittered) instead of
  -- condemning the task on the first lock. The sleep seam keeps the test fast,
  -- and the step that is replayed is the git operation, not the model session.
  local function check_git_lock_replay()
  local lock_diag = {
    cause = "git_lock",
    message = "cannot lock ref 'refs/remotes/origin/main'",
    hint = "another git process holds a ref lock; retry in a moment",
  }

  local replay_seen = { rebase = 0, checks = 0 }
  local replay_sleeps = {}
  local replay_record = {
    id = "T1", status = "ready", title = "t", checks = { "true" },
    branch = "metronome/t1", worktree = "/tmp/wt-t1",
    checkpoints = { "c1", "c2" }, run_dir = "/tmp/runs/T1",
  }
  local replay_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(replay_record),
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = {
      verify = function()
        replay_seen.checks = replay_seen.checks + 1
        return { ok = true }
      end,
      write_report = function() end,
    },
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = {
      rebase = function()
        replay_seen.rebase = replay_seen.rebase + 1
        if replay_seen.rebase < 3 then
          return nil, "rebase failed [git_lock]: cannot lock ref", lock_diag
        end
        return { ok = true, base = "origin/main@fresh", sha = "rebsha" }
      end,
      run = function() return { ok = true } end,
    },
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if replay_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    sleep = function(ms) replay_sleeps[#replay_sleeps + 1] = ms end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_replay = runtime.new(replay_deps)
  rt_replay.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_replay.run_pending()
  eq(replay_seen.rebase, 3, "a git_lock on the rebase is replayed up to the third attempt")
  eq(#replay_sleeps, 2, "the replay backs off between attempts")
  eq(type(replay_sleeps[1]) == "number" and replay_sleeps[1] >= 200
    and replay_sleeps[1] < 400, true, "the replay backoff is short and jittered around 200 ms")
  eq(replay_seen.checks, 1, "the task goes on to its checks after the replay")
  eq(replay_record.status ~= "failed", true, "a first git_lock does not fail the task")
  eq(replay_record.failure, nil, "a replayed git_lock leaves no failure on the task")

  -- An exhausted git_lock fails the task, names the cause and keeps every
  -- artefact a retry resumes from.
  local exhausted_seen = { rebase = 0 }
  local exhausted_sleeps = {}
  local exhausted_record = {
    id = "T1", status = "ready", title = "t", checks = { "true" },
    branch = "metronome/t1", worktree = "/tmp/wt-t1",
    checkpoints = { "c1", "c2" }, run_dir = "/tmp/runs/T1",
  }
  local exhausted_deps = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
          merge = { method = "squash", auto_merge = false },
          review = { max_rounds = 3 },
          deploy = { auto_deploy = false },
          recover = { max_attempts = 1, backoff_base_secs = 0 },
        }
      end,
    },
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(exhausted_record),
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = { pr_open = function() return { number = 1, url = "u", state = "open" } end },
    merge = {
      rebase = function()
        exhausted_seen.rebase = exhausted_seen.rebase + 1
        return nil, "rebase failed [git_lock]: cannot lock ref", lock_diag
      end,
      run = function() return { ok = true } end,
    },
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if exhausted_record.status == "ready" then
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    sleep = function(ms) exhausted_sleeps[#exhausted_sleeps + 1] = ms end,
    defer = function() return {} end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_exhausted = runtime.new(exhausted_deps)
  rt_exhausted.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_exhausted.run_pending()
  eq(exhausted_seen.rebase, 3, "an exhausted git_lock stops after three attempts")
  eq(#exhausted_sleeps, 2, "an exhausted replay backs off twice")
  eq(exhausted_record.status, "failed", "an exhausted git_lock fails the task")
  eq(type(exhausted_record.failure), "table", "the failure is a typed record")
  eq(exhausted_record.failure and exhausted_record.failure.cause, "git_lock",
    "the failure names git_lock")
  eq(exhausted_record.failure and exhausted_record.failure.transient, true,
    "git_lock is transient")
  has(tostring(exhausted_record.failure_reason), "git_lock", "the reason names git_lock")
  has(tostring(exhausted_record.failure_reason), "retry", "the reason names the remedy")
  eq(exhausted_record.branch, "metronome/t1", "the failure keeps the branch")
  eq(exhausted_record.worktree, "/tmp/wt-t1", "the failure keeps the worktree")
  eq(exhausted_record.run_dir, "/tmp/runs/T1", "the failure keeps the transcript directory")
  eq(#(exhausted_record.checkpoints or {}), 2, "the failure keeps the checkpoints")

  
  end
  check_git_lock_replay()

  -- metronome_retry restarts a failed task and resets the attempt budget ----
  local retry_record = {
    id = "T1", status = "failed", title = "t", checks = { "true" },
    branch = "metronome/t1", worktree = "/tmp/wt-t1",
    failure = { cause = "network", message = "boom", remedy = "retry", transient = true, attempts = 3 },
  }
  local retried_impl = 0
  local retry_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(retry_record),
    implement = {
      run = function()
        retried_impl = retried_impl + 1
        return { ok = false, error = "still down: connection refused" }
      end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = transient_deps.git,
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {},
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    defer = function() return {} end,
    wait_turn_end = false,
    runner = {},
    qualify = {}, questions = {}, analyze = {},
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_retry = runtime.new(retry_deps)
  local retried = rt_retry.retry({ id = "T1" }, { session = "S1" })
  eq(retried and retried.ok, true, "metronome_retry accepts a failed task")
  rt_retry.run_pending()
  eq(retried_impl, 1, "metronome_retry re-dispatches the task from its checkpoint")
  eq(retry_record.status, "failed", "the retried task failed again")
  eq(retry_record.failure and retry_record.failure.attempts, 1,
    "a human retry resets the attempt budget")
  eq(rt_retry.last_background and rt_retry.last_background.failure
    and rt_retry.last_background.failure.cause, "network",
    "the background record carries the typed failure, not only the raw error")
  eq(rt_retry.last_background and rt_retry.last_background.decision
    and rt_retry.last_background.decision.action, "auto_retry",
    "the background record carries the resume decision")
  eq(rt_retry.last_background and rt_retry.last_background.retrying, true,
    "the background record says the task is being retried")
  eq(type(rt_retry.last_background and rt_retry.last_background.error), "string",
    "the background record keeps the raw step error")

  -- An async retry that completes must re-drain after itself: the queued job
  -- runs off the drain's turn, so nothing else would notice the freed slot or a
  -- newly ready dependent. A drain that stops after a successful retry is the
  -- worst case this runtime exists to rule out.
  local async_record = {
    id = "T1", status = "failed", title = "t", checks = { "true" },
    branch = "metronome/t1", worktree = "/tmp/wt-t1",
    failure = { cause = "network", message = "boom", remedy = "retry", transient = true, attempts = 1 },
  }
  local async_impl = 0
  local async_ticks = 0
  local async_queue = {}
  local async_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = mem_state(async_record),
    implement = {
      run = function()
        async_impl = async_impl + 1
        return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
      end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = transient_deps.git,
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function()
        async_ticks = async_ticks + 1
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn)
      async_queue[#async_queue + 1] = fn
      return { cancel = function() end }
    end,
    async = true,
    defer = function() return {} end,
    wait_turn_end = false,
    runner = {},
    qualify = {}, questions = {},
    analyze = { gate = function() return { ok = true } end },
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_async = runtime.new(async_deps)
  local queued_retry = rt_async.retry({ id = "T1" }, { session = "S1" })
  eq(queued_retry and queued_retry.ok, true, "the retry is queued, not run")
  eq(async_impl, 0, "the retry job has not run when the handler returns")
  local async_guard = 0
  while #async_queue > 0 and async_guard < 50 do
    async_guard = async_guard + 1
    local fn = table.remove(async_queue, 1)
    fn()
  end
  eq(async_impl, 1, "the queued retry job runs the task off the drain's turn")
  eq(async_ticks >= 2,
    true, "a completed retry job re-drains the scheduler instead of stopping the workflow")

  -- metronome_status exposes the resume state for every task ----------------
  -- A failed task must be readable and resumable from the status tool alone:
  -- its checkpoint, its typed last error and the action a human (or the
  -- scheduler) takes next.
  local function check_status_view()
    local status_checkpoints = load_module("state")
  local status_record = {
    id = "T1", status = "failed", title = "resume me",
    branch = "metronome/t1", worktree = "/tmp/wt-t1",
    checkpoints = { { sha = "abc123" }, { sha = "def456" } },
    failure = { cause = "git_identity", message = "empty ident name",
      remedy = "set git user.email and user.name", transient = true,
      attempts = 2, at = 10, next_retry_at = 70 },
  }
  local legacy_record = {
    id = "T2", status = "failed", title = "old journal",
    failure_reason = "git commit exit 1: Sur la branche main",
  }
  local status_deps = {
    config = { load = function() return { project = { repo = "/tmp/repo" } } end },
    recover = recover_mod,
    state = {
      load = function()
        return { tasks = { T1 = status_record, T2 = legacy_record } }
      end,
      checkpoint_of = function(t) return status_checkpoints.checkpoint_of(t) end,
    },
    paths = function() return paths end,
    spawn = function(fn) fn() end,
    wait_turn_end = false,
    roles = deps.roles,
    implement = deps.implement or {},
    qualify = {}, analyze = {}, pipeline = {}, runner = {}, git = {},
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    calibrate = {}, fence = {}, mode = {}, questions = {},
  }
  local rt_status = runtime.new(status_deps)
  local listed = rt_status.status({})
  eq(listed and listed.ok, true, "metronome_status lists the tasks")
  local view = listed.tasks and listed.tasks.T1
  eq(view and view.checkpoint, "def456", "status exposes the last checkpoint")
  eq(view and view.branch, "metronome/t1", "status exposes the branch")
  eq(view and view.worktree, "/tmp/wt-t1", "status exposes the worktree")
  eq(view and view.last_error and view.last_error.cause, "git_identity",
    "status exposes the typed last error")
  eq(view and view.retry_action and view.retry_action.action, "auto_retry",
    "status exposes the resume action")
  eq(view and view.retry_action and view.retry_action.attempts, 2,
    "the resume action carries the attempt count")
  eq(view and view.retry_action and view.retry_action.max_attempts, 3,
    "the resume action carries the attempt bound")
  eq(view and view.retry_action and view.retry_action.tool, "metronome_retry",
    "the resume action names the tool")
  eq(view and view.status, "failed", "the raw status field is still there")
  eq(view and view.failure and view.failure.cause, "git_identity",
    "the raw failure object is still there")
  local legacy_view = listed.tasks and listed.tasks.T2
  eq(legacy_view and legacy_view.last_error ~= nil, true,
    "a legacy failure_reason still reads as a typed last error")
  eq(legacy_view and legacy_view.retry_action and legacy_view.retry_action.action, "manual",
    "a legacy failure is a manual resume")
  local detailed = rt_status.status({ id = "T1" })
  eq(detailed and detailed.task and detailed.task.checkpoint, "def456",
    "the by-id detail exposes the checkpoint too")
  eq(detailed and detailed.task and detailed.task.retry_action
    and detailed.task.retry_action.action, "auto_retry",
    "the by-id detail exposes the resume action too")
  end
  check_status_view()

  maki.session.notify = saved_notify
  maki.session.prompt = saved_prompt

end
