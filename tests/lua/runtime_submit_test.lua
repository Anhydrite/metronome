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

  do
  -- A merge conflict is a real implementation cycle, not a merge relaunch ----
  --
  -- `merge.run` returns a conflict (as it does after a failed rebase): the
  -- task goes back to running/implement with the files and hunks journalled and
  -- handed to the implementer, the open PR is reused (no second one), and the
  -- pipeline runs again — bounded by `merge.max_conflict_retries`.
  local function copy_task(task)
    local out = {}
    for key, value in pairs(task) do
      out[key] = value
    end
    return out
  end

  local function conflict_payload()
    return {
      ok = false,
      conflict = true,
      conflict_files = "docs/configuration.md",
      conflict_file_list = { "docs/configuration.md" },
      conflict_hunks = {
        { file = "docs/configuration.md", start = 12,
          text = "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> 59738f2" },
      },
      conflict_commit = "59738f2",
      base = "main",
      base_sha = "base123",
      upstream = "origin/main",
      rebase_command = "git rebase origin/main",
      error = "rebase failed (conflicts: docs/configuration.md)",
    }
  end

  -- `conflicts` conflicts are returned before the merge succeeds; `math.huge`
  -- keeps conflicting. `initial` is what a reload would hand back from the
  -- journal (`status`, `phase`, `conflict_retries`). `payload_fn` lets a test
  -- choose the shape of the conflict (a flag, a file list, `conflict_files`
  -- alone, with or without `error`).
  local function conflict_deps(max_retries, conflicts, initial, payload_fn)
    local record = { id = "T1", status = "ready", title = "t", checks = { "true" } }
    for key, value in pairs(initial or {}) do
      record[key] = value
    end
    local events = {}
    local pr_opens = 0
    local resets_taken = 0
    local merge_calls = 0
    local dispatched_conflict = false
    local impl_conflicts = {}
    local impl_calls = 0
    -- Forward-declared: `merge.run` below journals the note through
    -- `deps.state`, and a local declared by the table constructor would not be
    -- in scope inside that constructor.
    local deps
    deps = {
      config = {
        load = function()
          return {
            project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
            checks = { default = { "true" }, timeout_secs = 10 },
            merge = { method = "squash", auto_merge = true, max_conflict_retries = max_retries },
            deploy = { auto_deploy = false, plan_file = "deploy.md" },
          }
        end,
      },
      roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
      state = {
        -- A copy, not the live table: every run reads what a reload from the
        -- journal would give it, so a counter that was not persisted is lost.
        load = function() return { tasks = { T1 = copy_task(record) } } end,
        transition = function(_, id, status, fields)
          events[#events + 1] = {
            kind = "transition",
            status = status,
            phase = fields and fields.phase,
            reason = fields and fields.reason,
          }
          record.status = status
          if fields and fields.phase then record.phase = fields.phase end
          return { id = id, status = status }
        end,
        set_fields = function(_, _, fields)
          events[#events + 1] = { kind = "field", fields = fields }
          for k, v in pairs(fields or {}) do record[k] = v end
          return true
        end,
        append = function(_, event)
          events[#events + 1] = event
          return true
        end,
      },
      implement = {
        run = function(run_opts)
          impl_calls = impl_calls + 1
          if run_opts.conflict ~= nil then
            impl_conflicts[#impl_conflicts + 1] = run_opts.conflict
          end
          return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "sha" .. impl_calls }
        end,
        read_sheet = function() return {} end,
      },
      checks = { verify = function() return { ok = true } end, write_report = function() end },
      converge = { run = function() return { ok = true } end },
      review = { review = function() return { ok = true, approved = true, sha = "reviews ha" } end },
      git = {
        pr_open = function()
          pr_opens = pr_opens + 1
          return { number = 1, url = "u", state = "open" }
        end,
        push = function() return true end,
        rev_parse = function() return "base123" end,
        reset_hard = function() resets_taken = resets_taken + 1; return "sha" end,
      },
      merge = {
        run = function()
          merge_calls = merge_calls + 1
          if merge_calls <= conflicts then
            local conflict = (payload_fn or conflict_payload)()
            -- `merge.run` returns the conflict and the repairable wording but
            -- does not journal it: only the runtime, once it has committed to
            -- the repair, announces it. The note count assertions below prove
            -- the runtime journals it exactly once per conflict.
            return conflict
          end
          record.status = "merged"
          return { ok = true }
        end,
      },
      deploy = { run = function() return { ok = true } end },
      pipeline = {
        tick = function(tick_opts)
          if not dispatched_conflict then
            dispatched_conflict = true
            tick_opts.dispatch({ id = "T1" })
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
    return {
      deps = deps,
      record = record,
      events = events,
      impl_conflicts = impl_conflicts,
      impl_calls = function() return impl_calls end,
      pr_opens = function() return pr_opens end,
      resets = function() return resets_taken end,
      merge_calls = function() return merge_calls end,
    }
  end

  local function events_matching(events, fn)
    local out = {}
    for _, event in ipairs(events) do
      if fn(event) then
        out[#out + 1] = event
      end
    end
    return out
  end

  local function failed_transitions(events)
    return events_matching(events, function(event)
      return event.kind == "transition" and event.status == "failed"
    end)
  end

  local function repair_notes(events, label)
    return events_matching(events, function(event)
      return event.kind == "note"
        and tostring(event.text):find(label, 1, true) ~= nil
    end)
  end

  -- The first conflict happens because the repo moved under the branch and the
  -- same lines changed. That is repairable without a human: back to implement,
  -- on the fresh base, with the files and hunks journalled and quoted in the
  -- prompt.
  local repaired = conflict_deps(2, 1)
  local rt_repair = runtime.new(repaired.deps)
  rt_repair.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_repair.run_pending()
  eq(repaired.record.status, "merged", "the repaired task merges instead of failing")
  eq(repaired.merge_calls(), 2, "the merge is attempted once after the repair")
  eq(repaired.pr_opens(), 1, "the open PR is reused: no second PR is opened")
  eq(repaired.resets(), 1, "the branch is reset onto the fresh base once")
  eq(repaired.record.conflict_retries, 1, "the repair counter is persisted on the task")
  eq(repaired.record.conflict_retried, true, "the task records that it repaired a conflict")
  eq(repaired.record.phase, "review", "the repaired task went through the pipeline again")
  -- Never `failed` on the first conflict: the repair is a continuation.
  eq(#failed_transitions(repaired.events), 0, "a first conflict is never journalled as failed")
  -- The implementation turn received the conflict facts, as data.
  eq(repaired.impl_calls(), 2, "the work is redone once after the conflict")
  eq(#repaired.impl_conflicts, 1, "only the repair turn receives a conflict")
  eq(repaired.impl_conflicts[1] and repaired.impl_conflicts[1].files
    and repaired.impl_conflicts[1].files[1], "docs/configuration.md",
    "the repair turn receives the conflicting file")
  eq(repaired.impl_conflicts[1] and repaired.impl_conflicts[1].commit, "59738f2",
    "the repair turn receives the faulty commit")
  -- The journal note names the file, its hunk and the commit: the implementer
  -- and the human read the same facts.
  local notes = repair_notes(repaired.events, "merge conflict (repairable)")
  eq(#notes, 1, "one conflict produces exactly one journal note")
  local note_text = notes[1] and notes[1].text or ""
  eq(note_text:find("docs/configuration.md", 1, true) ~= nil, true, "the note names the conflicting file")
  eq(note_text:find("=======", 1, true) ~= nil, true, "the note carries the conflict hunk")
  eq(note_text:find("59738f2", 1, true) ~= nil, true, "the note names the faulty commit")
  eq(note_text:find("git rebase origin/main", 1, true) ~= nil, true, "the note names the base command")
  -- The counter is written with the status in one field patch, so a reload
  -- resumes in implement with the conflict already journalled.
  local repair_fields = events_matching(repaired.events, function(event)
    return event.kind == "field" and event.fields and event.fields.conflict_retries == 1
  end)
  eq(#repair_fields, 1, "the repair persists conflict_retries once")
  eq(repair_fields[1] and repair_fields[1].fields.status, "running",
    "the repair puts the task back in running")
  eq(repair_fields[1] and repair_fields[1].fields.phase, "implement",
    "the repair puts the task back in the implement phase")

  -- Two real repairs under the configured bound: the counter goes 1 then 2, and
  -- each repair re-pushes the same PR (never a second one).
  local twice = conflict_deps(2, 2)
  local rt_twice = runtime.new(twice.deps)
  rt_twice.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_twice.run_pending()
  eq(twice.record.status, "merged", "a task that repaired twice still merges")
  eq(twice.merge_calls(), 3, "the merge is retried after each repair")
  eq(twice.record.conflict_retries, 2, "two repairs count 2, the configured bound")
  eq(twice.pr_opens(), 1, "two repairs still reuse the single open PR")
  eq(twice.resets(), 2, "the branch is reset once per repair")
  eq(twice.impl_calls(), 3, "each repair redoes the work once")
  eq(#twice.impl_conflicts, 2, "each repair turn receives the conflict")
  eq(#(twice.impl_conflicts[2] and twice.impl_conflicts[2].hunks or {}), 1,
    "the second repair turn still receives the conflict hunks")
  eq(#failed_transitions(twice.events), 0, "bounded repairs never mark the task failed")
  local counters = {}
  for _, event in ipairs(events_matching(twice.events, function(event)
    return event.kind == "field" and event.fields and event.fields.conflict_retries ~= nil
  end)) do
    counters[#counters + 1] = event.fields.conflict_retries
  end
  eq(#counters, 2, "the counter is persisted on each repair")
  eq(counters[1], 1, "the first repair persists conflict_retries = 1")
  eq(counters[2], 2, "the second repair persists conflict_retries = 2")
  eq(#repair_notes(twice.events, "merge conflict (repairable)"), 2,
    "each conflict produces exactly one note (no duplicate)")

  -- A reloaded task resumes with its persisted counter: it starts at 1 and the
  -- second repair still happens because the bound is read from the config.
  local reloaded = conflict_deps(2, 1, {
    status = "running", phase = "implement", conflict_retried = true, conflict_retries = 1,
  })
  local rt_reloaded = runtime.new(reloaded.deps)
  -- A second process starts: it reads the journal (the copied record) and
  -- resumes the task where the first one left it.
  rt_reloaded.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_reloaded.run_pending()
  eq(reloaded.record.status, "merged", "a reloaded task at 1 repair still merges after the next one")
  eq(reloaded.record.conflict_retries, 2, "the reloaded counter continues from 1 to 2")
  eq(#reloaded.impl_conflicts, 1, "the reloaded run still hands over the conflict")
  eq(reloaded.pr_opens(), 1, "the reloaded repair reuses the PR")

  -- A reloaded task already at the bound escalates without another repair.
  local exhausted = conflict_deps(2, math.huge, {
    status = "running", phase = "implement", conflict_retried = true, conflict_retries = 2,
  })
  local rt_exhausted = runtime.new(exhausted.deps)
  rt_exhausted.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_exhausted.run_pending()
  eq(exhausted.record.status, "failed", "a reloaded task at the bound escalates instead of repairing")
  eq(#exhausted.impl_conflicts, 0, "no repair is attempted once the persisted bound is reached")
  eq(exhausted.impl_calls(), 1, "only the initial implementation turn runs")
  local exhausted_transitions = failed_transitions(exhausted.events)
  local exhausted_message = tostring(exhausted_transitions[1] and exhausted_transitions[1].reason or "")
  eq(exhausted_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the reloaded escalation names the conflicting files")
  eq(exhausted_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the reloaded escalation names the exact command")

  -- Beyond the bound, the conflict escalates to a human with the files, the
  -- base and the exact command — not git's raw "rebase failed".
  local escalated = conflict_deps(1, math.huge)
  local rt_escalate = runtime.new(escalated.deps)
  rt_escalate.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_escalate.run_pending()
  eq(escalated.record.status, "failed", "a conflict beyond the bound fails the task")
  eq(escalated.record.conflict_retries, 1, "the bound comes from merge.max_conflict_retries")
  eq(#escalated.impl_conflicts, 1, "the repair turn receives the conflict before escalating")
  eq(escalated.impl_calls(), 2, "one repair is attempted before escalating")
  eq(escalated.pr_opens(), 1, "the escalation still opens no second PR")
  local escalated_transitions = failed_transitions(escalated.events)
  local failure_message = tostring(escalated_transitions[1] and escalated_transitions[1].reason or "")
  eq(failure_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the escalation names the conflicting files")
  eq(failure_message:find("origin/main", 1, true) ~= nil, true,
    "the escalation names the base")
  eq(failure_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the escalation names the exact command")
  local escalation_notes = events_matching(escalated.events, function(event)
    return event.kind == "note" and tostring(event.text):find("cannot be repaired", 1, true) ~= nil
  end)
  eq(#escalation_notes, 1, "the escalation is journalled with the means to act")
  eq(tostring(escalation_notes[1] and escalation_notes[1].text):find("docs/configuration.md", 1, true) ~= nil,
    true, "the escalation note names the conflicting file")

  -- A rebase that conflicts during implement (the base moved under the branch
  -- between the turn and the merge) returns the `merge.rebase` diagnostic shape
  -- (`hunks`/`commit`/`command`), not the `merge.run` result shape. The repair
  -- must still carry the hunks and the faulty commit to the note and the prompt.
  local rebasing = conflict_deps(2, 0)
  local rebase_calls = 0
  rebasing.deps.merge.rebase = function()
    rebase_calls = rebase_calls + 1
    if rebase_calls == 1 then
      return nil, "could not apply 59738f2", {
        conflict = { "docs/configuration.md" },
        hunks = {
          { file = "docs/configuration.md", start = 12,
            text = "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> 59738f2" },
        },
        commit = "59738f2",
        upstream = "origin/main",
        command = "git rebase origin/main",
      }
    end
    return { ok = true, base = "origin/main", sha = "sha" }
  end
  local rt_rebase = runtime.new(rebasing.deps)
  rt_rebase.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_rebase.run_pending()
  eq(rebasing.record.status, "merged", "a rebase conflict during implement is repaired and merges")
  eq(rebasing.record.conflict_retries, 1, "the implement-side rebase conflict counts as a repair")
  eq(#rebasing.impl_conflicts, 1, "the implement-side repair hands the conflict over")
  eq(#(rebasing.impl_conflicts[1] and rebasing.impl_conflicts[1].hunks or {}), 1,
    "the implement-side repair hands over the conflict hunks")
  eq(rebasing.impl_conflicts[1] and rebasing.impl_conflicts[1].commit, "59738f2",
    "the implement-side repair hands over the faulty commit")
  eq(rebasing.impl_conflicts[1] and rebasing.impl_conflicts[1].command, "git rebase origin/main",
    "the implement-side repair hands over the exact command")
  local rebase_notes = repair_notes(rebasing.events, "rebase conflict (repairable)")
  eq(#rebase_notes, 1, "the implement-side conflict is journalled once")
  local rebase_note_text = tostring(rebase_notes[1] and rebase_notes[1].text or "")
  eq(rebase_note_text:find("docs/configuration.md", 1, true) ~= nil, true,
    "the implement-side note names the conflicting file")
  eq(rebase_note_text:find("=======", 1, true) ~= nil, true,
    "the implement-side note carries the conflict hunk")
  eq(rebase_note_text:find("59738f2", 1, true) ~= nil, true,
    "the implement-side note names the faulty commit")
  eq(rebasing.pr_opens(), 1, "the implement-side repair opens no second PR")

  do
  -- Every shape of a repairable conflict is repaired -------------------------
  --
  -- The runtime used to read `conflict` alone. A result that carried only
  -- `conflict_files`, or a bare `conflict = true` with no `error`, fell through
  -- to a failure with "no error details": the journal said repairable, the task
  -- ended failed. All three shapes are the same conflict and must go back to
  -- implement, their files handed over as data.
  local function payload_without_error(mutate)
    local payload = conflict_payload()
    payload.error = nil
    mutate(payload)
    return payload
  end

  local shapes = {
    {
      name = "conflict = true with conflict_files as a table",
      mutate = function(payload)
        payload.conflict = true
        payload.conflict_files = { "docs/configuration.md" }
        payload.conflict_file_list = nil
      end,
    },
    {
      name = "conflict as a file list alone",
      mutate = function(payload)
        payload.conflict = { "docs/configuration.md" }
        payload.conflict_files = nil
        payload.conflict_file_list = nil
      end,
    },
    {
      name = "conflict_files alone",
      mutate = function(payload)
        payload.conflict = nil
        payload.conflict_file_list = nil
      end,
    },
  }
  for _, shape in ipairs(shapes) do
    local case = conflict_deps(2, 1, nil, function()
      return payload_without_error(shape.mutate)
    end)
    local rt_shape = runtime.new(case.deps)
    rt_shape.submit({ intention = "x", fast = false }, { session = "S1" })
    rt_shape.run_pending()
    eq(case.record.status, "merged",
      shape.name .. ": the conflict is repaired, not fatal")
    eq(case.record.conflict_retries, 1,
      shape.name .. ": the repair is counted on the task")
    eq(#failed_transitions(case.events), 0,
      shape.name .. ": no failed transition under the bound")
    eq(case.impl_calls(), 2, shape.name .. ": the work is redone once")
    eq(#case.impl_conflicts, 1, shape.name .. ": the repair turn receives the conflict")
    eq(case.impl_conflicts[1] and case.impl_conflicts[1].files
      and case.impl_conflicts[1].files[1], "docs/configuration.md",
      shape.name .. ": the repair turn receives the conflicting file")
    eq(case.pr_opens(), 1, shape.name .. ": the repair reuses the open PR")
    -- (e) Coherence: no party announces "will be redone on the fresh base"
    -- until the runtime has committed to the repair. merge.run only returns the
    -- wording; the runtime journals it exactly once, when the reset has
    -- actually happened, so a "will be redone" note can never coexist with a
    -- `failed` on the same turn under the bound.
    local repairable_notes = repair_notes(case.events, "will be redone on the fresh base")
    eq(#repairable_notes, 1, shape.name .. ": the runtime journals the repair once")
    eq(#failed_transitions(case.events), 0,
      shape.name .. ": a 'will be redone' note never coexists with a failed task")
  end

  -- (e) Under the bound but unable to repair, nothing announces a repair: if
  -- the fresh base cannot be materialised (`reset_hard` missing or refusing),
  -- the turn never claims "will be redone" and does not fail without a message
  -- — the escalation names the files and the command instead.
  local no_reset_payload = conflict_payload()
  no_reset_payload.error = nil
  local no_reset = conflict_deps(2, math.huge, nil, function() return no_reset_payload end)
  no_reset.deps.git.reset_hard = nil
  local rt_no_reset = runtime.new(no_reset.deps)
  rt_no_reset.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_no_reset.run_pending()
  eq(#repair_notes(no_reset.events, "will be redone on the fresh base"), 0,
    "no 'will be redone' note is written when the repair cannot be committed")
  local no_reset_failures = failed_transitions(no_reset.events)
  eq(#no_reset_failures, 1, "an unrepairable conflict still ends the turn once")
  local no_reset_message = tostring(no_reset_failures[1] and no_reset_failures[1].reason or "")
  eq(no_reset_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the unrepairable conflict names the files")
  eq(no_reset_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the unrepairable conflict names the exact command")
  eq(no_reset_message:find("no error details", 1, true), nil,
    "the unrepairable conflict is never 'no error details'")
  eq(no_reset.impl_conflicts and #no_reset.impl_conflicts, 0,
    "no implementer turn is announced for a repair that did not happen")

  local reset_refused = conflict_deps(2, math.huge, nil, function()
    return no_reset_payload
  end)
  reset_refused.deps.git.reset_hard = function() return nil, "reset refused" end
  local rt_reset_refused = runtime.new(reset_refused.deps)
  rt_reset_refused.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_reset_refused.run_pending()
  eq(#repair_notes(reset_refused.events, "will be redone on the fresh base"), 0,
    "a refused reset writes no 'will be redone' note")
  eq(#failed_transitions(reset_refused.events), 1,
    "a refused reset escalates with the conflict facts, once")
  local refused_message = tostring(failed_transitions(reset_refused.events)[1]
    and failed_transitions(reset_refused.events)[1].reason or "")
  eq(refused_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the refused-reset escalation names the files")
  eq(refused_message:find("no error details", 1, true), nil,
    "the refused-reset escalation is never 'no error details'")

  -- (d)/(f) Beyond the bound, the escalation names the files, the base with its
  -- SHA and the exact command, and a result carrying conflict files never
  -- produces a failure without a message — even when `error` is absent.
  local escalated_shape = conflict_deps(1, math.huge, nil, function()
    return payload_without_error(function(payload)
      payload.conflict = nil
      payload.conflict_file_list = nil
      payload.conflict_files = "docs/configuration.md"
    end)
  end)
  local rt_escalated_shape = runtime.new(escalated_shape.deps)
  rt_escalated_shape.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_escalated_shape.run_pending()
  eq(escalated_shape.record.status, "failed",
    "a conflict beyond the bound still fails the task")
  local shape_failures = failed_transitions(escalated_shape.events)
  eq(#shape_failures, 1, "the escalation is a single failed transition")
  local shape_message = tostring(shape_failures[1] and shape_failures[1].reason or "")
  eq(shape_message ~= "", true, "a conflict failure is never written without a message")
  eq(shape_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the escalation names the conflicting files")
  eq(shape_message:find("origin/main", 1, true) ~= nil, true,
    "the escalation names the base")
  eq(shape_message:find("base123", 1, true) ~= nil, true,
    "the escalation names the base SHA")
  eq(shape_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the escalation names the exact command")
  eq(shape_message:find("no error details", 1, true), nil,
    "the escalation is never 'no error details'")
  -- The runtime hands the failure policy a typed conflict diagnosis (cause
  -- conflict, the escalation verbatim), so the persisted record keeps the
  -- files, the base and the command instead of degrading to "no error details".
  local failure_events = events_matching(escalated_shape.events, function(event)
    return event.kind == "field" and event.fields and event.fields.failure ~= nil
  end)
  eq(#failure_events, 1, "the conflict failure is persisted once")
  local persisted = failure_events[1] and failure_events[1].fields.failure or {}
  eq(persisted.cause, "conflict", "the persisted failure is typed as a conflict")
  local persisted_message = tostring(persisted.message or "")
  eq(persisted_message ~= "", true, "the persisted conflict failure carries a message")
  eq(persisted_message:find("no error details", 1, true), nil,
    "the persisted conflict failure is never 'no error details'")
  eq(persisted_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the persisted conflict failure names the files")
  eq(persisted_message:find("base123", 1, true) ~= nil, true,
    "the persisted conflict failure names the base SHA")
  eq(persisted_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the persisted conflict failure names the exact command")

  -- The implement-side rebase diagnostic is read the same way: `conflict_files`
  -- alone, with no `conflict` field, is the same repairable conflict.
  local rebasing_files = conflict_deps(2, 0)
  local rebase_file_calls = 0
  rebasing_files.deps.merge.rebase = function()
    rebase_file_calls = rebase_file_calls + 1
    if rebase_file_calls == 1 then
      return nil, "could not apply 59738f2", {
        conflict_files = { "docs/configuration.md" },
        hunks = {
          { file = "docs/configuration.md", start = 12,
            text = "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> 59738f2" },
        },
        commit = "59738f2",
        upstream = "origin/main",
        command = "git rebase origin/main",
      }
    end
    return { ok = true, base = "origin/main", sha = "sha" }
  end
  local rt_rebase_files = runtime.new(rebasing_files.deps)
  rt_rebase_files.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_rebase_files.run_pending()
  eq(rebasing_files.record.status, "merged",
    "an implement-side conflict flagged only by conflict_files is repaired")
  eq(rebasing_files.record.conflict_retries, 1,
    "the implement-side repair is counted")
  eq(#failed_transitions(rebasing_files.events), 0,
    "the implement-side conflict never fails the task under the bound")
  eq(#rebasing_files.impl_conflicts, 1,
    "the implement-side repair hands the conflict over")
  end

  -- The prompt and the config carry the conflict contract -------------------
  local implement = load_module("implement")
  local conflict_prompt = implement.render_prompt(
    { id = "T1", title = "t", files = { "docs/configuration.md" }, checks = { "true" } },
    "sheet",
    { repo = "/tmp/repo", worktree = "/tmp/wt", branch = "b", base_ref = "main" },
    {
      conflict = repaired.impl_conflicts[1],
    })
  eq(conflict_prompt:find("Rebase conflict to resolve", 1, true) ~= nil, true,
    "the prompt has a conflict section")
  eq(conflict_prompt:find("docs/configuration.md", 1, true) ~= nil, true,
    "the prompt names the conflicting file")
  eq(conflict_prompt:find("=======", 1, true) ~= nil, true,
    "the prompt quotes the conflict hunk")
  eq(conflict_prompt:find("data, not", 1, true) ~= nil, true,
    "the prompt says the conflict facts are data")
  eq(conflict_prompt:find("git rebase origin/main", 1, true) ~= nil, true,
    "the prompt names the exact command")
  eq(conflict_prompt:find("This is the epic branch", 1, true), nil,
    "a subtask repair turn is not described as an epic branch")
  local epic_conflict_prompt = implement.render_prompt(
    { id = "E1", title = "epic", kind = "epic", files = {}, checks = { "true" } },
    "sheet",
    { repo = "/tmp/repo", worktree = "/tmp/wt", branch = "b", base_ref = "main" },
    { conflict = { files = { "docs/configuration.md" }, base = "main",
      base_sha = "base123", command = "git rebase origin/main" } })
  eq(epic_conflict_prompt:find("This is the epic branch", 1, true) ~= nil, true,
    "an epic repair turn says the branch itself is the work")
  eq(epic_conflict_prompt:find("base123", 1, true) ~= nil, true,
    "an epic repair turn carries the base with its SHA")
  eq(epic_conflict_prompt:find("reset onto the fresh base", 1, true) ~= nil, true,
    "an epic repair turn says the worktree was reset onto the fresh base")
  eq(epic_conflict_prompt:find("origin/b", 1, true) ~= nil, true,
    "an epic repair turn says to recover the branch content from origin/<branch>")
  eq(epic_conflict_prompt:find("origin/main", 1, true) ~= nil, true,
    "an epic repair turn says to compare against origin/<base>")
  local plain_prompt = implement.render_prompt(
    { id = "T1", title = "t", files = {}, checks = {} }, "sheet",
    { repo = "/tmp/repo", worktree = "/tmp/wt", branch = "b", base_ref = "main" }, {})
  eq(plain_prompt:find("Rebase conflict to resolve", 1, true), nil,
    "a normal turn has no conflict section")
  local rendered_config = runtime.render_config({
    repo = "/tmp/repo", base_ref = "main", max_parallel = 1, max_parallel_qualifiers = 1,
    checks = { "true" }, auto_merge = true, auto_deploy = false, deploy_confirm = false,
    roles = {
      qualifier = { model = "m", thinking = "low" },
      analyst = { model = "m", thinking = "low" },
      implementer = { model = "m", thinking = "low" },
      reviewer = { model = "m", thinking = "low" },
      deployer = { model = "m", thinking = "low" },
    },
  })
  eq(rendered_config:find("%[merge%]%s*auto_merge") ~= nil, true, "the config has a merge section")
  eq(rendered_config:find("max_conflict_retries = 2", 1, true) ~= nil, true,
    "render_config emits max_conflict_retries")
  end

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

  do
  -- An epic conflict is repaired like a task conflict -----------------------
  --
  local function epic_events(events, fn)
    local out = {}
    for _, event in ipairs(events) do
      if fn(event) then
        out[#out + 1] = event
      end
    end
    return out
  end
  local function epic_failed(events)
    return epic_events(events, function(event)
      return event.kind == "transition" and event.status == "failed"
    end)
  end
  local function epic_notes(events, label)
    return epic_events(events, function(event)
      return event.kind == "note"
        and tostring(event.text):find(label, 1, true) ~= nil
    end)
  end
  --
  -- An epic has no implementation of its own, but the epic branch is a branch
  -- to reconcile: an implementer turn on that branch, with the conflict facts
  -- as data, resolves it; the existing PR is updated (no second PR) and the
  -- merge is retried, bounded by `merge.max_conflict_retries`. Beyond the bound
  -- the escalation names the files, the base with its SHA and the command
  -- instead of failing without a message.
  local function epic_conflict_deps(max_retries, conflicts, opts)
    opts = type(opts) == "table" and opts or {}
    local record = {
      id = "T1", status = "ready", title = "epic: two things", kind = "epic",
      branch = "metronome/epic/demo-0001", base_ref = "main", checks = { "true" },
    }
    local events = {}
    local pr_opens = 0
    local impl_conflicts = {}
    local impl_calls = 0
    local impl_push_flags = {}
    local merge_calls = 0
    local resets = {}
    local pushes = {}
    local rev_parses = {}
    -- The order the repair actually happens in: the branch is put back on a
    -- clean state before the implementer works, and the PR is reused after.
    local order = {}
    local dispatched = false
    local deps
    deps = {
      config = {
        load = function()
          return {
            project = { repo = "/tmp/repo", base_ref = "main" },
            checks = { default = { "true" }, timeout_secs = 10 },
            merge = { method = "squash", auto_merge = true, auto_rebase = true,
              max_conflict_retries = max_retries },
            deploy = { auto_deploy = true, plan_file = "deploy.md" },
          }
        end,
      },
      roles = { session_opts = function() return { system = "", model_spec = "m", thinking = "low", tools = {} } end },
      state = {
        load = function() return { tasks = { T1 = record } } end,
        transition = function(_, id, status, fields)
          events[#events + 1] = {
            kind = "transition",
            status = status,
            phase = fields and fields.phase,
            reason = fields and fields.reason,
          }
          record.status = status
          return { id = id, status = status }
        end,
        set_fields = function(_, _, fields)
          events[#events + 1] = { kind = "field", fields = fields }
          for k, v in pairs(fields or {}) do record[k] = v end
          return true
        end,
        append = function(_, event)
          events[#events + 1] = event
          return true
        end,
      },
      implement = {
        run = function(o)
          impl_calls = impl_calls + 1
          local call = impl_calls
          impl_push_flags[#impl_push_flags + 1] = o.push
          order[#order + 1] = "implement"
          if o.conflict ~= nil then
            impl_conflicts[#impl_conflicts + 1] = o.conflict
          end
          if opts.impl_ok == false
            or (opts.impl_fail_times and call <= opts.impl_fail_times) then
            return { ok = false, error = opts.impl_error or "implementer crashed" }
          end
          if opts.impl_no_changes
            or (opts.impl_no_op_times and call <= opts.impl_no_op_times) then
            -- `run_impl` reports a benign turn that committed nothing this
            -- way: `ok = true` with the head still on the fresh base.
            return {
              ok = true,
              no_changes = true,
              sha = opts.impl_sha or "base123",
              ctx = { worktree = "/tmp/wt", branch = "metronome/epic/demo-0001" },
            }
          end
          return {
            ok = true,
            -- A real repair commits: the branch head moves off the fresh base.
            sha = opts.impl_sha or "repaired1",
            ctx = { worktree = "/tmp/wt", branch = "metronome/epic/demo-0001" },
          }
        end,
        read_sheet = function() return {} end,
      },
      checks = { verify = function() return { ok = true } end, write_report = function() end },
      converge = { run = function() return { ok = true } end },
      review = { review = function() return { ok = true, approved = true } end },
      git = {
        fetch = function() return true end,
        rev_parse = function(_, ref)
          rev_parses[#rev_parses + 1] = ref
          -- Each ref resolves to its own SHA, and the epic branch tip differs
          -- from the fresh base on purpose: a reset onto the wrong ref would
          -- be visible in the test instead of passing by accident.
          local shas = opts.shas or {
            ["origin/main"] = "base123",
            ["origin/metronome/epic/demo-0001"] = "tip999",
          }
          return shas[ref]
        end,
        branch_reset = function() return true end,
        reset_hard = function(worktree, sha)
          resets[#resets + 1] = { worktree = worktree, sha = sha }
          order[#order + 1] = "reset"
          return sha
        end,
        push_branch = function() return true end,
        push = function(_, name)
          pushes[#pushes + 1] = name
          order[#order + 1] = "push"
          return true
        end,
        pr_open = function()
          pr_opens = pr_opens + 1
          return { number = 7, url = "https://example.test/pr/7", state = "open" }
        end,
        worktree_add = function(_, wt) return wt end,
        worktree_remove = function() return true end,
      },
      merge = {
        run = function()
          merge_calls = merge_calls + 1
          order[#order + 1] = "merge"
          if merge_calls <= conflicts then
            -- `conflict = true` with `conflict_files` as a table, and no
            -- `error`: the runtime must repair it without inventing a failure.
            return (opts.payload or function()
              return {
                ok = false,
                conflict = true,
                conflict_files = { "docs/configuration.md" },
                conflict_hunks = {
                  { file = "docs/configuration.md", start = 12,
                    text = "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> 59738f2" },
                },
                conflict_commit = "59738f2",
                base = "main",
                base_sha = "base123",
                upstream = "origin/main",
                rebase_command = "git rebase origin/main",
              }
            end)()
          end
          return { ok = true }
        end,
      },
      deploy = {
        run = function()
          record.status = "deployed"
          return { ok = true, deployed = true }
        end,
      },
      pipeline = {
        tick = function(tick_opts)
          if not dispatched then
            dispatched = true
            tick_opts.dispatch({ id = "T1" })
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
    return {
      deps = deps,
      record = record,
      events = events,
      impl_conflicts = impl_conflicts,
      impl_calls = function() return impl_calls end,
      impl_push_flags = impl_push_flags,
      pr_opens = function() return pr_opens end,
      merge_calls = function() return merge_calls end,
      resets = resets,
      pushes = pushes,
      rev_parses = rev_parses,
      order = order,
    }
  end

  local epic_repair = epic_conflict_deps(2, 1)
  local rt_epic_repair = runtime.new(epic_repair.deps)
  rt_epic_repair.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_repair.run_pending()
  eq(epic_repair.merge_calls(), 2, "the epic merge is retried after the repair")
  eq(epic_repair.pr_opens(), 1, "the repaired epic reuses its single PR")
  eq(epic_repair.impl_calls(), 1, "the epic repair runs one implementer turn")
  eq(epic_repair.impl_push_flags[1], false,
    "the implementer must not push the epic branch: the runtime pushes it after the redo")
  eq(#epic_repair.impl_conflicts, 1, "the epic repair hands the conflict over")
  eq(epic_repair.impl_conflicts[1] and epic_repair.impl_conflicts[1].files
    and epic_repair.impl_conflicts[1].files[1], "docs/configuration.md",
    "the epic repair turn receives the conflicting file")
  eq(epic_repair.impl_conflicts[1] and epic_repair.impl_conflicts[1].commit, "59738f2",
    "the epic repair turn receives the commit git could not replay")
  eq(epic_repair.impl_conflicts[1] and epic_repair.impl_conflicts[1].base_sha, "base123",
    "the epic repair turn receives the base with its SHA")
  eq(epic_repair.impl_conflicts[1] and epic_repair.impl_conflicts[1].command,
    "git rebase origin/main", "the epic repair turn receives the exact command")
  -- The branch is put back on the fresh base before the implementer works:
  -- its SHA comes from `origin/<base>`, not from the epic branch's own remote
  -- tip, and the rewritten branch is pushed before the merge is relaunched.
  eq(#epic_repair.resets, 1, "the epic branch is put back on a fresh state once")
  eq(epic_repair.resets[1] and epic_repair.resets[1].worktree,
    maki.fs.joinpath(paths.worktrees, "T1"),
    "the reset targets the epic worktree, not the project checkout")
  eq(epic_repair.resets[1] and epic_repair.resets[1].sha, "base123",
    "the reset uses the SHA of origin/<base>, never the epic branch tip")
  eq(epic_repair.resets[1] and epic_repair.resets[1].sha ~= "tip999", true,
    "the reset is distinguished from a reset onto origin/<branch>")
  local saw_main = false
  for _, ref in ipairs(epic_repair.rev_parses) do
    if ref == "origin/main" then saw_main = true end
  end
  eq(saw_main, true, "the repair resolves the fresh base it reconciles onto")
  -- The push follows the implementer: the reset itself stays local, so a
  -- failed or interrupted turn cannot wipe on `origin` the work the subtasks
  -- merged. Only a branch the implementer has actually redone is pushed, and
  -- that push precedes the relaunched merge.
  local reset_at, impl_at, first_push_after_reset, last_merge_at = nil, nil, nil, nil
  for i, step in ipairs(epic_repair.order) do
    if step == "reset" and not reset_at then reset_at = i end
    if step == "implement" and not impl_at then impl_at = i end
    if step == "push" and reset_at and not first_push_after_reset then
      first_push_after_reset = i
    end
    if step == "merge" then last_merge_at = i end
  end
  eq(#epic_repair.pushes >= 1, true, "the redone epic branch is pushed")
  eq(reset_at ~= nil and first_push_after_reset ~= nil
    and first_push_after_reset > reset_at, true,
    "the push happens after the reset onto the fresh base")
  eq(impl_at ~= nil and first_push_after_reset ~= nil
    and first_push_after_reset > impl_at, true,
    "the epic branch is not pushed before the implementer has redone it")
  eq(first_push_after_reset ~= nil and last_merge_at ~= nil
    and first_push_after_reset < last_merge_at, true,
    "the push happens before the merge is relaunched")
  eq(epic_repair.order[1], "merge", "the first merge comes before any repair")
  eq(epic_repair.order[reset_at + 1], "implement",
    "the fresh reset is immediately followed by the implementer turn")
  eq(epic_repair.order[reset_at + 2], "push",
    "the push follows the implementer turn, never the reset")
  for i, step in ipairs(epic_repair.order) do
    if step == "push" then
      eq(i > impl_at, true, "no push happens before the implementer redoes the branch")
    end
  end
  eq(epic_repair.record.conflict_retries, 1, "the epic repair is counted")
  eq(epic_repair.record.status, "deployed", "the repaired epic deploys")
  eq(#epic_failed(epic_repair.events), 0,
    "the repaired epic is never marked failed")
  eq(#epic_notes(epic_repair.events, "will be redone on the fresh base"), 1,
    "the epic conflict is journalled as repairable once")

  -- A conflict whose payload carries no `base_sha` still names the base with
  -- its SHA: the runtime resolves it from `origin/<base>` rather than handing
  -- the implementer (or the human) a base named "unknown".
  local epic_no_sha = epic_conflict_deps(2, 1, {
    shas = { ["origin/main"] = "fed321", ["origin/metronome/epic/demo-0001"] = "tip999" },
    payload = function()
      return {
        ok = false,
        conflict = { "maki/lua/metronome/runtime.lua" },
        base = "main",
        upstream = "origin/main",
        rebase_command = "git rebase origin/main",
      }
    end,
  })
  local rt_epic_no_sha = runtime.new(epic_no_sha.deps)
  rt_epic_no_sha.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_no_sha.run_pending()
  eq(epic_no_sha.pr_opens(), 1, "a conflict with `conflict` as a table reuses the PR")
  eq(epic_no_sha.impl_calls(), 1, "a conflict with `conflict` as a table is repaired")
  eq(epic_no_sha.impl_conflicts[1] and epic_no_sha.impl_conflicts[1].files
    and epic_no_sha.impl_conflicts[1].files[1], "maki/lua/metronome/runtime.lua",
    "the table form of `conflict` names the files in the repair turn")
  eq(epic_no_sha.impl_conflicts[1] and epic_no_sha.impl_conflicts[1].base_sha, "fed321",
    "the repair turn receives the base SHA resolved by the runtime")
  eq(epic_no_sha.record.conflict_retries, 1, "the table form is counted like any conflict")
  eq(epic_no_sha.resets[1] and epic_no_sha.resets[1].sha, "fed321",
    "the reset follows the base SHA the runtime resolved, not the branch tip")

  -- A repair turn that keeps failing re-enters the cycle under the bound: the
  -- epic is not failed after the first failed turn, and the merge is never
  -- relaunched on a branch that was not redone. Only the exhausted budget
  -- escalates, naming the facts plus the reason the repair did not happen.
  local epic_impl_failed = epic_conflict_deps(2, 1, {
    impl_ok = false, impl_error = "implementer turn aborted",
  })
  local rt_epic_impl_failed = runtime.new(epic_impl_failed.deps)
  rt_epic_impl_failed.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_impl_failed.run_pending()
  eq(epic_impl_failed.impl_calls(), 2,
    "a failed repair turn re-enters the cycle until the bound is spent")
  eq(epic_impl_failed.merge_calls(), 1,
    "the merge is not relaunched after a repair that did not happen")
  eq(epic_impl_failed.pr_opens(), 1, "a failed repair opens no second PR")
  eq(epic_impl_failed.record.conflict_retries, 2,
    "the failed attempts spend the persisted budget, never more than the bound")
  eq(epic_impl_failed.record.conflict_retried, true,
    "the boolean fallback is set so a reload continues the same budget")
  eq(epic_impl_failed.record.status, "failed",
    "the epic escalates only once the repair bound is exhausted")
  local impl_failures = epic_failed(epic_impl_failed.events)
  eq(#impl_failures, 1, "the epic is failed exactly once, at the bound")
  local impl_message = tostring(impl_failures[1] and impl_failures[1].reason or "")
  eq(impl_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the escalation still names the conflicting files")
  eq(impl_message:find("base123", 1, true) ~= nil, true,
    "the escalation still names the base SHA")
  eq(impl_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the escalation still names the exact command")
  eq(impl_message:find("implementer turn aborted", 1, true) ~= nil, true,
    "the escalation says why no repair happened")
  eq(#epic_impl_failed.pushes, 0,
    "a failed repair turn never pushes: the epic branch on origin keeps its work")

  -- A failed turn is not final under the bound: when the next turn redoes the
  -- branch, the epic repairs and deploys without ever being marked failed.
  local epic_flaky = epic_conflict_deps(2, 1, {
    impl_fail_times = 1, impl_error = "transient implementer crash",
  })
  local rt_epic_flaky = runtime.new(epic_flaky.deps)
  rt_epic_flaky.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_flaky.run_pending()
  eq(epic_flaky.impl_calls(), 2, "a failed turn is retried instead of failing the epic")
  eq(epic_flaky.merge_calls(), 2, "the merge is relaunched once the branch is redone")
  eq(epic_flaky.pr_opens(), 1, "the retried repair reuses the single PR")
  eq(epic_flaky.record.status, "deployed", "a flaky repair still deploys the epic")
  eq(#epic_failed(epic_flaky.events), 0,
    "no failed is journaled on the conflict turn while the bound has room")

  -- A turn that commits nothing is not a repair. `run_impl` reports
  -- `ok = true, no_changes = true` when the tree was already clean; right
  -- after the reset the branch sits on the fresh base, so relaunching the
  -- merge would succeed trivially and the epic would deploy without the work
  -- its subtasks merged. The attempt is retried under the bound and the merge
  -- is never relaunched on the unchanged branch.
  local epic_no_op = epic_conflict_deps(2, 1, { impl_no_changes = true })
  local rt_epic_no_op = runtime.new(epic_no_op.deps)
  rt_epic_no_op.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_no_op.run_pending()
  eq(epic_no_op.impl_calls(), 2,
    "a no-op repair turn re-enters the cycle until the bound is spent")
  eq(epic_no_op.merge_calls(), 1,
    "the merge is not relaunched when the branch was not redone")
  eq(epic_no_op.pr_opens(), 1, "a no-op repair opens no second PR")
  eq(epic_no_op.record.conflict_retries, 2,
    "the no-op attempts spend the persisted budget up to the bound")
  eq(epic_no_op.record.status, "failed",
    "an epic whose branch was never redone escalates once the bound is spent")
  eq(#epic_no_op.pushes, 0, "an unchanged epic branch is never pushed")
  eq(epic_no_op.impl_push_flags[1], false,
    "the implementer never pushes the epic branch during a repair attempt")
  local noop_failures = epic_failed(epic_no_op.events)
  local noop_message = tostring(noop_failures[1] and noop_failures[1].reason or "")
  eq(noop_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the no-op escalation names the conflicting files")
  eq(noop_message:find("base123", 1, true) ~= nil, true,
    "the no-op escalation names the base SHA")
  eq(noop_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the no-op escalation names the exact command")
  eq(noop_message:find("no commit", 1, true) ~= nil, true,
    "the no-op escalation says the branch was not redone")

  -- A no-op first turn followed by a real repair: the epic must deploy, not
  -- silently merge the bare base.
  local epic_noop_then_redone = epic_conflict_deps(2, 1, { impl_no_op_times = 1 })
  local rt_epic_noop_then_redone = runtime.new(epic_noop_then_redone.deps)
  rt_epic_noop_then_redone.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_noop_then_redone.run_pending()
  eq(epic_noop_then_redone.impl_calls(), 2,
    "a no-op turn is retried rather than failing the epic")
  eq(epic_noop_then_redone.merge_calls(), 2,
    "the merge follows the turn that actually redid the branch")
  eq(epic_noop_then_redone.record.status, "deployed",
    "the epic deploys only after a real repair")
  eq(#epic_failed(epic_noop_then_redone.events), 0,
    "a no-op turn under the bound is never a failed turn")

  local epic_escalated = epic_conflict_deps(0, math.huge)
  local rt_epic_escalated = runtime.new(epic_escalated.deps)
  rt_epic_escalated.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_escalated.run_pending()
  eq(epic_escalated.record.status, "failed",
    "an epic conflict beyond the bound escalates to a human")
  eq(epic_escalated.impl_calls(), 0,
    "no repair is attempted once the epic bound is reached")
  local epic_failures = epic_failed(epic_escalated.events)
  local epic_message = tostring(epic_failures[1] and epic_failures[1].reason or "")
  eq(epic_message ~= "", true, "the epic escalation carries a message")
  eq(epic_message:find("docs/configuration.md", 1, true) ~= nil, true,
    "the epic escalation names the conflicting files")
  eq(epic_message:find("base123", 1, true) ~= nil, true,
    "the epic escalation names the base SHA")
  eq(epic_message:find("git rebase origin/main", 1, true) ~= nil, true,
    "the epic escalation names the exact command")
  eq(epic_message:find("no error details", 1, true), nil,
    "the epic escalation is never 'no error details'")
  end

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
