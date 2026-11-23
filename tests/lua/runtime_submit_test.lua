-- Tests for the submit context plumbing in maki/lua/metronome/runtime.lua.
--
-- Regression: tools.lua forwards the maki `ctx` as the *second* argument to
-- the runtime method, but `runtime.submit` only accepted `input` and read
-- `input.ctx` (always nil). The qualifier then called `maki.agent.session(nil,
-- ...)` and every submit died with "error converting Lua nil to
-- Either<UserDataRef<LuaCtx>, Table>". These tests pin the contract: the
-- positional ctx wins, `input.ctx` is a fallback, and a missing ctx does not
-- crash the run.

-- The cases below live in top-level functions rather than in one body:
-- Lua 5.1 caps a function at 200 locals, and the single `return function()`
-- that used to hold every case had grown past it (each epic added fixtures).
-- Each case takes the shared fixtures it reads through `env`, so the body the
-- harness calls keeps a small, stable local count and the next epic has
-- headroom. Nothing is skipped: the returned function still calls every case,
-- in the original order.

local function case_qualify_remap(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_qualify_positions(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_qualify_t_form(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
  -- Qualification remaps « T<n> » dependency forms to task ids -------------

  -- The qualifier emits "T<n>" references (T1, T3, ...) that are neither real
  -- ids, nor bare indices, nor titles; they must resolve to the n-th applied
  -- task or the scheduler blocks those tasks forever.
  local remap_deps = function(applied_tasks, sink)
    return {
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
          return { ok = true, tasks = applied_tasks }
        end,
        next_id = function()
          return applied_tasks[1] and applied_tasks[1].id or "T-1"
        end,
        apply = function()
          return { ok = true, tasks = applied_tasks }
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
          sink[id] = fields
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
        branch_create = function(_, name)
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
  end

  local set_fields_t = {}
  local rt2t = runtime.new(remap_deps({
    { id = "T-1", title = "Alpha" },
    { id = "T-2", title = "Beta", depends_on = { "T1" } },
  }, set_fields_t))
  rt2t.submit({ intention = "x", fast = false }, ctx)
  rt2t.run_pending()
  eq(set_fields_t["T-2"] and set_fields_t["T-2"].depends_on
    and set_fields_t["T-2"].depends_on[1], "T-1",
    "« T<n> » dependencies are remapped to task ids")

  -- A title that looks like "T2" must never win over the positional form.
  local set_fields_t2 = {}
  local rt2t2 = runtime.new(remap_deps({
    { id = "T-1", title = "T2" },
    { id = "T-2", title = "Beta" },
    { id = "T-3", title = "Gamma", depends_on = { "T2" } },
  }, set_fields_t2))
  rt2t2.submit({ intention = "x", fast = false }, ctx)
  rt2t2.run_pending()
  eq(set_fields_t2["T-3"] and set_fields_t2["T-3"].depends_on
    and set_fields_t2["T-3"].depends_on[1], "T-2",
    "« T<n> » wins over a title spelled like it")

  -- Precedence: an applied id that literally reads "T2" wins over position 2.
  local set_fields_prec = {}
  local rt2p = runtime.new(remap_deps({
    { id = "T2", title = "Zed" },
    { id = "T-9", title = "Yankee" },
    { id = "T-3", title = "Xray", depends_on = { "T2", "Yankee" } },
  }, set_fields_prec))
  rt2p.submit({ intention = "x", fast = false }, ctx)
  rt2p.run_pending()
  eq(set_fields_prec["T-3"] and set_fields_prec["T-3"].depends_on
    and set_fields_prec["T-3"].depends_on[1], "T2",
    "an exact applied id wins over a « T<n> » batch position")
  eq(set_fields_prec["T-3"] and set_fields_prec["T-3"].depends_on
    and set_fields_prec["T-3"].depends_on[2], "T-9",
    "titles still resolve when no positional form matches")

  -- An unknown reference stays verbatim; the analysis gate blocks it later.
  local set_fields_ghost = {}
  local rt2g = runtime.new(remap_deps({
    { id = "T-1", title = "Alpha" },
    { id = "T-2", title = "Beta", depends_on = { "ghost", "Alpha" } },
  }, set_fields_ghost))
  rt2g.submit({ intention = "x", fast = false }, ctx)
  rt2g.run_pending()
  eq(set_fields_ghost["T-2"] and set_fields_ghost["T-2"].depends_on
    and set_fields_ghost["T-2"].depends_on[1], "ghost",
    "an unknown dependency reference stays verbatim")
  eq(set_fields_ghost["T-2"] and set_fields_ghost["T-2"].depends_on
    and set_fields_ghost["T-2"].depends_on[2], "T-1",
    "known references are still remapped next to an unknown one")
end


local function case_retry_dispatch(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
  -- Retry re-dispatches the task -------------------------------------------

  local implemented = false
  local deps3 = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
        }
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
      read_sheet = function() return {} end,
    },
    state = {
      load = function()
        return { tasks = { T1 = { id = "T1", status = "failed" } } }
      end,
      transition = function(_, id, status)
        return { id = id, status = status }
      end,
      append = function()
        return { tasks = { T1 = { id = "T1", status = "failed" } } }
      end,
      set_fields = function(_, id)
        return { id = id, status = "failed" }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    runner = {}, git = {}, qualify = {}, questions = {},
    analyze = { gate = function() return { ok = true } end },
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    calibrate = {}, fence = {}, mode = {},
    -- `retry` requeues the task and lets the drain dispatch it, like the real
    -- `pipeline.tick`. This fixture's projection never moves, so the stub
    -- dispatches once and reports an empty queue afterwards.
    pipeline = {
      tick = (function()
        local calls = 0
        return function(opts)
          calls = calls + 1
          if calls == 1 then
            opts.dispatch({ id = "T1" })
            return { ok = true, started = { "T1" } }
          end
          return { ok = true, started = {} }
        end
      end)(),
    },
  }
  local rt3 = runtime.new(deps3)
  local retried = rt3.retry({ id = "T1" }, ctx)
  rt3.run_pending()
  eq(type(retried), "table", "retry returns a result")
  eq(retried and retried.background, true, "retry returns before the dispatch finishes")
  eq(retried and retried.requeued, true, "retry hands the task back to the drain")
  eq(type(rt3.last_background) == "table"
    and type(rt3.last_background.results) == "table"
    and rt3.last_background.results[1]
    and rt3.last_background.results[1].error or nil, "stop after dispatch",
    "retry reports the dispatch result on the background record")
  eq(implemented, true, "retry re-dispatches the task instead of only moving its status")
end

local function case_background_ctx(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
  -- The role runner receives the background ctx of the task it runs ---------
  --
  -- Regression: `real_runner` was built once in `prepare`, before
  -- `background_ctx` turned the tool ctx into `{ session = sid }`, and read
  -- only the captured `opts.ctx`. The implementer then opened its session with
  -- the tool's LuaCtx, which the turn cancelled at once (duration_ms 0). The
  -- ctx carried by the request must win.
  local runner_ctx
  -- The fixture's projection is a single record: this variable is both what
  -- `state.load` returns and where `state.transition` writes, so the drain stub
  -- sees the status the retry left behind.
  local retry_status = "failed"
  local deps4 = {
    config = {
      load = function()
        return {
          project = { repo = "/tmp/repo", base_ref = "main" },
          checks = { default = { "true" }, timeout_secs = 10 },
        }
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
        retry_status = status
        return { id = id, status = status }
      end,
      set_fields = function(_, id)
        return { id = id, status = retry_status, slot_wait = true }
      end,
    },
    paths = function()
      return paths
    end,
    spawn = function(fn)
      fn()
    end,
    wait_turn_end = false,
    qualify = {}, questions = {},
    analyze = { gate = function() return { ok = true } end },
    checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
    calibrate = {}, fence = {}, mode = {}, git = {},
    -- `retry` only queues the task: the drain dispatches. The stub plays the
    -- tick the real scheduler would run once the task is parked with
    -- `slot_wait` (its status stays the original `failed`/`abandoned`).
    pipeline = {
      tick = function(opts)
        if retry_status == "failed" or retry_status == "abandoned" then
          retry_status = "running"
          opts.dispatch({ id = "T1" })
          return { ok = true, started = { "T1" } }
        end
        return { ok = true, started = {} }
      end,
    },
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
end

local function case_auto_deploy(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_parallelism(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_stop_and_delete(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_resume(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_merge_conflict(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
  -- The pipeline tick dispatches the task once; this counter used to be
  -- shared with the parallelism case above, in the same flat scope.
  local ticks = 0
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
end

local function case_conflict_repair(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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

  -- T0 regression: a failed merge task whose recorded PR is CLOSED on GitHub ---
  --
  -- `git.pr_open` used to trust the persisted `task.pr.state` field: the task
  -- reused a PR that GitHub had already closed, then `gh pr merge` answered
  -- "not mergeable" and the task died in a loop with no diagnosis (T-20261122-0043
  -- / T-20261122-004c). The runtime now re-reads the PR through the real git
  -- module (with a fake `gh` binary) and recreates it when it is closed, then
  -- merges the PR it just read back.
  do
    local git_module = load_module("git")
    local pr_root = mktmpdir("metronome-runtime-pr")
    local bins = maki.fs.joinpath(pr_root, "bin")
    maki.fs.mkdir(bins, { parents = true })
    local gh_log = maki.fs.joinpath(pr_root, "gh.log")
    maki.fs.write(gh_log, "")
    local function quote(text)
      return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
    end
    -- Same fake-binary trick as pr_test.lua: the script logs its argv, so a
    -- test proves exactly one `pr create` and zero `pr close`.
    local function fake_gh(name, body)
      local path = maki.fs.joinpath(bins, name)
      maki.fs.write(path, "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> "
        .. quote(gh_log) .. "\n" .. body .. "\n")
      local job = maki.fn.jobstart({ "chmod", "+x", path }, { scope = "plugin" })
      maki.fn.jobwait(job, 10000)
      return path
    end
    local function count_gh(needle)
      local n = 0
      for line in (maki.fs.read(gh_log) or ""):gmatch("[^\n]+") do
        if line:find(needle, 1, true) then
          n = n + 1
        end
      end
      return n
    end

    -- The recorded PR #75 is CLOSED on GitHub; `pr create` opens #76, whose
    -- `pr view` is OPEN. `pr close` is logged but must never be called.
    local closed_gh = fake_gh("gh-closed", [[
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ "$3" = "75" ]; then
    echo '{"number":75,"url":"https://github.com/example/repo/pull/75","state":"CLOSED","mergeable":"UNKNOWN","baseRefName":"main"}'
  else
    echo '{"number":76,"url":"https://github.com/example/repo/pull/76","state":"OPEN","mergeable":"MERGEABLE","baseRefName":"main"}'
  fi
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/example/repo/pull/76"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "close" ]; then
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])
    -- An open PR #42: the reuse path, no create, no close.
    local open_gh = fake_gh("gh-open", [[
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","mergeable":"MERGEABLE","baseRefName":"main"}'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "close" ]; then
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])
    -- `gh` cannot be interrogated and creation is refused: the explicit gh
    -- reason must reach the failure message, never an optimistic reuse.
    local failing_gh = fake_gh("gh-fail", [[
echo "gh: authentication failed (HTTP 401): not logged in" >&2
exit 1
]])

    local pr_paths = {
      repo = pr_root,
      root = maki.fs.joinpath(pr_root, "state"),
      tasks = maki.fs.joinpath(pr_root, "tasks"),
      worktrees = maki.fs.joinpath(pr_root, "worktrees"),
      runs = maki.fs.joinpath(pr_root, "runs"),
      prompts = maki.fs.joinpath(pr_root, "prompts"),
      config = maki.fs.joinpath(pr_root, "config.toml"),
    }
    maki.fs.mkdir(pr_paths.root, { parents = true })

    -- The real git module, with only the binary name and the side-effecting
    -- git commands narrowed: pr_open/pr_view/pr_create keep their real
    -- implementation (verification, recreation, persistence).
    local function git_with_gh(gh)
      local wrapped = {}
      for key, value in pairs(git_module) do
        wrapped[key] = value
      end
      local function with_bin(opts)
        local copy = {}
        for key, value in pairs(opts or {}) do
          copy[key] = value
        end
        copy.gh = gh
        return copy
      end
      wrapped.pr_open = function(state, root, id, opts)
        return git_module.pr_open(state, root, id, with_bin(opts))
      end
      wrapped.pr_view = function(ref, opts)
        return git_module.pr_view(ref, with_bin(opts))
      end
      wrapped.pr_create = function(opts)
        return git_module.pr_create(with_bin(opts))
      end
      wrapped.pr_close = function(ref, opts)
        return git_module.pr_close(ref, with_bin(opts))
      end
      -- The merge itself is faked below; these only keep the implement turn
      -- from shelling out to git in a directory that is not a repository.
      wrapped.push = function() return true end
      wrapped.rev_parse = function() return "base123" end
      wrapped.reset_hard = function() return "sha" end
      return wrapped
    end

    local function pr_deps(gh, initial)
      local record = {
        id = "T1", status = "failed", title = "t", phase = "merge",
        checks = { "true" },
        pr = {
          number = 75,
          url = "https://github.com/example/repo/pull/75",
          state = "open",
        },
      }
      for key, value in pairs(initial or {}) do
        record[key] = value
      end
      local events = {}
      local merge_prs = {}
      local impl_conflicts = {}
      local impl_calls = 0
      local dispatched_conflict = false
      local deps
      deps = {
        config = {
          load = function()
            return {
              project = { repo = pr_root, base_ref = "main", max_parallel = 1 },
              checks = { default = { "true" }, timeout_secs = 10 },
              merge = { method = "squash", auto_merge = true, max_conflict_retries = 2 },
              deploy = { auto_deploy = false, plan_file = "deploy.md" },
            }
          end,
        },
        roles = { session_opts = function()
          return { system = "", model_spec = "m", thinking = "low", tools = {} }
        end },
        state = {
          load = function() return { tasks = { T1 = record } } end,
          transition = function(_, id, status, fields)
            events[#events + 1] = {
              kind = "transition", status = status,
              phase = fields and fields.phase,
              reason = fields and fields.reason,
            }
            record.status = status
            if fields and fields.phase then record.phase = fields.phase end
            return { id = id, status = status }
          end,
          set_fields = function(_, _, fields)
            events[#events + 1] = { kind = "field", fields = fields }
            for key, value in pairs(fields or {}) do record[key] = value end
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
            return {
              ok = true,
              ctx = { worktree = pr_paths.repo, branch = "metronome/t1" },
              sha = "sha",
            }
          end,
          read_sheet = function() return {} end,
        },
        checks = { verify = function() return { ok = true } end, write_report = function() end },
        converge = { run = function() return { ok = true } end },
        review = { review = function() return { ok = true, approved = true } end },
        merge = {
          rebase = function() return { ok = true, base = "origin/main" } end,
          run = function(run_opts)
            merge_prs[#merge_prs + 1] = run_opts.pr
            record.status = "merged"
            return { ok = true }
          end,
        },
        git = git_with_gh(gh),
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
        paths = function() return pr_paths end,
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
        deps = deps, record = record, events = events,
        merge_prs = merge_prs, impl_conflicts = impl_conflicts,
        impl_calls = function() return impl_calls end,
      }
    end

    -- (1) Closed PR recreated, then merged on the new number ------------------
    maki.fs.write(gh_log, "")
    local recreated = pr_deps(closed_gh)
    local rt_closed = runtime.new(recreated.deps)
    rt_closed.retry({ id = "T1" }, { session = "S1" })
    rt_closed.run_pending()
    eq(recreated.record.status, "merged",
      "a failed merge task with a closed PR is relaunched and reaches merged")
    eq(recreated.record.pr and recreated.record.pr.number, 76,
      "the closed PR is recreated and the new number is persisted")
    eq(count_gh("pr create"), 1, "exactly one PR is created for the closed PR")
    eq(count_gh("pr close"), 0, "the relaunch closes no PR")
    eq(count_gh("pr view 75"), 1, "the recorded PR is re-read before reuse")
    eq(recreated.merge_prs[1], 76,
      "the merge consumes the PR re-read in this run, not the recorded #75")
    eq(#events_matching(recreated.events, function(event)
      return event.kind == "transition" and event.status == "failed"
    end), 0, "the relaunch never fails on the closed PR")

    -- (2) An OPEN PR is reused: no second PR, no close -----------------------
    maki.fs.write(gh_log, "")
    local reused = pr_deps(open_gh, {
      pr = { number = 42, url = "https://github.com/example/repo/pull/42", state = "open" },
    })
    local rt_open = runtime.new(reused.deps)
    rt_open.retry({ id = "T1" }, { session = "S1" })
    rt_open.run_pending()
    eq(reused.record.status, "merged", "an open PR is reused and merged")
    eq(count_gh("pr create"), 0, "an open PR is never recreated")
    eq(count_gh("pr close"), 0, "an open PR is never closed")
    eq(reused.record.pr and reused.record.pr.number, 42,
      "the persisted PR stays the re-read one")
    eq(reused.merge_prs[1], 42, "the merge consumes the re-read PR")

    -- (3) An unreadable gh is never an optimistic reuse: the explicit reason --
    maki.fs.write(gh_log, "")
    local unreadable = pr_deps(failing_gh)
    local rt_fail = runtime.new(unreadable.deps)
    rt_fail.retry({ id = "T1" }, { session = "S1" })
    rt_fail.run_pending()
    eq(unreadable.record.status, "failed",
      "an unopenable PR fails the task with ok=false")
    local failed_message = tostring(unreadable.record.failure
      and unreadable.record.failure.message or "")
    eq(failed_message:find("cannot open the pull request", 1, true) ~= nil, true,
      "the failure says the pull request cannot be opened")
    eq(failed_message:find("authentication failed", 1, true) ~= nil, true,
      "the failure carries the explicit gh reason, not a generic sentence")
    eq(count_gh("pr create") >= 1, true, "an unreadable gh still attempts creation")
    eq(count_gh("pr close"), 0, "the failure closes no PR")

    -- (4) A conflicting PR triggers the existing bounded repair --------------
    maki.fs.write(gh_log, "")
    local conflicting = pr_deps(open_gh, {
      status = "failed",
      phase = "merge",
      pr = { number = 42, url = "https://github.com/example/repo/pull/42", state = "open" },
    })
    local conflict_calls = 0
    conflicting.deps.merge.run = function(run_opts)
      conflict_calls = conflict_calls + 1
      conflicting.merge_prs[#conflicting.merge_prs + 1] = run_opts.pr
      if conflict_calls == 1 then
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
          mergeable = "conflicting",
          error = "pull request #42 conflicts with main",
        }
      end
      conflicting.record.status = "merged"
      return { ok = true }
    end
    local rt_conflict = runtime.new(conflicting.deps)
    rt_conflict.retry({ id = "T1" }, { session = "S1" })
    rt_conflict.run_pending()
    eq(conflicting.record.status, "merged",
      "a conflicting PR is repaired and merges instead of failing")
    eq(conflicting.record.conflict_retries, 1, "the conflict repair is counted on the task")
    eq(conflict_calls, 2, "the merge is attempted again after the repair")
    eq(#events_matching(conflicting.events, function(event)
      return event.kind == "transition" and event.status == "failed"
    end), 0, "a conflicting PR never transitions to failed before the bound")
    eq(#conflicting.impl_conflicts, 1, "the repair turn receives the conflict facts")
    local given = conflicting.impl_conflicts[1] or {}
    eq(given.files and given.files[1], "docs/configuration.md",
      "the repair turn receives the conflicting files")
    eq(given.base, "main", "the repair turn receives the base")
    eq(given.base_sha, "base123", "the repair turn receives the base sha")
    eq(given.command, "git rebase origin/main", "the repair turn receives the exact command")
    eq(conflicting.merge_prs[1], 42, "the conflicting merge consumes the re-read PR")
    eq(count_gh("pr close"), 0, "the repair opens no second PR and closes none")
    eq(count_gh("pr create"), 0, "the repair reuses the open PR")
  end

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
  -- The runtime passes `push = false` for the epic turn and pushes the branch
  -- itself once the redo is verified: a prompt that still told the implementer
  -- to push could force origin/<branch> back onto the fresh base.
  eq(epic_conflict_prompt:find("Do not push", 1, true) ~= nil, true,
    "an epic repair turn tells the implementer not to push")
  eq(epic_conflict_prompt:find("Commit the reconciliation and leave the push to the runtime",
    1, true) ~= nil, true,
    "an epic repair turn says the runtime does the push")
  eq(epic_conflict_prompt:find("commit and push again", 1, true), nil,
    "an epic repair turn does not tell the implementer to push")
  eq(conflict_prompt:find("commit and push again", 1, true) ~= nil, true,
    "a subtask repair turn still tells the implementer to push")
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

local function case_prune(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
          FAILED = { id = "FAILED", status = "failed", branch = "metronome/failed" },
        } }
      end,
    },
    git = {
      list_open_prs = function(opts)
        prune_repo = opts and opts.repo
        return {
          { number = 10, head = "metronome/live", url = "u", title = "live" },
          { number = 11, head = "metronome/failed", url = "u", title = "failed" },
          { number = 12, head = "someone/else", url = "u", title = "not ours" },
        }
      end,
      list_branches = function(_, _, opts)
        eq(opts and opts.pattern, "metronome/*", "prune lists only task branches")
        return { "metronome/live", "metronome/failed", "metronome/orphan" }
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
  eq(#pruned.closed, 0, "prune never closes a failed or live task's PR")
  local kept_failed = nil
  for _, entry in ipairs(pruned.kept or {}) do
    if entry.task == "FAILED" then kept_failed = entry end
  end
  eq(type(kept_failed), "table", "a failed task is kept")
  eq(kept_failed and kept_failed.reason, "failed (retryable)",
    "a failed task is kept because it is retryable")
  eq(kept_failed and kept_failed.number, 11, "the failed task keeps its open PR")
  local deleted_branches = {}
  for _, entry in ipairs(pruned.deleted or {}) do
    deleted_branches[#deleted_branches + 1] = entry.branch
  end
  has(table.concat(deleted_branches, ","), "metronome/orphan", "a branch with no task is deleted")
  eq(table.concat(deleted_branches, ","):find("metronome/failed", 1, true), nil,
    "a failed task's branch is kept")
  eq(table.concat(deleted_branches, ","):find("metronome/live", 1, true), nil,
    "a live task's branch is kept")
  eq(table.concat(prune_closed, ","):find("11", 1, true), nil,
    "the failed task's PR is never closed")

  -- Stop and abandon prune the explicitly abandoned task's GitHub debris -----
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
  local stop_deleted = stopped.prune and stopped.prune.deleted and stopped.prune.deleted[1] or nil
  eq(type(stop_deleted), "table", "the stop prune reports structured deletions")
  eq(stop_deleted and stop_deleted.reason, "abandoned",
    "the stop prune names the task abandoned, not dead")

  local abandoned = rt12.abandon({ id = "ABANDONME" })
  eq(abandoned.ok, true, "abandon succeeds")
  eq(auto_tasks.ABANDONME.status, "abandoned", "abandon parks the task as abandoned")
  eq(abandoned.prune and abandoned.prune.ok, true, "abandon prunes automatically")
  has(table.concat(auto_closed, ","), "22", "abandon closes the orphan PR")
  has(table.concat(auto_deleted, ","), "metronome/abandonme", "abandon deletes the dead branch")
end

local function case_config_base(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
  -- config: a base branch that does not exist on origin is refused ----------
  local cfg_root = test_dir("runtime-config")
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
end

local function case_review_loop(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_rebase_push(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_rebase_conflict(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_second_conflict(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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

local function case_epic_subtask(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_epic_task(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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
end

local function case_epic_conflict(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx
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

  -- When `origin/<base>` cannot be resolved but the merge result already
  -- carried a usable `base_sha`, the repair still proceeds on that SHA instead
  -- of breaking to escalation on a base it could have reset onto.
  local epic_sha_fallback = epic_conflict_deps(2, 1, {
    shas = { ["origin/metronome/epic/demo-0001"] = "tip999" },
  })
  local rt_epic_sha_fallback = runtime.new(epic_sha_fallback.deps)
  rt_epic_sha_fallback.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_epic_sha_fallback.run_pending()
  eq(epic_sha_fallback.resets[1] and epic_sha_fallback.resets[1].sha, "base123",
    "an unresolvable origin/<base> falls back to the base SHA the merge carried")
  eq(epic_sha_fallback.impl_calls(), 1,
    "the repair turn runs when the base SHA comes from the merge result")
  eq(epic_sha_fallback.merge_calls(), 2, "the merge is retried after the fallback repair")
  eq(epic_sha_fallback.pr_opens(), 1, "the fallback repair reuses the single PR")
  eq(epic_sha_fallback.record.status, "deployed",
    "a repair on the carried base SHA does not escalate the epic")

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

local function case_failure_policy(env)
  local runtime, root, config, paths, deps, ctx =
    env.runtime, env.root, env.config, env.paths, env.deps, env.ctx


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
        if type(extra.fields) == "table" and extra.fields.slot_wait == false then
          record.slot_wait = nil
          record.slot_wait_since = nil
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
  local transient_meta = { impl = 0, closed = 0, deleted = 0 }
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
        transient_meta.impl = transient_meta.impl + 1
        return { ok = false, error = "fatal: unable to access 'https://github.com/x/y': could not resolve host: github.com" }
      end,
      read_sheet = function() return {} end,
    },
    checks = { verify = function() return { ok = true } end, write_report = function() end },
    converge = { run = function() return { ok = true } end },
    review = { review = function() return { ok = true, approved = true } end },
    git = {
      pr_open = function() return { number = 1, url = "u", state = "open" } end,
      pr_close = function()
        transient_meta.closed = transient_meta.closed + 1
        return { closed = true }
      end,
      delete_branch = function()
        transient_meta.deleted = transient_meta.deleted + 1
        return { ok = true }
      end,
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
  eq(transient_meta.impl, 1, "the failing task ran once")
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
  eq(transient_record.branch, "metronome/t1", "the failure keeps the branch for metronome_retry")
  eq(transient_meta.closed, 0, "the failure never closes the PR: metronome_retry resumes from it")
  eq(transient_meta.deleted, 0, "the failure never deletes the branch: metronome_retry resumes from it")
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
  eq(transient_meta.impl, 2, "the automatic retry re-dispatches the task")
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

  do
    -- A malformed review never fails the task ---------------------------------
    --
    -- review.lua replays an invalid answer once and, when it is still malformed,
    -- hands back cause = "review_invalid", transient = true. The runtime must
    -- propagate that contract and hold the task in `reviewing`: its code is
    -- committed, its checks are green, so no `failed` transition, no PR closed,
    -- and the branch, worktree, transcript and checkpoints stay resumable.
    local held_record = {
      id = "T1", status = "ready", title = "t", checks = { "true" },
      branch = "metronome/t1", worktree = "/tmp/wt-t1", run_dir = "/tmp/runs/T1",
      checkpoints = { "c1", "c2" },
      pr = { number = 54, url = "u", state = "open" },
    }
    local held_transitions = {}
    local held_state = mem_state(held_record)
    local held_transition = held_state.transition
    held_state.transition = function(state_root, id, status, extra)
      held_transitions[#held_transitions + 1] = status
      return held_transition(state_root, id, status, extra)
  end
  local function held_saw(wanted)
    for _, status in ipairs(held_transitions) do
      if status == wanted then
        return true
      end
    end
    return false
  end
  local held_pr_closed = 0
  local held_reviews = 0
  local held_retries = 0
  local held_invalid = {
    ok = false,
    cause = "review_invalid",
    transient = true,
    error = "review_invalid: finding 1: expected an object with severity and message",
    round = 1,
    sha = "abc",
  }
  local held_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = held_state,
    implement = {
      run = function()
        return { ok = true, ctx = { worktree = "/tmp/wt-t1", branch = "metronome/t1" }, sha = "abc" }
      end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = {
      loop = function()
        held_reviews = held_reviews + 1
        return held_invalid
      end,
    },
    git = {
      pr_open = function() return { number = 54, url = "u", state = "open" } end,
      pr_close = function()
        held_pr_closed = held_pr_closed + 1
        return { closed = true }
      end,
    },
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function(opts)
        if held_record.slot_wait or held_record.status == "ready" then
          held_record.slot_wait = nil
          held_record.status = "running"
          opts.dispatch({ id = "T1" })
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    defer = function()
      held_retries = held_retries + 1
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
  local rt_held = runtime.new(held_deps)
  rt_held.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_held.run_pending()
  eq(held_reviews, 1, "the review loop ran once for the malformed answer")
  eq(held_record.status, "reviewing", "an invalid review leaves the task in reviewing")
  eq(held_saw("failed"), false, "an invalid review emits no failed transition")
  eq(held_pr_closed, 0, "an invalid review does not close the PR")
  eq(held_record.pr and held_record.pr.state, "open", "the PR stays open")
  eq(held_record.branch, "metronome/t1", "an invalid review keeps the branch")
  eq(held_record.worktree, "/tmp/wt-t1", "an invalid review keeps the worktree")
  eq(held_record.run_dir, "/tmp/runs/T1", "an invalid review keeps the transcript")
  eq(#(held_record.checkpoints or {}), 2, "an invalid review keeps the checkpoints")
  eq(held_retries, 0, "no automatic retry is armed for a task that is not failed")
  eq(#notified, 0, "an invalid review does not wake a human")
  eq(type(held_record.failure), "table", "the invalid review is recorded, not lost")
  eq(held_record.failure and held_record.failure.cause, "review_invalid",
    "the recorded cause is typed review_invalid")
  eq(held_record.failure and held_record.failure.transient, true,
    "the recorded cause is transient")
  -- `set_fields` writes a raw `field` event that the journal replays verbatim,
  -- so every key of the persisted failure must belong to the schema's closed
  -- set (schemas/task.schema.json). A stray key such as `held` would poison the
  -- replayed projection and fail tools/validate-state.py.
  do
    local allowed = {
      cause = true, message = true, remedy = true, transient = true,
      attempts = true, at = true, next_retry_at = true, phase = true,
    }
    local stray = {}
    for key in pairs(held_record.failure or {}) do
      if not allowed[key] then
        stray[#stray + 1] = tostring(key)
      end
    end
    eq(#stray, 0, "the recorded failure stays inside the schema's closed key set: "
      .. table.concat(stray, ","))
  end
  local held_result = type(rt_held.last_background) == "table"
    and type(rt_held.last_background.results) == "table"
    and rt_held.last_background.results[1] or nil
  eq(held_result and held_result.cause, "review_invalid",
    "the drain result keeps the typed cause")
  eq(held_result and held_result.transient, true, "the drain result keeps transient")
  local held_retry = rt_held.retry({ id = "T1" }, { session = "S1" })
  eq(held_retry and held_retry.ok, false,
    "a task kept in reviewing is resumed from its checkpoint, not retried as failed")

  -- The resume path applies the same guard: a `/reload` walks the interrupted
  -- reviewing task back to running and re-dispatches it; a second invalid
  -- review holds it again instead of destroying it.
  held_deps.pipeline.resume = function()
    -- The runtime parks the selected entry with `slot_wait` and lets the drain
    -- dispatch it; the fake hands back the entry shaped like the scheduler's.
    return { ok = true, resumed = { { id = "T1", from = "reviewing" } }, errors = {} }
  end
  local held_resume = rt_held.resume({})
  eq(held_resume and held_resume.ok, true, "the resume accepts a reviewing task")
  rt_held.run_pending()
  eq(held_reviews, 2, "the resumed task went through the review again")
  eq(held_record.status, "reviewing", "the resume path holds the task in reviewing")
  eq(held_saw("failed"), false, "the resume path emits no failed transition either")
  eq(held_pr_closed, 0, "the resume path does not close the PR")
  eq(held_record.branch, "metronome/t1", "the resume path keeps the branch")
  eq(#(held_record.checkpoints or {}), 2, "the resume path keeps the checkpoints")
  eq(held_retries, 0, "the resume path arms no automatic retry")

  end

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
        if guard_record.status == "ready" or guard_record.slot_wait then
          guard_record.slot_wait = nil
          guard_record.slot_wait_since = nil
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
    -- `retry` only queues the task: the drain dispatches it, exactly like the
    -- real scheduler, so the stub plays `pipeline.tick` on the live projection
    -- and clears the wait when it dispatches.
    pipeline = {
      tick = function(opts)
        if retry_record.status == "ready" or retry_record.slot_wait then
          retry_record.slot_wait = nil
          retry_record.slot_wait_since = nil
          opts.dispatch({ id = "T1" })
          return { ok = true, started = { "T1" } }
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn) fn() end,
    defer = function() return {} end,
    wait_turn_end = false,
    runner = {},
    qualify = {}, questions = {}, analyze = transient_deps.analyze,
    calibrate = {}, fence = {}, mode = {},
  }
  notified = {}
  local rt_retry = runtime.new(retry_deps)
  local retried = rt_retry.retry({ id = "T1" }, { session = "S1" })
  eq(retried and retried.ok, true, "metronome_retry accepts a failed task")
  eq(retried and retried.requeued, true, "metronome_retry queues the task for the drain")
  rt_retry.run_pending()
  eq(retried_impl, 1, "metronome_retry re-dispatches the task from its checkpoint")
  eq(retry_record.status, "failed", "the retried task failed again")
  eq(retry_record.failure and retry_record.failure.attempts, 1,
    "a human retry resets the attempt budget")
  -- The dispatch is the drain's now, so its outcome lives in the drain's
  -- results rather than on the retry's own background record.
  eq(type(rt_retry.last_background) == "table"
    and type(rt_retry.last_background.results) == "table"
    and rt_retry.last_background.results[1]
    and rt_retry.last_background.results[1].failure
    and rt_retry.last_background.results[1].failure.cause or nil, "network",
    "the background record carries the typed failure, not only the raw error")
  eq(type(rt_retry.last_background) == "table"
    and type(rt_retry.last_background.results) == "table"
    and rt_retry.last_background.results[1]
    and rt_retry.last_background.results[1].decision
    and rt_retry.last_background.results[1].decision.action or nil, "auto_retry",
    "the background record carries the resume decision")
  eq(type(rt_retry.last_background) == "table"
    and type(rt_retry.last_background.results) == "table"
    and rt_retry.last_background.results[1]
    and rt_retry.last_background.results[1].retrying or nil, true,
    "the background record says the task is being retried")
  eq(type(type(rt_retry.last_background) == "table"
    and rt_retry.last_background.results
    and rt_retry.last_background.results[1]
    and rt_retry.last_background.results[1].error), "string",
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
    -- The retry only queues the task: the drain dispatches. The stub plays one
    -- tick that starts the parked task, then reports an empty queue.
    pipeline = {
      tick = function(opts)
        async_ticks = async_ticks + 1
        if async_record.status == "ready" or async_record.slot_wait then
          -- The dispatch is queued, so the projection must move now or the next
          -- tick would spawn the same task again.
          async_record.slot_wait = nil
          async_record.slot_wait_since = nil
          async_record.status = "running"
          opts.dispatch({ id = "T1" })
          return { ok = true, started = { "T1" } }
        end
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

  -- The review budget on relaunch is checked in its own function: the outer
  -- case already holds too many locals for Lua 5.1 to accept them inline.
  local function check_review_budget()
    -- A review escalation gets its review budget back on relaunch --------------
    --
    -- Reproduction T-20261122-0043: the task failed at review.round = 3 with
    -- review.max_rounds = 3. `metronome_retry` moved it back to `running` but kept
    -- the counter, so the first review of the new attempt computed round 4 and
    -- escalated with no review at all. The relaunch must reset the counter to 0,
    -- keep the findings as the implementer's feedback, journal the reset, and let
    -- the new attempt run a real review round.
    local escalated_findings = {
      { severity = "blocking", message = "no test covers the change", path = "src/a.lua", line = 2, rule = "tests" },
    }
    local escalated_record = {
      id = "T1", status = "failed", title = "t", checks = { "true" },
      branch = "metronome/t1", worktree = "/tmp/wt-t1",
      review = { round = 3, max_rounds = 3, commit_sha = "abcdef1234567", findings = escalated_findings },
      failure = { cause = "review_escalated", message = "review escalated after 3 rounds",
        remedy = "relaunch", transient = false, attempts = 3, phase = "review" },
      failure_reason = "review escalated after 3 rounds: human review required (see note)",
    }
    local escalated_state = mem_state(escalated_record)
    local escalated_events = {}
    local escalated_fields = {}
    local escalated_steps = {}
    local escalated_set_fields = escalated_state.set_fields
    local escalated_transition = escalated_state.transition
    escalated_state.set_fields = function(root, id, fields)
      escalated_fields[#escalated_fields + 1] = fields
      if type(fields.review) == "table" then
        escalated_steps[#escalated_steps + 1] = "fields:review"
      end
      return escalated_set_fields(root, id, fields)
    end
    escalated_state.transition = function(root, id, status, extra)
      escalated_steps[#escalated_steps + 1] = "status:" .. tostring(status)
      return escalated_transition(root, id, status, extra)
    end
    escalated_state.append = function(_, event)
      escalated_steps[#escalated_steps + 1] = "event:" .. tostring(event.kind)
      escalated_events[#escalated_events + 1] = event
      -- A real `append` is the journal: apply the batched events the way the
      -- replay would, so a `slot_wait` field written this way is observable.
      local batch = type(event) == "table" and event[1] ~= nil and event or { event }
      for _, one in ipairs(batch) do
        if one.kind == "field" and type(one.fields) == "table" then
          for key, value in pairs(one.fields) do
            escalated_record[key] = value
          end
        end
      end
      return true
    end
    local escalated_feedback = nil
    local escalated_round_at_review = nil
    local escalated_deps = {
      config = transient_deps.config,
      roles = transient_deps.roles,
      recover = recover_mod,
      state = escalated_state,
      implement = {
        run = function(run_opts)
          escalated_feedback = run_opts.feedback
          return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abcdef1234567" }
        end,
        read_sheet = function() return {} end,
      },
      checks = { verify = function() return { ok = true } end, write_report = function() end },
      converge = { run = function() return { ok = true } end },
      review = {
        review = function(review_opts)
          escalated_round_at_review = escalated_record.review and escalated_record.review.round
          return {
            ok = true,
            approved = true,
            round = (escalated_round_at_review or 0) + 1,
            sha = "abcdef1234567",
          }
        end,
      },
      git = {
        pr_open = function() return { number = 1, url = "u", state = "open" } end,
        pr_attach = function() end,
      },
      merge = { run = function() return { ok = true } end },
      deploy = { run = function() return { ok = true, deployed = true } end },
      -- The drain is the only dispatch authority: a retry parks the task with
      -- `slot_wait` and the tick moves it back to `running` before spawning it.
      pipeline = {
        tick = function(tick_opts)
          if escalated_record.slot_wait then
            escalated_record.slot_wait = nil
            escalated_steps[#escalated_steps + 1] = "status:running"
            escalated_record.status = "running"
            if type(tick_opts.dispatch) == "function" then
              tick_opts.dispatch({ id = "T1" })
            end
            return { ok = true, started = { "T1" } }
          end
          return { ok = true, started = {} }
        end,
      },
      paths = transient_deps.paths,
      spawn = function(fn) fn() end,
      defer = function() return {} end,
      wait_turn_end = false,
      runner = {},
      qualify = {}, questions = {}, analyze = {},
      calibrate = {}, fence = {}, mode = {},
    }
    notified = {}
    local rt_escalated = runtime.new(escalated_deps)
    local relaunched = rt_escalated.retry({ id = "T1" }, { session = "S1" })

    eq(relaunched and relaunched.ok, true, "a review-escalated task can be relaunched")
    eq(relaunched and relaunched.requeued, true,
      "the relaunch hands the task to the drain instead of starting it itself")    eq(escalated_record.review and escalated_record.review.round, 0,
      "the relaunch resets the review round to 0")
    eq(escalated_record.review and escalated_record.review.max_rounds, 3,
      "the relaunch keeps the configured review budget")
    eq(type(escalated_record.review and escalated_record.review.findings), "table",
      "the last round's findings are still stored")
    -- The reset belongs to the same gesture as the move back to `running`, and
    -- must land before it: the relaunched review then computes round 1.
    local reset_at, running_at
    for i, step in ipairs(escalated_steps) do
      if step == "fields:review" and reset_at == nil then
        reset_at = i
      end
      if step == "status:running" and running_at == nil then
        running_at = i
      end
    end
    eq(type(reset_at), "number", "the reset writes a review field patch")
    eq(type(running_at), "number", "the drain moves the task back to running")
    eq(reset_at and running_at and reset_at < running_at, true,
      "the reset lands before the task crosses to running")
    local reset_field, reset_note = nil, nil
    for _, fields in ipairs(escalated_fields) do
      if type(fields.review) == "table" then
        reset_field = fields
      end
    end
    for _, event in ipairs(escalated_events) do
      if event.kind == "note" and tostring(event.text or ""):find("review.round", 1, true) then
        reset_note = event.text
      end
    end
    eq(type(reset_field), "table", "the reset is journaled as a field patch on review")
    eq(reset_field and reset_field.review and reset_field.review.round, 0,
      "the field patch carries the reset round")
    eq(type(reset_note), "string", "the reset is journaled as a note")
    has(reset_note or "", "review.round 3 -> 0", "the note names the old round")
    has(reset_note or "", "budget 3", "the note names the granted budget")
    rt_escalated.run_pending()
    eq(type(escalated_feedback), "table", "the implementer receives feedback on the relaunch")
    eq(escalated_feedback and escalated_feedback[1] and escalated_feedback[1].message,
      "no test covers the change", "the feedback is the escalated round's findings")
    eq(escalated_round_at_review, 0, "the review is dispatched with a reset round")
    eq(escalated_record.status ~= "failed", true,
      "the relaunched review does not escalate empty: status is " .. tostring(escalated_record.status))
    local escalated_notes = {}
    for _, event in ipairs(escalated_events) do
      escalated_notes[#escalated_notes + 1] = tostring(event.text or "")
    end
    has(table.concat(escalated_notes, "\n"), "review.round 3 -> 0",
      "the relaunch journal keeps the reset note")

    -- A retry for another cause leaves the review counter alone ----------------
    local untouched_record = {
      id = "T1", status = "failed", title = "t", checks = { "true" },
      branch = "metronome/t1", worktree = "/tmp/wt-t1",
      review = { round = 1, max_rounds = 3, commit_sha = "abcdef1234567" },
      failure = { cause = "network", message = "boom", remedy = "retry", transient = true,
        attempts = 3, phase = "implement" },
    }
    local untouched_deps = {
      config = transient_deps.config,
      roles = transient_deps.roles,
      recover = recover_mod,
      state = mem_state(untouched_record),
      implement = {
        run = function()
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
    local rt_untouched = runtime.new(untouched_deps)
    eq(type(rt_untouched.retry({ id = "T1" }, { session = "S1" })), "table",
      "a non-review retry is accepted")
    eq(untouched_record.review and untouched_record.review.round, 1,
      "a retry for another cause does not touch the review counter")

    -- A `/reload` relaunch grants the same budget ------------------------------
    -- pipeline.resume used to skip every failed task it could not retry
    -- automatically, which silently dropped a review-escalated task. It now
    -- admits it and applies the same reset before the task crosses to `running`.
    local pipeline = load_module("pipeline")
    local resume_record = {
      id = "T9", status = "failed", title = "t", checks = { "true" },
      branch = "metronome/t9", worktree = "/tmp/wt-t9",
      review = { round = 3, max_rounds = 3, commit_sha = "abcdef1" },
      failure = { cause = "review_escalated", message = "review escalated after 3 rounds",
        transient = false, attempts = 1, phase = "review" },
    }
    local resume_state = mem_state(resume_record)
    local resume_events = {}
    resume_state.append = function(_, event)
      resume_events[#resume_events + 1] = event
      return true
    end
    local dispatched = {}
    local resumed_result = pipeline.resume(resume_state, "/tmp/nowhere", {
      apply = true,
      recover = recover_mod,
      max_attempts = 3,
      dispatch = function(task) dispatched[#dispatched + 1] = task end,
    })
    eq(type(resumed_result), "table", "the resume reports its work")
    eq(#(resumed_result and resumed_result.resumed or {}), 1,
      "a review-escalated task is no longer skipped by the resume")
    eq(resume_record.status, "running", "the resume moves the task back to running")
    eq(resume_record.review and resume_record.review.round, 0,
      "the resume resets the review round budget")
    local resume_note = nil
    for _, event in ipairs(resume_events) do
      if event.kind == "note" then
        resume_note = event.text
      end
    end
    has(tostring(resume_note), "review.round 3 -> 0", "the resume journals the reset")
    has(tostring(resume_note), "budget 3", "the resume note names the granted budget")
    eq(#dispatched, 1, "the resumed task is dispatched from its checkpoint")
  end
  check_review_budget()

  local function check_quarantine_drain()
  -- A blocked task never stops the drain -------------------------------------
  -- One blocking finding must only quarantine its own task: the independent
  -- ready task is dispatched in the same pass, no task is marked `failed`, and
  -- the result names the quarantine it left behind so a freeze is not silent.
  local q_blocked = {
    id = "T-blocked", status = "qualifying", title = "blocked", checks = { "true" },
    quarantine = {
      reason = "analysis_blocked",
      rules = { "missing_dependency", "gate_cycle" },
      findings = { { severity = "blocking", rule = "missing_dependency", message = "missing dep" } },
      since = 1,
    },
  }
  local q_ready = {
    id = "T-ready", status = "ready", title = "ready", checks = { "true" },
    branch = "metronome/t-ready", worktree = "/tmp/wt-ready",
  }
  local q_transitions = {}
  local q_queue = {}
  local q_ready_dispatched = false
  local q_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = {
      load = function()
        return { tasks = { ["T-blocked"] = q_blocked, ["T-ready"] = q_ready } }
      end,
      transition = function(_, id, status)
        q_transitions[#q_transitions + 1] = { id = id, status = status }
        if id == "T-blocked" then q_blocked.status = status end
        if id == "T-ready" then q_ready.status = status end
        return { id = id, status = status }
      end,
      set_fields = function(_, id, fields)
        local rec = id == "T-blocked" and q_blocked or q_ready
        for key, value in pairs(fields or {}) do rec[key] = value end
        return rec
      end,
      clear_quarantine = function(_, id)
        if id == "T-blocked" then q_blocked.quarantine = nil end
        if id == "T-ready" then q_ready.quarantine = nil end
        return q_blocked
      end,
    },
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
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
        if q_ready.status == "ready" and not q_ready_dispatched then
          q_ready_dispatched = true
          q_ready.status = "running"
          opts.dispatch({ id = "T-ready" })
          return { ok = true, started = { "T-ready" } }
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn)
      q_queue[#q_queue + 1] = fn
      return { cancel = function() end }
    end,
    async = true,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = {
      gate = function()
        return {
          ok = true,
          verdict = "blocked",
          findings = { { severity = "blocking", rule = "missing_dependency",
            message = "missing dep", tasks = { "T-blocked" } } },
          quarantined = { "T-blocked" },
          blocked = { ["T-blocked"] = { reason = "analysis_blocked",
            rules = { "missing_dependency", "gate_cycle" } } },
        }
      end,
    },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_q = runtime.new(q_deps)
  rt_q.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_q.run_pending()
  local q_bg = rt_q.last_background
  eq(q_bg and q_bg.ok, true, "a quarantined task does not fail the drain")
  eq(q_bg and q_bg.background, true, "the async drain still reports background")
  eq(q_ready_dispatched, true, "an independent ready task is still dispatched")
  eq(#q_queue >= 1, true, "the dispatched ready task owns a spawn")
  eq(q_blocked.status, "qualifying", "the blocked task stays qualifying")
  local q_failed = false
  for _, moved in ipairs(q_transitions) do
    if moved.status == "failed" then q_failed = true end
  end
  eq(q_failed, false, "no task is marked failed for a blocking finding")
  local q_named = false
  for _, id in ipairs(q_bg and q_bg.quarantined or {}) do
    if id == "T-blocked" then q_named = true end
  end
  eq(q_named, true, "the result names the quarantined task")
  eq(type(q_bg and q_bg.findings), "table", "the result carries the findings")
  -- The quarantine is logged with its rules: a freeze must never be silent.
  local q_log = maki.fs.read(maki.fs.joinpath(root, "runtime.log")) or ""
  has(q_log, "T-blocked", "the quarantine log names the task")
  has(q_log, "missing_dependency", "the quarantine log names the rule")

  -- A gate that raises still quarantines and drains --------------------------
  -- An analysis-gate error must not stop the queue: the task it names is
  -- quarantined, the independent task is dispatched, and the failure is logged.
  local e_blocked = {
    id = "T-blocked", status = "qualifying", title = "blocked", checks = { "true" },
  }
  local e_ready = {
    id = "T-ready", status = "ready", title = "ready", checks = { "true" },
    branch = "metronome/t-ready", worktree = "/tmp/wt-ready",
  }
  local e_queue = {}
  local e_ready_dispatched = false
  local e_failed = false
  local e_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = {
      load = function()
        return { tasks = { ["T-blocked"] = e_blocked, ["T-ready"] = e_ready } }
      end,
      transition = function(_, id, status)
        if status == "failed" then e_failed = true end
        if id == "T-blocked" then e_blocked.status = status end
        if id == "T-ready" then e_ready.status = status end
        return { id = id, status = status }
      end,
      set_fields = function(_, id, fields)
        local rec = id == "T-blocked" and e_blocked or e_ready
        for key, value in pairs(fields or {}) do rec[key] = value end
        return rec
      end,
      clear_quarantine = function(_, id)
        return id == "T-blocked" and e_blocked or e_ready
      end,
    },
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
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
        if e_ready.status == "ready" and not e_ready_dispatched then
          e_ready_dispatched = true
          e_ready.status = "running"
          opts.dispatch({ id = "T-ready" })
          return { ok = true, started = { "T-ready" } }
        end
        return { ok = true, started = {} }
      end,
    },
    paths = transient_deps.paths,
    spawn = function(fn)
      e_queue[#e_queue + 1] = fn
      return { cancel = function() end }
    end,
    async = true,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = {
      gate = function()
        error("cannot analyse T-blocked: the sheet is unreadable")
      end,
    },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_e = runtime.new(e_deps)
  rt_e.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_e.run_pending()
  local e_bg = rt_e.last_background
  eq(e_bg and e_bg.ok, true, "a gate error does not fail the drain")
  eq(e_ready_dispatched, true, "the drain still dispatches after a gate error")
  eq(e_failed, false, "a gate error never marks a task failed")
  eq(type(e_blocked.quarantine), "table", "the named task is quarantined on a gate error")
  eq(e_blocked.quarantine and e_blocked.quarantine.reason, "analysis_gate_error",
    "the quarantine names the gate error")
  eq(e_blocked.quarantine and e_blocked.quarantine.rules and e_blocked.quarantine.rules[1],
    "analysis_gate_error", "the quarantine carries its rule")
  local e_named = false
  for _, id in ipairs(e_bg and e_bg.quarantined or {}) do
    if id == "T-blocked" then e_named = true end
  end
  eq(e_named, true, "the gate-error result names the quarantined task")
  local e_log = maki.fs.read(maki.fs.joinpath(root, "runtime.log")) or ""
  has(e_log, "analysis gate failed", "the gate error is logged")
  has(e_log, "T-blocked", "the gate-error log names the quarantined task")
  has(e_log, "analysis_gate_error", "the gate-error log names the quarantine rule")

  -- A quarantined task is re-analysed without a new submit --------------------
  -- Once the queue has drained nothing dirties the scheduler, so a pass that
  -- leaves a task quarantined arms one more pass with a bounded backoff. When
  -- the sheet is repaired, that pass finds it clean and leaves quarantine.
  local r_blocked = {
    id = "T-blocked", status = "qualifying", title = "blocked", checks = { "true" },
  }
  local r_deferred = {}
  local r_gate_calls = 0
  local r_fixed = false
  local r_deps = {
    config = transient_deps.config,
    roles = transient_deps.roles,
    recover = recover_mod,
    state = {
      load = function()
        if r_fixed then r_blocked.quarantine = nil end
        return { tasks = { ["T-blocked"] = r_blocked } }
      end,
      transition = function(_, id, status)
        if id == "T-blocked" then r_blocked.status = status end
        return { id = id, status = status }
      end,
      set_fields = function(_, id, fields)
        for key, value in pairs(fields or {}) do r_blocked[key] = value end
        return r_blocked
      end,
      clear_quarantine = function(_, id)
        if id == "T-blocked" then r_blocked.quarantine = nil end
        return r_blocked
      end,
    },
    implement = {
      run = function() return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" } end,
      read_sheet = function() return {} end,
    },
    checks = transient_deps.checks,
    converge = transient_deps.converge,
    review = transient_deps.review,
    git = transient_deps.git,
    merge = transient_deps.merge,
    deploy = transient_deps.deploy,
    pipeline = {
      tick = function() return { ok = true, started = {} } end,
    },
    paths = transient_deps.paths,
    spawn = function() return { cancel = function() end } end,
    async = true,
    defer = function(fn, ms)
      r_deferred[#r_deferred + 1] = { fn = fn, ms = ms }
      return { cancel = function() end }
    end,
    wait_turn_end = false,
    runner = {},
    qualify = transient_deps.qualify,
    questions = transient_deps.questions,
    analyze = {
      gate = function()
        r_gate_calls = r_gate_calls + 1
        if r_fixed then
          r_blocked.quarantine = nil
          return { ok = true, verdict = "pass", findings = {}, quarantined = {}, blocked = {} }
        end
        r_blocked.quarantine = {
          reason = "analysis_blocked",
          rules = { "missing_dependency" },
          findings = { { severity = "blocking", rule = "missing_dependency", message = "missing dep" } },
          since = 1,
        }
        return {
          ok = true,
          verdict = "blocked",
          findings = { { severity = "blocking", rule = "missing_dependency",
            message = "missing dep", tasks = { "T-blocked" } } },
          quarantined = { "T-blocked" },
          blocked = { ["T-blocked"] = { reason = "analysis_blocked",
            rules = { "missing_dependency" } } },
        }
      end,
    },
    calibrate = {}, fence = {}, mode = {},
  }
  local rt_r = runtime.new(r_deps)
  rt_r.submit({ intention = "x", fast = false }, { session = "S1" })
  rt_r.run_pending()
  eq(r_gate_calls, 1, "the first pass runs the analysis gate")
  eq(type(r_blocked.quarantine), "table", "the blocked task is quarantined")
  eq(#r_deferred, 1, "a still-quarantined queue arms one more re-analysis pass")
  eq((r_deferred[1] and r_deferred[1].ms) and r_deferred[1].ms > 0, true,
    "the re-analysis pass is delayed, not a spin")
  -- The user repairs the sheet: the next pass finds it clean, no new submit.
  r_fixed = true
  r_deferred[1].fn()
  eq(r_gate_calls, 2, "the armed pass re-runs the analysis gate")
  eq(r_blocked.quarantine, nil, "a clean pass leaves quarantine without a new submit")
  eq(#r_deferred, 1, "a clean queue arms no further pass")
  end
  check_quarantine_drain()


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
    review = { round = 0, max_rounds = 3, commit_sha = "abcdef1" },
    failure = { cause = "git_identity", message = "empty ident name",
      remedy = "set git user.email and user.name", transient = true,
      attempts = 2, at = 10, next_retry_at = 70 },
  }
  local escalated_status_record = {
    id = "T3", status = "failed", title = "escalated",
    branch = "metronome/t3", worktree = "/tmp/wt-t3",
    review = { round = 3, max_rounds = 3, commit_sha = "abcdef1",
      findings = { { severity = "blocking", message = "still broken" } } },
    failure = { cause = "review_escalated", message = "review escalated after 3 rounds",
      remedy = "relaunch", transient = false, attempts = 1, phase = "review" },
  }
  local legacy_record = {
    id = "T2", status = "failed", title = "old journal",
    failure_reason = "git commit exit 1: Sur la branche main",
  }
  local quarantined_record = {
    id = "T3", status = "qualifying", title = "set aside",
    quarantine = {
      reason = "analysis_blocked",
      rules = { "missing_dependency", "gate_cycle" },
      findings = { { severity = "blocking", rule = "missing_dependency", message = "m" } },
      since = 1,
    },
  }
  local status_deps = {
    config = { load = function() return { project = { repo = "/tmp/repo" } } end },
    recover = recover_mod,
    state = {
      load = function()
        return { tasks = { T1 = status_record, T2 = legacy_record, T3 = escalated_status_record, T4 = quarantined_record } }
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
  -- The review budget is visible: a relaunched task shows its full budget, an
  -- escalated one shows nothing remaining, and the raw review object is intact.
  eq(view and view.review_round, 0, "status exposes the current review round")
  eq(view and view.review_max_rounds, 3, "status exposes the review budget")
  eq(view and view.review_rounds_remaining, 3, "a reset task shows its full review budget")
  local escalated_view = listed.tasks and listed.tasks.T3
  eq(escalated_view and escalated_view.review_rounds_remaining, 0,
    "an escalated task shows no review round remaining")
  eq(escalated_view and escalated_view.review and escalated_view.review.round, 3,
    "the raw review object stays untouched")
  local legacy_view = listed.tasks and listed.tasks.T2
  eq(legacy_view and legacy_view.last_error ~= nil, true,
    "a legacy failure_reason still reads as a typed last error")
  eq(legacy_view and legacy_view.retry_action and legacy_view.retry_action.action, "manual",
    "a legacy failure is a manual resume")
  -- The quarantine summary: sorted by id, reasons are the named rules, sorted,
  -- while the per-task view keeps the raw quarantine object.
  eq(type(listed.quarantined), "table", "status exposes a top-level quarantine summary")
  eq(#listed.quarantined, 1, "only the quarantined task is summarised")
  local summary = listed.quarantined[1]
  eq(summary and summary.id, "T4", "the summary names the quarantined task")
  eq(summary and summary.reasons and summary.reasons[1], "gate_cycle",
    "the summary reasons are the named rules, sorted")
  eq(summary and summary.reasons and summary.reasons[2], "missing_dependency",
    "every named rule is listed")
  eq(listed.tasks and listed.tasks.T4 and listed.tasks.T4.quarantine
    and listed.tasks.T4.quarantine.reason, "analysis_blocked",
    "the per-task view still carries the raw quarantine")
  eq(view and view.quarantine, nil, "a clean task carries no quarantine")
  local detailed = rt_status.status({ id = "T1" })
  eq(detailed and detailed.task and detailed.task.checkpoint, "def456",
    "the by-id detail exposes the checkpoint too")
  eq(detailed and detailed.task and detailed.task.retry_action
    and detailed.task.retry_action.action, "auto_retry",
    "the by-id detail exposes the resume action too")
  eq(detailed and detailed.task and detailed.task.review_rounds_remaining, 3,
    "the by-id detail exposes the review budget too")
  end
  check_status_view()

  maki.session.notify = saved_notify
  maki.session.prompt = saved_prompt

end

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
  local captured_answer
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
      answer = function(_, _, answers, opts)
        captured_answer = { answers = answers, opts = opts }
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
  eq(captured_answer and captured_answer.opts and captured_answer.opts.tasks_dir, paths.tasks,
    "answer hands questions.answer the project tasks directory")
  eq(captured_answer and captured_answer.opts and captured_answer.opts.qualify, deps.qualify,
    "answer hands questions.answer the qualify module")

  -- A sheet rewrite failure fails metronome_answer --------------------------

  local real_answer = deps.questions.answer
  deps.questions.answer = function()
    return nil, "cannot write sheet for T-20261114-0001: read-only file system"
  end
  local failed_answer = rt.answer({ answers = { q1 = "yes" } }, ctx)
  eq(failed_answer and failed_answer.ok, false, "a sheet write failure fails the answer")
  eq(failed_answer and failed_answer.error,
    "cannot write sheet for T-20261114-0001: read-only file system",
    "the answer error names the task whose sheet failed")
  deps.questions.answer = real_answer


  -- The fixtures the case functions read. Passing them explicitly keeps this
  -- function well under the Lua 5.1 limit of 200 locals.
  local env = {
    runtime = runtime, root = root, config = config, paths = paths,
    deps = deps, ctx = ctx,
  }

  case_qualify_remap(env)
  case_qualify_positions(env)
  case_qualify_t_form(env)
  case_retry_dispatch(env)
  case_background_ctx(env)
  case_auto_deploy(env)
  case_parallelism(env)
  case_stop_and_delete(env)
  case_resume(env)
  case_merge_conflict(env)
  case_conflict_repair(env)
  case_prune(env)
  case_config_base(env)
  case_review_loop(env)
  case_rebase_push(env)
  case_rebase_conflict(env)
  case_second_conflict(env)
  case_epic_subtask(env)
  case_epic_task(env)
  case_epic_conflict(env)
  case_failure_policy(env)

  -- status: the named skip reason of the scheduler is exposed ----------------
  --
  -- A ready task is not necessarily dispatchable: an unknown dependency or a
  -- dependency still in draft keeps it out of the queue forever. `status` used
  -- to return the raw tasks, so such a task looked ready and nothing said why
  -- it never started.
  local status_root = mktmpdir("metronome-runtime-status")
  local status_paths = {
    repo = "/tmp/repo",
    root = status_root,
    config = maki.fs.joinpath(status_root, "config.toml"),
    -- The status view derives the worktree it would use for a task, so the
    -- fixture must carry the directory the real paths table always has.
    worktrees = maki.fs.joinpath(status_root, "worktrees"),
    runs = maki.fs.joinpath(status_root, "runs"),
  }
  local status_tasks = {
    T1 = { id = "T1", title = "ghost", status = "ready", files = { "a" },
      depends_on = { "T-nope" } },
    T2 = { id = "T2", title = "drafty", status = "ready", files = { "b" },
      depends_on = { "T3" } },
    T3 = { id = "T3", title = "draft dep", status = "draft", files = { "c" } },
    T4 = { id = "T4", title = "free", status = "ready", files = { "d" } },
  }
  local status_rt = runtime.new({
    config = {
      load = function()
        return { project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 2 } }
      end,
    },
    state = {
      load = function() return { tasks = status_tasks, events = {} } end,
    },
    pipeline = load_module("pipeline"),
    paths = function() return status_paths end,
    roles = {}, runner = {}, git = {}, qualify = {}, questions = {},
    analyze = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {}, implement = {},
  })
  local status_result = status_rt.status({})
  eq(status_result.ok, true, "status reads the state")
  eq(#status_result.waiting, 2, "the two blocked ready tasks are named")
  eq(status_result.waiting[1].id, "T1", "waiting is sorted by id (1)")
  eq(status_result.waiting[1].reason:find("missing dependency: T-nope", 1, true) ~= nil, true,
    "the missing dependency is named")
  eq(status_result.waiting[2].id, "T2", "waiting is sorted by id (2)")
  eq(status_result.waiting[2].reason:find("waiting on T3 (draft)", 1, true) ~= nil, true,
    "the draft dependency is named")
  eq(status_result.tasks.T1.waiting_reason:find("missing dependency", 1, true) ~= nil, true,
    "the blocked task carries its reason")
  eq(status_result.tasks.T2.waiting_reason:find("waiting on T3", 1, true) ~= nil, true,
    "the waiting task carries its reason")
  eq(status_result.tasks.T4.waiting_reason, nil, "a dispatchable task carries no reason")

  -- A config that cannot be read must not fail status: the scheduler default
  -- applies and the reasons still come out.
  local broken_rt = runtime.new({
    config = {
      load = function()
        error("unreadable config")
      end,
    },
    state = {
      load = function() return { tasks = status_tasks, events = {} } end,
    },
    pipeline = load_module("pipeline"),
    paths = function() return status_paths end,
    roles = {}, runner = {}, git = {}, qualify = {}, questions = {},
    analyze = {}, checks = {}, converge = {}, review = {}, merge = {},
    deploy = {}, calibrate = {}, fence = {}, mode = {}, implement = {},
  })
  local broken_result = broken_rt.status({})
  eq(broken_result.ok, true, "an invalid config does not fail status")
  eq(#broken_result.waiting, 2, "the reasons still come out without a config")

end
