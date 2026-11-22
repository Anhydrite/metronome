-- Tests for maki/lua/metronome/pipeline.lua (REQ-20261114-39).
--
-- The scheduler is pure: dependencies, max_parallel, the runs-alone rule,
-- stall detection and resume are decisions over the projection. Declared
-- files never serialize tasks: each task has its own worktree and conflicts
-- resolve at merge. The integration cases use the real state module on a
-- throwaway root, so a resume is proven to walk only legal transitions.

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

  -- schedule: same file is not a conflict ----------------------------------

  -- Two ready tasks declaring the same file are selected together: each task
  -- has its own branch and worktree, conflicts resolve at merge.
  local same_file = {
    task("T-a", "ready", { files = { "src/shared.lua" } }),
    task("T-b", "ready", { files = { "src/shared.lua" } }),
  }
  local started, skipped = pipeline.schedule(same_file, {}, { max_parallel = 2 })
  eq(#started, 2, "two tasks sharing a file are both selected")
  eq(#skipped, 0, "sharing a file produces no skip")

  -- schedule: max_parallel -------------------------------------------------

  local tasks = {
    task("T-1", "ready", { files = { "src/1" } }),
    task("T-2", "ready", { files = { "src/2" } }),
    task("T-3", "ready", { files = { "src/3" } }),
  }
  started, skipped = pipeline.schedule(tasks, {}, { max_parallel = 2 })
  eq(#started, 2, "max_parallel caps the selection")
  eq(started[1].id, "T-1", "the first task starts")
  eq(started[2].id, "T-2", "the second task starts")
  eq(#skipped, 1, "the third task is skipped")
  eq(skipped[1].id, "T-3", "the skipped task is named")
  eq(skipped[1].reason:find("max_parallel", 1, true) ~= nil, true, "the skip reason is max_parallel")

  -- schedule: a running task never blocks on files -------------------------

  local running = { task("T-run", "running", { files = { "src/1" } }) }
  started, skipped = pipeline.schedule(tasks, running, { max_parallel = 4 })
  eq(#started, 3, "a running task leaves room for every ready task")
  eq(started[1].id, "T-1", "the task sharing a file with the running one starts")
  eq(#skipped, 0, "no task is skipped for file overlap")

  -- schedule: runs-alone rule for an undeclared file set -------------------

  local with_lonely = {
    task("T-1", "ready", { files = { "src/1" } }),
    task("T-2", "ready"),
  }
  started, skipped = pipeline.schedule(with_lonely, {}, { max_parallel = 2 })
  eq(#started, 1, "a task with no declared files does not run beside another")
  eq(started[1].id, "T-1", "the declared task is selected")
  eq(#skipped, 1, "the undeclared task is skipped")
  eq(skipped[1].id, "T-2", "the skipped task is named")
  eq(skipped[1].reason:find("runs alone", 1, true) ~= nil, true,
    "the skip reason is the runs-alone rule")

  -- The runs-alone rule holds in both orderings: an undeclared task that sorts
  -- before a declared one must not be selected alongside it.
  started, skipped = pipeline.schedule({
    task("T-a", "ready"),
    task("T-b", "ready", { files = { "src/b" } }),
  }, {}, { max_parallel = 2 })
  eq(#started, 1, "an undeclared task listed first does not run beside a declared one")
  eq(started[1].id, "T-b", "the declared task is selected")
  eq(#skipped, 1, "the undeclared task is skipped")
  eq(skipped[1].id, "T-a", "the skipped task is named")
  eq(skipped[1].reason:find("runs alone", 1, true) ~= nil, true,
    "the skip reason is the runs-alone rule")

  started, skipped = pipeline.schedule({ task("T-solo", "ready") }, {}, { max_parallel = 2 })
  eq(#started, 1, "a lone task with no declared files starts")
  eq(#skipped, 0, "a lone undeclared task is not skipped")

  -- The same rule holds against a task already in flight, not only against one
  -- selected in this pass.
  local in_flight = { task("T-run", "running", { files = { "src/1" } }) }
  started, skipped = pipeline.schedule({ task("T-solo", "ready") }, in_flight, { max_parallel = 4 })
  eq(#started, 0, "an undeclared task does not start beside an in-flight task")
  eq(#skipped, 1, "the undeclared task is skipped")
  eq(skipped[1].reason:find("runs alone", 1, true) ~= nil, true,
    "the skip reason is the runs-alone rule")

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

  -- retry_ready: a transient failure under the bound and due -------------

  local retry_now = 1000000
  local function failed(id, failure, extra)
    local t = task(id, "failed", extra)
    t.failure = failure
    return t
  end
  local function diag(extra)
    local f = {
      cause = "network",
      message = "network blip",
      remedy = "retry",
      transient = true,
      attempts = 1,
      at = retry_now - 120,
      next_retry_at = retry_now - 10,
      phase = "implement",
    }
    for k, v in pairs(extra or {}) do
      f[k] = v
    end
    return f
  end

  local retry_pool = {
    failed("T-due", diag(), { files = { "src/due" } }),
    failed("T-future", diag({ next_retry_at = retry_now + 60 }), { files = { "src/future" } }),
    failed("T-exhausted", diag({ attempts = 3 }), { files = { "src/exhausted" } }),
    failed("T-permanent", diag({ transient = false }), { files = { "src/permanent" } }),
    task("T-ready", "ready", { files = { "src/ready" } }),
  }
  local retries = pipeline.retry_ready(retry_pool, { now = retry_now, max_attempts = 3 })
  eq(#retries, 1, "only the due transient failure under the bound is retryable")
  eq(retries[1].id, "T-due", "the due task is selected")

  local no_deadline = pipeline.retry_ready({
    failed("T-nodeadline", diag({ next_retry_at = nil })),
  }, { now = retry_now, max_attempts = 3 })
  eq(#no_deadline, 1, "a failure without a deadline is due")

  local no_failure = pipeline.retry_ready({
    task("T-none", "failed"),
  }, { now = retry_now, max_attempts = 3 })
  eq(#no_failure, 0, "a failed task without a diagnosis is not retried")

  -- dependencies: a retryable failure is "retrying", not "blocked" --------

  local child = task("T-child", "ready", { depends_on = { "T-due" } })
  met, reason = pipeline.dependencies_met(child, retry_pool, { now = retry_now, max_attempts = 3 })
  eq(met, false, "a retrying dependency is not met")
  eq(reason:find("waiting on T-due (retrying)", 1, true) ~= nil, true,
    "the reason says the dependency is retrying")

  met, reason = pipeline.dependencies_met(
    task("T-child2", "ready", { depends_on = { "T-permanent" } }),
    retry_pool,
    { now = retry_now, max_attempts = 3 }
  )
  eq(reason:find("blocked by T-permanent (failed)", 1, true) ~= nil, true,
    "a permanent failure still blocks its dependent")

  -- A not-yet-due retry is still retrying: the dependent waits, not blocked.
  met, reason = pipeline.dependencies_met(
    task("T-child3", "ready", { depends_on = { "T-future" } }),
    retry_pool,
    { now = retry_now, max_attempts = 3 }
  )
  eq(reason:find("waiting on T-future (retrying)", 1, true) ~= nil, true,
    "a pending backoff is reported as retrying")

  -- Integration: tick retries a failed task instead of wedging -------------

  local retry_root = tmp_root("pipeline-retry")
  state.create(retry_root, {
    id = "T-20261122-e001",
    title = "retry me",
    status = "failed",
    files = { "src/retry" },
    failure = diag(),
  })
  state.create(retry_root, {
    id = "T-20261122-e002",
    title = "give up",
    status = "failed",
    files = { "src/giveup" },
    failure = diag({ attempts = 3 }),
  })
  state.create(retry_root, {
    id = "T-20261122-e003",
    title = "child",
    status = "ready",
    files = { "src/child" },
    depends_on = { "T-20261122-e001" },
  })

  local retry_tick = pipeline.run({
    state = state,
    root = retry_root,
    max_parallel = 4,
    stall = false,
    now = retry_now,
    max_attempts = 3,
    dispatch = function(t, phase)
      dispatched[#dispatched + 1] = { id = t.id, phase = phase }
    end,
  })
  eq(retry_tick.ok, true, "a tick with failures never returns ok=false")
  eq(#retry_tick.retrying, 1, "the tick reports one retry candidate")
  eq(retry_tick.retrying[1].id, "T-20261122-e001", "the retry candidate is the due one")
  local retry_after = state.load(retry_root).tasks
  eq(retry_after["T-20261122-e001"].status, "running", "the retryable task is running again")
  eq(retry_after["T-20261122-e002"].status, "failed", "the exhausted task stays failed")
  eq(retry_after["T-20261122-e003"].status, "ready", "the dependent waits instead of being blocked")
  local child_skip
  for _, item in ipairs(retry_tick.skipped) do
    if item.id == "T-20261122-e003" then
      child_skip = item
    end
  end
  eq(child_skip ~= nil, true, "the dependent is reported as skipped")
  eq(child_skip.reason:find("retrying", 1, true) ~= nil, true,
    "the dependent waits on a retrying dependency")

  -- A tick over a state with only failed-permanent tasks still succeeds.
  local stuck_tick = pipeline.tick({
    state = state,
    root = retry_root,
    max_parallel = 2,
    stall = false,
    now = retry_now,
    max_attempts = 3,
    apply = false,
  })
  eq(stuck_tick.ok, true, "a dry tick over failed tasks succeeds")

  -- Integration: resume relaunches a retryable failed task ---------------

  local retry_resume_root = tmp_root("pipeline-retry-resume")
  state.create(retry_resume_root, {
    id = "T-20261122-f001",
    title = "retry me",
    status = "failed",
    failure = diag(),
  })
  state.create(retry_resume_root, {
    id = "T-20261122-f002",
    title = "give up",
    status = "failed",
    failure = diag({ transient = false }),
  })
  local retry_resume = pipeline.resume(state, retry_resume_root, {
    now = retry_now,
    max_attempts = 3,
    apply = false,
  })
  eq(#retry_resume.resumed, 1, "resume includes only the retryable failed task")
  eq(retry_resume.resumed[1].id, "T-20261122-f001", "the retryable task is resumed")
  eq(retry_resume.resumed[1].phase, "implement", "the retry resumes its failure phase")

  local applied_resume = pipeline.resume(state, retry_resume_root, {
    now = retry_now,
    max_attempts = 3,
  })
  eq(#applied_resume.errors, 0, "the failed -> running resume path is legal")
  local retry_resumed = state.load(retry_resume_root).tasks
  eq(retry_resumed["T-20261122-f001"].status, "running", "the retryable task is running after resume")
  eq(retry_resumed["T-20261122-f002"].status, "failed", "the permanent failure stays failed after resume")

  -- Resume refuses bad input -----------------------------------------------

  local no_state = pipeline.resume(nil, "/tmp")
  eq(no_state, nil, "resume refuses without a state module")
  local no_root = pipeline.resume(state, "")
  eq(no_root, nil, "resume refuses without a root")
end
