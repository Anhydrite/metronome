-- Tests for maki/lua/metronome/pipeline.lua (REQ-20261114-39).
--
-- The scheduler is pure: dependencies, file overlap, max_parallel, stall
-- detection and resume are decisions over the projection. The integration
-- cases use the real state module on a throwaway root, so a resume is proven
-- to walk only legal transitions.

return function()
  local pipeline = load_module("pipeline")
  local state = load_module("state")

  local function tmp_root(label)
    local base = maki.env.state_dir()
    local root = maki.fs.joinpath(base, "metronome-tests", label)
    local entries = maki.fs.dir(root)
    if entries then
      for _, e in ipairs(entries) do
        maki.fs.rm(maki.fs.joinpath(root, e[1]), { recursive = true })
      end
    end
    maki.fs.mkdir(root, { parents = true })
    return root
  end

  local function task(id, status, extra)
    local t = { id = id, title = id, status = status }
    for k, v in pairs(extra or {}) do
      t[k] = v
    end
    return t
  end

  -- parse_iso --------------------------------------------------------------

  local t0 = pipeline.parse_iso("2026-01-01T00:00:00Z")
  local t1 = pipeline.parse_iso("2026-01-01T00:01:00Z")
  eq(type(t0), "number", "parse_iso returns an epoch")
  eq(t1 - t0, 60, "parse_iso reads minutes")
  eq(pipeline.parse_iso("not a date"), nil, "parse_iso refuses a bad timestamp")
  eq(pipeline.parse_iso(nil), nil, "parse_iso refuses nil")

  -- collect ----------------------------------------------------------------

  local map = {
    ["T-b"] = task("T-b", "ready"),
    ["T-a"] = task("T-a", "ready"),
  }
  local collected = pipeline.collect(map)
  eq(#collected, 2, "collect reads a map")
  eq(collected[1].id, "T-a", "collect sorts map keys")
  eq(#pipeline.collect({ task("T-1", "ready") }), 1, "collect reads an array")
  eq(#pipeline.collect({ { title = "no id" } }), 0, "collect drops an entry without an id")

  -- dependencies -----------------------------------------------------------

  local merged = task("T-dep", "merged")
  local ready_dep = task("T-dep", "ready")
  local failed_dep = task("T-dep", "failed")
  local dependent = task("T-child", "ready", { depends_on = { "T-dep" } })

  eq(pipeline.dependencies_met(task("T-1", "ready"), {}), true, "a task without dependencies is free")
  eq(pipeline.dependencies_met(dependent, { merged }), true, "a merged dependency is met")
  eq(pipeline.dependencies_met(dependent, { task("T-dep", "deployed") }), true, "a deployed dependency is met")

  local met, reason = pipeline.dependencies_met(dependent, { ready_dep })
  eq(met, false, "a ready dependency is not met")
  eq(reason:find("waiting on", 1, true) ~= nil, true, "the reason says it is waiting")

  met, reason = pipeline.dependencies_met(dependent, { failed_dep })
  eq(met, false, "a failed dependency is not met")
  eq(reason:find("blocked by", 1, true) ~= nil, true, "the reason says it is blocked")

  met, reason = pipeline.dependencies_met(dependent, {})
  eq(met, false, "a missing dependency is not met")
  eq(reason:find("missing dependency", 1, true) ~= nil, true, "the reason names the missing dependency")

  -- file overlap -----------------------------------------------------------

  local a = task("T-a", "ready", { files = { "src/a.lua", "README.md" } })
  local b = task("T-b", "ready", { files = { "src/b.lua" } })
  local c = task("T-c", "ready", { files = { "README.md" } })
  eq(pipeline.overlaps(a, b), false, "disjoint files do not overlap")
  eq(pipeline.overlaps(a, c), true, "a shared file overlaps")
  eq(pipeline.overlaps(a, task("T-x", "ready")), false, "an undeclared file set does not overlap")

  -- schedule: max_parallel -------------------------------------------------

  local tasks = {
    task("T-1", "ready", { files = { "src/1" } }),
    task("T-2", "ready", { files = { "src/2" } }),
    task("T-3", "ready", { files = { "src/3" } }),
  }
  local started, skipped = pipeline.schedule(tasks, {}, { max_parallel = 2 })
  eq(#started, 2, "max_parallel caps the selection")
  eq(started[1].id, "T-1", "the first task starts")
  eq(started[2].id, "T-2", "the second task starts")
  eq(#skipped, 1, "the third task is skipped")
  eq(skipped[1].id, "T-3", "the skipped task is named")
  eq(skipped[1].reason:find("max_parallel", 1, true) ~= nil, true, "the skip reason is max_parallel")

  -- schedule: file overlap with a running task -----------------------------

  local running = { task("T-run", "running", { files = { "src/1" } }) }
  started, skipped = pipeline.schedule(tasks, running, { max_parallel = 3 })
  eq(#started, 2, "a running task leaves two slots")
  eq(started[1].id, "T-2", "the overlapping task is not started")
  eq(started[2].id, "T-3", "the disjoint task starts")
  local overlap_reason
  for _, item in ipairs(skipped) do
    if item.id == "T-1" then
      overlap_reason = item.reason
    end
  end
  eq(type(overlap_reason), "string", "the overlapping task is skipped")
  eq(overlap_reason:find("files overlap", 1, true) ~= nil, true, "the skip reason is file overlap")

  -- schedule: dependencies -------------------------------------------------

  local dep_tasks = {
    task("T-a", "ready", { files = { "src/a" } }),
    task("T-b", "ready", { files = { "src/b" }, depends_on = { "T-a" } }),
  }
  started, skipped = pipeline.schedule(dep_tasks, {}, { max_parallel = 2 })
  eq(#started, 1, "a dependent task waits")
  eq(started[1].id, "T-a", "the dependency starts")
  eq(skipped[1].id, "T-b", "the dependent task is skipped")
  eq(skipped[1].reason:find("waiting on T-a", 1, true) ~= nil, true, "the skip reason names the dependency")

  local merged_tasks = {
    task("T-a", "merged", { files = { "src/a" } }),
    task("T-b", "ready", { files = { "src/b" }, depends_on = { "T-a" } }),
  }
  started = pipeline.schedule(merged_tasks, {}, { max_parallel = 2 })
  eq(#started, 1, "a dependent task starts once its dependency is merged")
  eq(started[1].id, "T-b", "the dependent task is the one selected")

  -- schedule: only ready tasks ---------------------------------------------

  local mixed = {
    task("T-1", "draft"),
    task("T-2", "qualifying"),
    task("T-3", "running"),
    task("T-4", "ready"),
  }
  started = pipeline.schedule(mixed, {}, { max_parallel = 5 })
  eq(#started, 1, "only ready tasks are scheduled")
  eq(started[1].id, "T-4", "the ready task is scheduled")

  -- stall ------------------------------------------------------------------

  local now = pipeline.parse_iso("2026-01-01T01:00:00Z")
  local stale = {
    task("T-old", "running", { updated_at = "2026-01-01T00:00:00Z" }),
    task("T-new", "running", { updated_at = "2026-01-01T00:55:00Z" }),
    task("T-done", "deployed", { updated_at = "2026-01-01T00:00:00Z" }),
    task("T-verify", "verifying", { updated_at = "2026-01-01T00:00:00Z" }),
  }
  local stalled = pipeline.stall(stale, { now = now, stall_minutes = 20 })
  eq(#stalled, 2, "two active tasks are stale")
  eq(stalled[1].id, "T-old", "the old running task is stale")
  eq(stalled[2].id, "T-verify", "the old verifying task is stale")
  eq(stalled[1].idle_secs, 3600, "the idle time is reported")
  eq(stalled[2].status, "verifying", "the status is reported")

  local fresh = pipeline.stall({
    task("T-new", "running", { updated_at = "2026-01-01T00:55:00Z" }),
  }, { now = now, stall_minutes = 20 })
  eq(#fresh, 0, "a fresh task is not stale")

  local flagged = pipeline.stall({
    task("T-flag", "running", {
      updated_at = "2026-01-01T00:00:00Z",
      stall = { last_progress_at = "2026-01-01T00:59:00Z" },
    }),
  }, { now = now, stall_minutes = 20 })
  eq(#flagged, 0, "last_progress_at overrides updated_at")

  local default_stall = pipeline.stall({
    task("T-default", "running", { updated_at = "2026-01-01T00:00:00Z" }),
  }, { now = now })
  eq(#default_stall, 1, "the default stall window is 20 minutes")

  -- Integration: tick ------------------------------------------------------

  local root = tmp_root("pipeline-tick")
  state.create(root, { id = "T-20261114-a001", title = "a", status = "ready", files = { "src/a" } })
  state.create(root, { id = "T-20261114-a002", title = "b", status = "ready", files = { "src/b" } })
  state.create(root, { id = "T-20261114-a003", title = "c", status = "ready", files = { "src/c" } })

  local dry = pipeline.tick({
    state = state,
    root = root,
    max_parallel = 2,
    stall = false,
    apply = false,
  })
  eq(dry.ok, true, "a dry tick succeeds")
  eq(#dry.started, 2, "a dry tick selects two tasks")
  eq(#dry.skipped, 1, "a dry tick reports the third as skipped")
  eq(state.load(root).tasks["T-20261114-a001"].status, "ready", "a dry tick changes nothing")

  local dispatched = {}
  local applied = pipeline.run({
    state = state,
    root = root,
    max_parallel = 2,
    stall = false,
    dispatch = function(t, phase)
      dispatched[#dispatched + 1] = { id = t.id, phase = phase }
    end,
  })
  eq(applied.ok, true, "a live tick succeeds")
  eq(#applied.started, 2, "a live tick starts two tasks")
  eq(#dispatched, 2, "a live tick dispatches two tasks")
  eq(dispatched[1].phase, "implement", "the dispatch phase is implement")
  local after = state.load(root).tasks
  eq(after["T-20261114-a001"].status, "running", "the first task is running")
  eq(after["T-20261114-a002"].status, "running", "the second task is running")
  eq(after["T-20261114-a003"].status, "ready", "the third task is still ready")

  -- Integration: dependency in the state -----------------------------------

  local dep_root = tmp_root("pipeline-dep")
  state.create(dep_root, { id = "T-20261114-b001", title = "base", status = "ready", files = { "src/base" } })
  state.create(dep_root, {
    id = "T-20261114-b002",
    title = "child",
    status = "ready",
    files = { "src/child" },
    depends_on = { "T-20261114-b001" },
  })
  local dep_tick = pipeline.tick({
    state = state,
    root = dep_root,
    max_parallel = 2,
    stall = false,
    apply = false,
  })
  eq(#dep_tick.started, 1, "only the dependency is selected")
  eq(dep_tick.started[1].id, "T-20261114-b001", "the dependency is selected")
  eq(dep_tick.skipped[1].id, "T-20261114-b002", "the child is skipped")
  eq(dep_tick.skipped[1].reason:find("waiting on", 1, true) ~= nil, true, "the child waits on its dependency")

  -- Integration: mark_stalled ----------------------------------------------

  local stall_root = tmp_root("pipeline-stall")
  state.create(stall_root, {
    id = "T-20261114-c001",
    title = "slow",
    status = "running",
    created_at = "2026-01-01T00:00:00Z",
  })
  state.create(stall_root, {
    id = "T-20261114-c002",
    title = "verify slow",
    status = "verifying",
    created_at = "2026-01-01T00:00:00Z",
  })

  local stall_now = pipeline.parse_iso("2026-01-01T01:00:00Z")
  local marked = pipeline.mark_stalled(state, stall_root, {
    now = stall_now,
    stall_minutes = 20,
  })
  eq(type(marked), "table", "mark_stalled returns a list")
  eq(#marked, 2, "mark_stalled handles both active tasks")
  local stalled_state = state.load(stall_root).tasks
  eq(stalled_state["T-20261114-c001"].status, "stalled", "a running task moves to stalled")
  eq(stalled_state["T-20261114-c002"].status, "verifying", "a verifying task keeps its status")
  eq(stalled_state["T-20261114-c002"].stall.suspect, true, "a verifying task is flagged suspect")

  local dry_mark = pipeline.mark_stalled(state, stall_root, {
    now = stall_now,
    stall_minutes = 20,
    apply = false,
  })
  eq(#dry_mark, 1, "a dry mark reports the verifying task only")
  eq(dry_mark[1].id, "T-20261114-c002", "the dry mark names the flagged task")

  -- Integration: resume ----------------------------------------------------

  local resume_root = tmp_root("pipeline-resume")
  local statuses = { "running", "verifying", "reviewing", "merging", "deploying", "stalled" }
  for i, status in ipairs(statuses) do
    state.create(resume_root, {
      id = string.format("T-20261114-d00%d", i),
      title = status,
      status = status,
    })
  end

  local dry_resume = pipeline.resume(state, resume_root, { apply = false })
  eq(#dry_resume.resumed, 6, "resume finds every interrupted task")
  eq(#dry_resume.errors, 0, "a dry resume has no errors")
  eq(state.load(resume_root).tasks["T-20261114-d001"].status, "running", "a dry resume changes nothing")

  local resumed_dispatch = {}
  local resume = pipeline.resume(state, resume_root, {
    dispatch = function(t, phase)
      resumed_dispatch[#resumed_dispatch + 1] = { id = t.id, phase = phase }
    end,
  })
  eq(#resume.resumed, 6, "resume returns every interrupted task")
  eq(#resume.errors, 0, "every resume path is legal")
  eq(#resumed_dispatch, 6, "resume dispatches every task")
  local resumed_state = state.load(resume_root).tasks
  for i = 1, 6 do
    local id = string.format("T-20261114-d00%d", i)
    eq(resumed_state[id].status, "running", "resumed task " .. i .. " is running")
  end
  eq(resume.resumed[3].from, "reviewing", "a reviewing task remembers where it came from")
  eq(resume.resumed[3].phase, "review", "a reviewing task resumes the review phase")
  eq(resume.resumed[4].phase, "merge", "a merging task resumes the merge phase")
  eq(resume.resumed[5].phase, "deploy", "a deploying task resumes the deploy phase")

  -- Resume refuses bad input -----------------------------------------------

  local no_state = pipeline.resume(nil, "/tmp")
  eq(no_state, nil, "resume refuses without a state module")
  local no_root = pipeline.resume(state, "")
  eq(no_root, nil, "resume refuses without a root")

  -- Analysis gate ----------------------------------------------------------
  --
  -- A single task cannot contradict itself: the cross-task analysis only has
  -- something to say from two tasks on.

  eq(pipeline.needs_analysis(0), false, "no task needs no analysis")
  eq(pipeline.needs_analysis(1), false, "one task skips the analysis gate")
  eq(pipeline.needs_analysis(2), true, "two tasks go through the analysis gate")
  eq(pipeline.needs_analysis(3), true, "three tasks go through the analysis gate")
  eq(pipeline.needs_analysis(nil), false, "a missing count means no analysis")
  eq(pipeline.needs_analysis({ task("T-a", "ready") }), false, "one collected task skips the gate")
  eq(pipeline.needs_analysis({ task("T-a", "ready"), task("T-b", "ready") }), true,
    "two collected tasks go through the gate")

  -- Submit and fast mode ---------------------------------------------------
  --
  -- The runtime decides when the gate runs and when the qualifier is skipped.
  -- These cases inject the pipeline and the models so the decisions are proven
  -- without a session.

  local runtime = load_module("runtime")
  local implement = load_module("implement")
  local joinpath = maki.fs.joinpath

  local function make_runtime(label, options)
    options = options or {}
    local root = tmp_root(label)
    local paths = {
      repo = "/tmp/repo",
      root = root,
      tasks = joinpath(root, "tasks"),
      worktrees = joinpath(root, "worktrees"),
      runs = joinpath(root, "runs"),
      prompts = joinpath(root, "prompts"),
      config = joinpath(root, "config.toml"),
    }
    maki.fs.mkdir(paths.tasks, { parents = true })
    maki.fs.write(paths.config, '[project]\nrepo = "/tmp/repo"\n')
    local record = { gate = 0, qualifier = 0, implemented = 0, checks = nil }
    local cfg = {
      project = { repo = "/tmp/repo", base_ref = "main" },
      checks = { default = { "true" }, timeout_secs = 10, re_run_after_merge = false },
      review = { protected_paths = { "AGENTS.md" } },
      merge = { auto_merge = false },
      deploy = { auto_deploy = false, plan_file = "deploy.md" },
    }
    local deps = {
      config = { load = function() return cfg end },
      roles = {
        session_opts = function()
          return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
        end,
      },
      state = state,
      pipeline = pipeline,
      analyze = {
        gate = function()
          record.gate = record.gate + 1
          return { ok = true }
        end,
      },
      questions = {
        round = function() return { questions = {} } end,
        answer = function() return {} end,
      },
      implement = {
        run = function()
          record.implemented = record.implemented + 1
          if options.implement_ok then
            return { ok = true, ctx = { worktree = "/tmp/wt", branch = "b" }, sha = "abc" }
          end
          return { ok = false, error = "stop after dispatch" }
        end,
        read_sheet = function() return "" end,
      },
      checks = {
        verify = function(opts)
          record.checks = opts.checks
          return { ok = true }
        end,
        write_report = function() end,
      },
      converge = { run = function() return { ok = true } end },
      review = { review = function() return { ok = true, approved = true } end },
      git = { pr_open = function() return { number = 1, url = "u" } end },
      merge = { run = function() return { ok = true } end },
      deploy = { run = function() return { ok = true, deployed = true } end },
      calibrate = {}, fence = {}, mode = {}, runner = {},
      qualify = {
        run = function()
          record.qualifier = record.qualifier + 1
          return { ok = true, tasks = options.qualify_tasks or { { title = "one" } } }
        end,
        next_id = function() return options.next_id or "T-20260101-0001" end,
        apply = function(state_mod, state_root, result)
          local made = {}
          for i, pending in ipairs(result.tasks or {}) do
            local id = string.format("T-20260101-%04x", i + 10)
            local record = { id = id, title = pending.title, status = "draft" }
            if type(pending.files) == "table" and #pending.files > 0 then
              record.files = pending.files
            end
            local created, err = state_mod.create(state_root, record)
            if not created then
              return nil, err
            end
            state_mod.transition(state_root, id, "qualifying", { phase = "qualify" })
            state_mod.transition(state_root, id, "ready", { phase = "qualify" })
            made[#made + 1] = { id = id, title = pending.title }
          end
          return { ok = true, tasks = made }
        end,
        sheet_markdown = function(t) return "# " .. tostring(t.title) .. "\n" end,
      },
      paths = function() return paths end,
      spawn = function(fn) fn() end,
      wait_turn_end = false,
    }
    local built, err = runtime.new(deps)
    eq(type(built), "table", label .. ": runtime builds: " .. tostring(err))
    return built, record, root, paths
  end

  -- One task: no gate, straight to implementation -------------------------

  local single, single_record = make_runtime("runtime-single")
  single.submit({ intention = "add a button" }, { session = "S" })
  single.run_pending()
  eq(single_record.qualifier, 1, "a single-task submit still qualifies")
  eq(single_record.gate, 0, "a single-task submit skips analyze.gate")
  eq(single_record.implemented, 1, "a single-task submit is dispatched to implementation")

  -- Two tasks: the gate runs ----------------------------------------------

  local batch, batch_record = make_runtime("runtime-batch", {
    qualify_tasks = { { title = "first" }, { title = "second" } },
  })
  batch.submit({ intention = "split the work" }, { session = "S" })
  batch.run_pending()
  eq(batch_record.gate, 1, "a multi-task submit calls analyze.gate")

  -- Fast mode: one task, no qualifier, no files, no checks ----------------

  local fast, fast_record, fast_root, fast_paths = make_runtime("runtime-fast", {
    next_id = "T-20260101-00ff",
  })
  local fast_result = fast.submit({ intention = "add a favicon", fast = true }, { session = "S" })
  eq(fast_record.qualifier, 0, "fast mode does not call the qualifier")
  eq(fast_record.gate, 0, "fast mode creates one task and skips the gate")
  eq(fast_result and fast_result.fast, true, "fast mode reports itself")
  local fast_id = fast_result and fast_result.tasks and fast_result.tasks[1]
    and fast_result.tasks[1].id
  eq(type(fast_id), "string", "fast task has an id")
  local fast_task = fast_id and state.load(fast_root).tasks[fast_id]
  eq(fast_task and fast_task.title, "add a favicon", "the fast title is the intention verbatim")
  eq(fast_task and #(fast_task.files or {}), 0, "the fast task declares no files")
  eq(fast_task and fast_task.checks, nil, "the fast task declares no checks")
  eq(type(maki.fs.read(joinpath(fast_paths.tasks, tostring(fast_id) .. ".md"))), "string",
    "fast mode writes a sheet")

  -- Fast mode is explicit and only for a short intention ------------------

  eq(runtime.fast_requested({ intention = "add a favicon" }), false,
    "fast mode is not implicit")
  eq(runtime.fast_requested({ intention = "add a favicon", fast = true }), true,
    "fast=true on a short intention is honoured")
  local long_intention = string.rep("word ", 30)
  eq(runtime.is_short_intention("add a favicon"), true, "a short intention is short")
  eq(runtime.is_short_intention(long_intention), false, "a long intention is not short")
  eq(runtime.fast_requested({ intention = long_intention, fast = true }), false,
    "a long intention falls back to qualification even with fast=true")

  -- Default checks ---------------------------------------------------------
  --
  -- An empty list is truthy in Lua: it must not shadow config.checks.default.

  eq(table.concat(runtime.task_checks({ checks = {} }, { checks = { default = { "npm test" } } }), ","),
    "npm test", "an empty task checks list falls back to the default")
  eq(table.concat(runtime.task_checks({}, { checks = { default = { "npm test" } } }), ","),
    "npm test", "a missing task checks list falls back to the default")
  eq(table.concat(runtime.task_checks({ checks = { "make" } }, { checks = { default = { "npm test" } } }), ","),
    "make", "declared checks win over the default")

  local checks_run, checks_record = make_runtime("runtime-checks", { implement_ok = true })
  checks_run.submit({ intention = "add a thing" }, { session = "S" })
  checks_run.run_pending()
  eq(table.concat(checks_record.checks or {}, ","), "true",
    "the run path executes config.checks.default when the task declares none")

  -- Autonomous implementer: no files means the diff is the declaration -----

  local autonomous_prompt = implement.render_prompt(
    { id = "T-1", title = "do it", files = {} }, "sheet", { task_id = "T-1" }, {})
  has(autonomous_prompt, "choose them", "the autonomous prompt says the files are chosen")
  has(autonomous_prompt, "Your declaration is the branch diff",
    "the autonomous prompt says the diff is the declaration")
  local scoped_prompt = implement.render_prompt(
    { id = "T-2", title = "do it", files = { "src/a.lua" } }, "sheet", { task_id = "T-2" }, {})
  has(scoped_prompt, "Stay inside the declared files", "a scoped task keeps the scope rule")

  local persisted = {}
  local fake_state = {
    set_fields = function(_, id, fields)
      persisted[id] = fields
      return { id = id }
    end,
  }
  local fake_git = {
    changed_files = function(worktree, base, opts)
      eq(worktree, "/wt", "the diff is read from the worktree")
      eq(base, "main", "the diff is read against the base")
      eq(opts and opts.three_dot, true, "the diff uses the three-dot range")
      return { "src/a.lua", "src/b.lua" }
    end,
  }
  local declared = implement.declare_files({
    task = { id = "T-1", files = {} },
    git = fake_git,
    state = fake_state,
    root = "/root",
  }, { task_id = "T-1", worktree = "/wt", base_ref = "main" })
  eq(table.concat(declared or {}, ","), "src/a.lua,src/b.lua",
    "the autonomous declaration is the branch diff")
  eq(table.concat(persisted["T-1"] and persisted["T-1"].files or {}, ","), "src/a.lua,src/b.lua",
    "the declaration is persisted on the task")

  local ignored = implement.declare_files({
    task = { id = "T-2", files = { "src/only.lua" } },
    git = fake_git,
    state = fake_state,
    root = "/root",
  }, { task_id = "T-2", worktree = "/wt", base_ref = "main" })
  eq(ignored, nil, "a task that already declares files is not redeclared")
  eq(persisted["T-2"], nil, "a declared task is not overwritten")
end
