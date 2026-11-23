-- Tests for maki/lua/metronome/implement.lua (REQ-20261114-27).
--
-- The implementation turn is proven against a real throwaway repository and a
-- local bare remote: prepare creates the worktree, checkpoint records the base
-- SHA, and a fake runner stands in for the model. Nothing outside the temp dir
-- is written, and the temp dir is kept so tests/run-lua.sh can validate the
-- journal it produced.

return function()
  local git = load_module("git")
  local state = load_module("state")
  local implement = load_module("implement")

  -- Base-branch guard (REQ-20261114-49): no direct commit on main.
  eq(implement.assert_task_branch("metronome/T-1", "main"), true,
    "a task branch may commit")
  local guarded, guarded_err = implement.assert_task_branch("main", "main")
  eq(guarded, nil, "the base branch is refused")
  has(guarded_err, "pull request", "the refusal names the pull request rule")
  eq(implement.assert_task_branch("master", "main"), nil, "master is refused too")
  eq(implement.assert_task_branch(nil, "main"), nil, "a missing branch is refused")

  -- test_dir() empties and recreates the per-test workspace, so two runs (or
  -- two tests) never share a journal, a temporary repository or a worktree.
  local base = test_dir("implement")

  local remote = maki.fs.joinpath(base, "remote.git")
  local repo = maki.fs.joinpath(base, "repo")
  local root = maki.fs.joinpath(base, "state")
  local worktree_root = maki.fs.joinpath(base, "worktrees")
  local tasks_dir = maki.fs.joinpath(base, "tasks")
  local run_state_root = maki.fs.joinpath(base, "runs")

  maki.fs.mkdir(tasks_dir, { parents = true })

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  local function sheet_for(id, title)
    local text = table.concat({
      "# " .. title,
      "",
      "- ID: " .. id,
      "- Files: src/feature.lua",
      "- Checks: make test",
      "",
      "## Acceptance",
      "- it works",
      "",
    }, "\n")
    maki.fs.write(maki.fs.joinpath(tasks_dir, id .. ".md"), text)
    return text
  end

  local function new_task(id, title, files, checks)
    local created, err = state.create(root, {
      id = id,
      title = title,
      status = "ready",
      files = files or { "src/feature.lua" },
      checks = checks or { "make test" },
    })
    eq(err, nil, "task " .. id .. " created: " .. tostring(err))
    return created
  end

  -- A throwaway repository with a bare remote --------------------------------

  local code, out = sh({ "git", "init", "--bare", "-b", "main", remote })
  eq(code, 0, "bare remote created: " .. out:sub(1, 80))

  maki.fs.mkdir(repo, { parents = true })
  code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "working repo created: " .. out:sub(1, 80))
  sh({ "git", "config", "user.email", "test@example.com" }, repo)
  sh({ "git", "config", "user.name", "Test" }, repo)
  sh({ "git", "remote", "add", "origin", remote }, repo)
  maki.fs.write(maki.fs.joinpath(repo, "README.md"), "# throwaway\n")
  code, out = sh({ "git", "add", "-A" }, repo)
  eq(code, 0, "initial add: " .. out:sub(1, 80))
  code, out = sh({ "git", "commit", "-m", "chore: init" }, repo)
  eq(code, 0, "initial commit: " .. out:sub(1, 80))
  code, out = sh({ "git", "push", "-u", "origin", "main" }, repo)
  eq(code, 0, "initial push: " .. out:sub(1, 80))

  -- Paths and names ----------------------------------------------------------

  local id = "T-20261114-e001"
  eq(implement.worktree_path(root, id), maki.fs.joinpath(root, "worktrees", id),
    "worktree_path defaults under root")
  eq(implement.worktree_path(root, id, { worktree_root = worktree_root }),
    maki.fs.joinpath(worktree_root, id), "worktree_path honours worktree_root")
  eq(implement.branch_for(id), "metronome/" .. id, "branch_for uses the default prefix")
  eq(implement.branch_for(id, { branch_prefix = "task/" }), "task/" .. id,
    "branch_for honours branch_prefix")

  -- Branch names say what the feature is, not just which ticket it is.
  eq(implement.branch_for(id, { title = "Add feature flag" }),
    "metronome/add-feature-flag-e001", "branch_for slugs the title and keeps the short id")
  eq(implement.branch_for(id, { title = "Tarte aux pommes à 4,5 €" }),
    "metronome/tarte-aux-pommes-a-4-5-e001", "branch_for folds accents and punctuation")
  eq(implement.branch_for(id, { title = "  " }), "metronome/" .. id,
    "an empty title falls back to the id")
  eq(#implement.slug("un titre vraiment tres long qui depasse la limite de longueur autorisee"), 48,
    "slug cuts at the limit")
  eq(implement.slug("a--b__c"), "a-b-c", "slug collapses separators")
  eq(implement.sheet_path(root, id), maki.fs.joinpath(root, "tasks", id .. ".md"),
    "sheet_path defaults under root")
  eq(implement.sheet_path(root, id, { tasks_dir = tasks_dir }),
    maki.fs.joinpath(tasks_dir, id .. ".md"), "sheet_path honours tasks_dir")

  -- Sheet reading ------------------------------------------------------------

  local task = new_task(id, "Add feature flag",
    { "src/flag.lua", "src/flag_test.lua" }, { "make test", "make lint" })
  local sheet_text = sheet_for(id, "Add feature flag")
  eq(implement.read_sheet(root, task, { tasks_dir = tasks_dir }), sheet_text,
    "read_sheet returns the sheet verbatim")

  local fallback = implement.read_sheet(root, task, {
    tasks_dir = maki.fs.joinpath(base, "missing-sheets"),
  })
  has(fallback, "Add feature flag", "fallback sheet keeps the title")
  has(fallback, id, "fallback sheet keeps the id")
  has(fallback, "src/flag.lua", "fallback sheet keeps the files")
  has(fallback, "make test", "fallback sheet keeps the checks")

  -- Prompt rendering ---------------------------------------------------------

  local ctx = {
    task_id = id,
    repo = repo,
    worktree = maki.fs.joinpath(worktree_root, id),
    branch = "metronome/" .. id,
    base_ref = "main",
  }
  local prompt = implement.render_prompt(task, sheet_text, ctx, {})
  has(prompt, "# Implementation task", "prompt has the top heading")
  has(prompt, "## Task sheet", "prompt has the sheet section")
  has(prompt, sheet_text, "prompt carries the sheet verbatim")
  has(prompt, id, "prompt names the task id")
  has(prompt, "Add feature flag", "prompt names the title")
  has(prompt, "src/flag.lua", "prompt names the files")
  has(prompt, "make test", "prompt names the checks")
  has(prompt, "## Worktree", "prompt has the worktree section")
  has(prompt, ctx.worktree, "prompt names the worktree")
  has(prompt, ctx.branch, "prompt names the branch")
  has(prompt, "main", "prompt names the base")
  has(prompt, "## Checks", "prompt has the checks section")
  has(prompt, "## Rules", "prompt has the rules section")
  has(prompt, "Stay inside the declared files", "prompt states the scope rule")

  -- An undeclared file set is the fast lane: the implementer chooses the files.
  local free_task = {}
  for k, v in pairs(task) do
    free_task[k] = v
  end
  free_task.files = {}
  local free_prompt = implement.render_prompt(free_task, sheet_text, ctx, {})
  has(free_prompt, "choose the files the change genuinely needs",
    "prompt lets the implementer choose files when none are declared")
  eq(free_prompt:find("Stay inside the declared files", 1, true), nil,
    "an undeclared file set does not claim a scope it does not have")

  -- A fix turn carries the reviewer's findings as the work list.
  local fix_prompt = implement.render_prompt(task, sheet_text, ctx, {
    feedback = {
      { severity = "major", message = "contrast too low", path = "public/styles.css", line = 21 },
      { severity = "minor", message = "hardcoded red" },
    },
  })
  has(fix_prompt, "## Review feedback", "a fix turn has a feedback section")
  has(fix_prompt, "[major] public/styles.css:21 — contrast too low",
    "the finding names its severity, location and message")
  has(fix_prompt, "[minor] hardcoded red", "a finding without a path still reads")
  eq(prompt:find("## Review feedback", 1, true), nil,
    "a first turn carries no feedback section")

  -- Answered questions are binding, even when the sheet is missing or lagging:
  -- the prompt renders task.questions[].answer on its own.
  local answered_task = {}
  for k, v in pairs(task) do
    answered_task[k] = v
  end
  answered_task.questions = {
    { id = "q1", text = "Which persistence strategy?",
      answer = "persist slot_wait", answered_at = "2026-11-23T16:27:00Z" },
    { id = "q2", text = "Still open?" },
  }
  local answered_prompt = implement.render_prompt(answered_task, "", ctx, {})
  local binding_heading = "## Réponses aux questions (contraignantes)"
  has(answered_prompt, binding_heading, "an answered question adds the binding section")
  has(answered_prompt, "persist slot_wait", "the binding section carries the answer")
  has(answered_prompt, "2026-11-23T16:27:00Z", "the binding section carries the answered date")
  has(answered_prompt, "q1", "the binding section names the question id")
  has(answered_prompt, "Which persistence strategy?", "the binding section carries the question text")
  has(answered_prompt, "the answer wins", "the binding section states the answer wins")
  has(answered_prompt, "intent is overridden", "the binding section states the answer overrides the intent")
  eq(answered_prompt:find("Still open?", 1, true), nil,
    "an unanswered question is not presented as binding")
  local heading_at = answered_prompt:find(binding_heading, 1, true)
  local rules_at = answered_prompt:find("## Rules", 1, true)
  eq(heading_at ~= nil and rules_at ~= nil and heading_at < rules_at, true,
    "the binding section comes before the rules")

  -- A task with no answered question gains nothing.
  eq(prompt:find(binding_heading, 1, true), nil,
    "a task without answers has no binding section")

  -- Prepare ------------------------------------------------------------------

  local prep_opts = {
    task = task,
    repo = repo,
    state = state,
    root = root,
    git = git,
    worktree_root = worktree_root,
    tasks_dir = tasks_dir,
    remote = "origin",
    base_ref = "main",
  }

  local ctx1, perr = implement.prepare(prep_opts)
  eq(perr, nil, "prepare has no error: " .. tostring(perr))
  eq(ctx1 and ctx1.task_id, id, "prepare returns the task id")
  eq(ctx1 and ctx1.repo, repo, "prepare returns the repo")
  eq(ctx1 and ctx1.worktree, maki.fs.joinpath(worktree_root, id), "prepare returns the worktree")
  eq(ctx1 and ctx1.branch, "metronome/add-feature-flag-e001", "prepare names the branch after the feature")
  eq(ctx1 and ctx1.base_ref, "main", "prepare returns the base")

  local loaded = state.load(root).tasks[id]
  eq(loaded and loaded.status, "running", "prepare moves the task to running")
  eq(loaded and loaded.branch, "metronome/add-feature-flag-e001", "prepare stores the branch")
  eq(loaded and loaded.worktree, maki.fs.joinpath(worktree_root, id), "prepare stores the worktree")
  eq(loaded and loaded.base_ref, "main", "prepare stores the base")
  eq(git.current_branch(ctx1.worktree), "metronome/add-feature-flag-e001", "the worktree is on the task branch")

  local ctx2, perr2 = implement.prepare(prep_opts)
  eq(perr2, nil, "second prepare has no error: " .. tostring(perr2))
  eq(ctx2 and ctx2.worktree, ctx1.worktree, "second prepare reuses the worktree")
  local listed = git.worktree_list(repo)
  local count = 0
  for _, path in ipairs(listed or {}) do
    if path == ctx1.worktree then
      count = count + 1
    end
  end
  eq(count, 1, "the worktree is registered exactly once")

  -- Remove the worktree but keep the branch: prepare must re-attach it.
  local removed, rerr = git.worktree_remove(repo, ctx1.worktree, { force = true })
  eq(removed, true, "worktree removed: " .. tostring(rerr))
  local ctx3, perr3 = implement.prepare(prep_opts)
  eq(perr3, nil, "prepare re-attaches the existing branch: " .. tostring(perr3))
  eq(ctx3 and ctx3.worktree, ctx1.worktree, "re-attached worktree has the same path")
  eq(git.current_branch(ctx3.worktree), "metronome/add-feature-flag-e001",
    "re-attached worktree is on the existing branch")

  -- A checkout deleted behind git's back (a reset state root, a crashed run)
  -- leaves a stale registration. prepare must prune it and re-add the branch
  -- instead of reusing a path that no longer exists.
  maki.fs.rm(ctx3.worktree, { recursive = true })
  local ctx4, perr4 = implement.prepare(prep_opts)
  eq(perr4, nil, "prepare prunes a stale worktree registration: " .. tostring(perr4))
  eq(ctx4 and maki.fs.metadata(ctx4.worktree) ~= nil, true,
    "prepare recreates the worktree directory")
  eq(ctx4 and git.current_branch(ctx4.worktree), "metronome/add-feature-flag-e001",
    "the recreated worktree is on the task branch")

  -- Git lock -----------------------------------------------------------------
  --
  -- Two maki processes on the same clone can still race for a ref lock even
  -- though fetch is single-flight in process. A `git_lock` is contention, not a
  -- broken task: prepare replays it with a short bounded backoff (three
  -- attempts, ~200 ms with jitter) and only fails once the budget is spent. The
  -- sleep is injected so the test proves the budget without waiting.

  local function git_with(overrides)
    local out = {}
    for key, value in pairs(git) do
      out[key] = value
    end
    for key, value in pairs(overrides or {}) do
      out[key] = value
    end
    return out
  end

  local lock_diag = {
    cause = "git_lock",
    message = "another git process holds a ref lock",
    hint = "wait for the other git process and retry",
  }

  local retry_id = "T-20261122-a048"
  local retry_task = new_task(retry_id, "Retry a git lock", { "src/retry.lua" }, { "make test" })
  local fetch_calls = 0
  local retry_sleeps = {}
  local flaky_fetch = git_with({
    fetch = function()
      fetch_calls = fetch_calls + 1
      if fetch_calls < 3 then
        return nil, "fetch failed [git_lock]: cannot lock ref", lock_diag
      end
      return true
    end,
  })
  local retry_opts = {
    task = retry_task,
    repo = repo,
    state = state,
    root = root,
    git = flaky_fetch,
    worktree_root = worktree_root,
    tasks_dir = tasks_dir,
    remote = "origin",
    base_ref = "main",
    sleep = function(ms)
      retry_sleeps[#retry_sleeps + 1] = ms
    end,
  }
  local retry_ctx, retry_err = implement.prepare(retry_opts)
  eq(retry_err, nil, "a git_lock on fetch is replayed: " .. tostring(retry_err))
  eq(retry_ctx and retry_ctx.task_id, retry_id, "the replayed prepare returns its context")
  eq(fetch_calls, 3, "the first git_lock is not fatal: prepare makes three attempts")
  eq(#retry_sleeps, 2, "prepare backs off between the replay attempts")
  eq(type(retry_sleeps[1]) == "number" and retry_sleeps[1] >= 200
    and retry_sleeps[1] < 400, true, "the backoff is short and jittered around 200 ms")

  -- The budget is bounded and the diagnostic reaches the caller, so it can
  -- branch on `diag.cause == "git_lock"` instead of a raw string.
  local exhausted_task = new_task("T-20261122-b048", "Exhaust a git lock",
    { "src/lock.lua" }, { "make test" })
  local exhausted_calls = 0
  local exhausted_sleeps = {}
  local locked_git = git_with({
    fetch = function()
      exhausted_calls = exhausted_calls + 1
      return nil, "fetch failed [git_lock]: cannot lock ref", lock_diag
    end,
  })
  local exhausted_opts = {
    task = exhausted_task,
    repo = repo,
    state = state,
    root = root,
    git = locked_git,
    worktree_root = worktree_root,
    tasks_dir = tasks_dir,
    remote = "origin",
    base_ref = "main",
    sleep = function(ms)
      exhausted_sleeps[#exhausted_sleeps + 1] = ms
    end,
  }
  local ectx, eerr, ediag = implement.prepare(exhausted_opts)
  eq(ectx, nil, "an exhausted git_lock does not prepare a worktree")
  eq(type(eerr), "string", "an exhausted git_lock reports an error")
  eq(type(ediag) == "table" and ediag.cause, "git_lock",
    "prepare propagates the git diagnostic as its third value")
  eq(exhausted_calls, 3, "prepare stops after three bounded attempts")
  eq(#exhausted_sleeps, 2, "an exhausted replay backs off twice")

  -- A non-lock failure is permanent: it is not replayed.
  local hard_calls = 0
  local hard_sleeps = {}
  local hard_git = git_with({
    fetch = function()
      hard_calls = hard_calls + 1
      return nil, "fetch failed [auth_failed]: denied",
        { cause = "auth_failed", message = "denied", hint = "login" }
    end,
  })
  local hard_opts = {}
  for key, value in pairs(exhausted_opts) do
    hard_opts[key] = value
  end
  hard_opts.task = new_task("T-20261122-c048", "Auth failure", { "src/a.lua" }, { "make test" })
  hard_opts.git = hard_git
  hard_opts.sleep = function(ms)
    hard_sleeps[#hard_sleeps + 1] = ms
  end
  local hctx, herr, hdiag = implement.prepare(hard_opts)
  eq(hctx, nil, "a permanent failure does not prepare")
  eq(hdiag and hdiag.cause, "auth_failed", "a permanent failure keeps its cause")
  eq(hard_calls, 1, "a non-lock failure is not replayed")
  eq(#hard_sleeps, 0, "a non-lock failure does not sleep")

  -- Checkpoints --------------------------------------------------------------

  local head = git.head_sha(ctx3.worktree)
  eq(type(head), "string", "the base sha is available")
  eq(#head, 40, "the base sha is full length")

  local cp1, cperr = implement.checkpoint({
    git = git, state = state, root = root, task_id = id, worktree = ctx3.worktree,
  })
  eq(cperr, nil, "checkpoint has no error: " .. tostring(cperr))
  eq(cp1, head, "the first checkpoint is the base sha")
  local after_cp1 = state.load(root).tasks[id]
  eq(#after_cp1.checkpoints, 1, "the first checkpoint is recorded once")
  eq(after_cp1.checkpoints[1], head, "the recorded checkpoint is the base sha")

  local cp2, cperr2 = implement.checkpoint({
    git = git, state = state, root = root, task_id = id, worktree = ctx3.worktree,
  })
  eq(cperr2, nil, "the second checkpoint has no error")
  eq(cp2, head, "the second checkpoint is the same sha")
  eq(#state.load(root).tasks[id].checkpoints, 1, "an unchanged head is not duplicated")

  maki.fs.write(maki.fs.joinpath(ctx3.worktree, "checkpoint.txt"), "one\n")
  local csha, cserr = git.commit(ctx3.worktree, "feat: checkpoint")
  eq(cserr, nil, "checkpoint commit has no error: " .. tostring(cserr))
  local cp3, cperr3 = implement.checkpoint({
    git = git, state = state, root = root, task_id = id, worktree = ctx3.worktree,
  })
  eq(cperr3, nil, "the third checkpoint has no error")
  eq(cp3, csha, "a new commit produces a new checkpoint")
  eq(#state.load(root).tasks[id].checkpoints, 2, "the new checkpoint is appended")

  -- Run ----------------------------------------------------------------------

  local function run_opts(task_row, runner)
    return {
      task = task_row,
      repo = repo,
      state = state,
      root = root,
      git = git,
      worktree_root = worktree_root,
      tasks_dir = tasks_dir,
      remote = "origin",
      base_ref = "main",
      runner = runner,
      session_opts = {
        system = "test-system",
        model_spec = "test-model",
        thinking = "low",
        tools = { "read", "write" },
      },
      state_root = run_state_root,
      ctx = "session-ctx",
      max_attempts = 1,
      deadline_secs = 30,
    }
  end

  -- implement.run surfaces the same diagnostic, so the runtime can name
  -- git_lock on the task instead of losing it behind a string.
  local run_lock_task = new_task("T-20261122-d048", "Run a git lock",
    { "src/runlock.lua" }, { "make test" })
  sheet_for("T-20261122-d048", "Run a git lock")
  local run_lock_calls = 0
  local run_lock_git = git_with({
    fetch = function()
      run_lock_calls = run_lock_calls + 1
      return nil, "fetch failed [git_lock]: cannot lock ref", lock_diag
    end,
  })
  local run_lock_opts = run_opts(run_lock_task, function()
    return { ok = true, text = "should not run" }
  end)
  run_lock_opts.git = run_lock_git
  run_lock_opts.sleep = function() end
  local run_lock = implement.run(run_lock_opts)
  eq(run_lock.ok, false, "an exhausted git_lock fails the turn")
  eq(run_lock.diagnosis and run_lock.diagnosis.cause, "git_lock",
    "run returns the git diagnostic for the caller")
  eq(run_lock_calls, 3, "run respects the same three-attempt budget")

  -- Scenario A: the runner writes a file, twice, so checkpoints accumulate.
  local id2 = "T-20261114-e002"
  local task2 = new_task(id2, "Add widget", { "src/widget.lua" }, { "make test" })
  sheet_for(id2, "Add widget")

  local seen = nil
  local turn = 0
  local function writing_runner(args)
    seen = args
    turn = turn + 1
    local wt = maki.fs.joinpath(worktree_root, args.task_id)
    maki.fs.write(maki.fs.joinpath(wt, "widget_" .. turn .. ".lua"), "return " .. turn .. "\n")
    return { ok = true, text = "done " .. turn }
  end

  local result1 = implement.run(run_opts(task2, writing_runner))
  eq(result1.ok, true, "a writing turn succeeds: " .. tostring(result1.error))
  eq(seen and seen.role, "implementer", "the runner is called as the implementer")
  eq(seen and seen.phase, "implement", "the runner is called in the implement phase")
  eq(seen and seen.task_id, id2, "the runner is called for the task")
  eq(seen and seen.system, "test-system", "the runner gets the system prompt")
  eq(seen and seen.model_spec, "test-model", "the runner gets the model spec")
  eq(seen and seen.thinking, "low", "the runner gets the thinking level")
  eq(seen and seen.state_root, run_state_root, "the runner gets the state root")
  eq(seen and seen.ctx, "session-ctx", "the runner gets the session ctx")
  has(seen and seen.prompt, id2, "the runner prompt names the task")

  eq(type(result1.sha), "string", "the turn returns a sha")
  eq(#result1.sha, 40, "the sha is full length")
  eq(result1.no_changes, false, "a writing turn reports changes")

  local wt2 = maki.fs.joinpath(worktree_root, id2)
  local lcode, lout = sh({ "git", "-C", wt2, "ls-tree", "-r", "--name-only", "HEAD" })
  eq(lcode, 0, "the worktree head is readable")
  has(lout, "widget_1.lua", "the runner's file is committed")

  local rcode, rout = sh({ "git", "-C", remote, "rev-parse", "--verify", "refs/heads/metronome/add-widget-e002" })
  eq(rcode, 0, "the task branch is on the bare remote: " .. rout:sub(1, 80))

  local result1b = implement.run(run_opts(task2, writing_runner))
  eq(result1b.ok, true, "the second writing turn succeeds: " .. tostring(result1b.error))
  eq(result1b.no_changes, false, "the second writing turn reports changes")
  local after2 = state.load(root).tasks[id2]
  eq(after2 and after2.status, "running", "the task stays running")
  eq(after2 and #after2.checkpoints, 2, "two turns recorded two checkpoints")
  local lcode2, lout2 = sh({ "git", "-C", wt2, "ls-tree", "-r", "--name-only", "HEAD" })
  eq(lcode2, 0, "the second head is readable")
  has(lout2, "widget_2.lua", "the second turn's file is committed")

  -- Scenario B: the runner does nothing.
  local id3 = "T-20261114-e003"
  local task3 = new_task(id3, "No-op task", { "src/noop.lua" }, { "make test" })
  sheet_for(id3, "No-op task")
  local function noop_runner(args)
    return { ok = true, text = "nothing to do" }
  end

  local result3 = implement.run(run_opts(task3, noop_runner))
  eq(result3.ok, true, "a no-op turn succeeds: " .. tostring(result3.error))
  eq(result3.no_changes, true, "a no-op turn reports no changes")
  eq(result3.sha, result3.checkpoint, "the no-op sha is the checkpoint")
  eq(#result3.sha, 40, "the no-op sha is full length")

  -- Scenario C: the runner fails.
  local id4 = "T-20261114-e004"
  local task4 = new_task(id4, "Failing task", { "src/fail.lua" }, { "make test" })
  sheet_for(id4, "Failing task")
  local function failing_runner(args)
    return { ok = false, error = "boom: the model refused" }
  end

  local result4 = implement.run(run_opts(task4, failing_runner))
  eq(result4.ok, false, "a failing turn fails")
  has(tostring(result4.error), "boom", "the runner error is propagated")
  eq(result4.run and result4.run.ok, false, "the runner result is returned")
  local wt4 = maki.fs.joinpath(worktree_root, id4)
  eq(git.head_sha(wt4), result4.checkpoint, "a failed turn does not commit")
  local fcode = sh({ "git", "-C", remote, "rev-parse", "--verify", "refs/heads/metronome/failing-task-e004" })
  eq(fcode ~= 0, true, "a failed turn does not push")

  -- Scenario D: the runner commits by itself.
  local id5 = "T-20261114-e005"
  local task5 = new_task(id5, "Self commit task", { "src/self.lua" }, { "make test" })
  sheet_for(id5, "Self commit task")
  local self_sha = nil
  local function self_commit_runner(args)
    local wt = maki.fs.joinpath(worktree_root, args.task_id)
    maki.fs.write(maki.fs.joinpath(wt, "self.lua"), "return true\n")
    local sha, err = git.commit(wt, "feat: self commit")
    self_sha = sha
    return { ok = true, text = "committed myself" }
  end

  local result5 = implement.run(run_opts(task5, self_commit_runner))
  eq(result5.ok, true, "a self-committing turn succeeds: " .. tostring(result5.error))
  eq(result5.no_changes, false, "a self-committing turn is a real change")
  eq(result5.sha, self_sha, "the turn keeps the runner's sha")
  eq(#result5.sha, 40, "the self-commit sha is full length")
  local wt5 = maki.fs.joinpath(worktree_root, id5)
  local scode, sout = sh({ "git", "-C", wt5, "log", "-1", "--format=%s" })
  eq(scode, 0, "the self-commit log is readable")
  has(sout, "feat: self commit", "the runner's commit is the head")

  -- Scenario E: the branch was rewritten (a rebase onto the fresh base, a
  -- rollback), so its history no longer descends from what origin holds. A
  -- plain push would be refused as non-fast-forward; the turn must lease the
  -- push and land the commit anyway.
  local id6 = "T-20261114-e006"
  local task6 = new_task(id6, "Rewritten branch", { "src/rw.lua" }, { "make test" })
  sheet_for(id6, "Rewritten branch")
  local function rewrite_runner(args)
    local wt = maki.fs.joinpath(worktree_root, args.task_id)
    maki.fs.write(maki.fs.joinpath(wt, "rw.lua"), "return 1\n")
    local sha = git.commit(wt, "feat: first commit")
    -- Rewrite the commit: same tree, different history, exactly what a rebase
    -- onto a moved base does.
    sh({ "git", "-C", wt, "commit", "--amend", "-q", "-m", "feat: rewritten commit" })
    return { ok = true, text = "committed and rewrote" }
  end
  local result6 = implement.run(run_opts(task6, rewrite_runner))
  eq(result6.ok, true, "a rewritten branch still pushes: " .. tostring(result6.error))
  local wt6 = maki.fs.joinpath(worktree_root, id6)
  local local_sha = git.head_sha(wt6)
  local rcode6, remote_sha = sh({ "git", "-C", remote, "rev-parse", "refs/heads/metronome/rewritten-branch-e006" })
  eq(rcode6, 0, "the rewritten branch reached the remote")
  eq((remote_sha:gsub("%s+$", "")), local_sha, "the remote holds the rewritten commit")

  -- Scenario F: the commit is already in place and the worktree is clean when
  -- the turn's own commit runs -- exactly the state that used to be reported as
  -- `git commit exit 1: Sur la branche main ... rien à valider` and condemned a
  -- finished task. The turn must succeed, take HEAD as its sha and reach the
  -- push, so the caller goes on to the checks instead of failing.
  local id7 = "T-20261122-f001"
  local task7 = new_task(id7, "Already committed", { "src/done.lua" }, { "make test" })
  sheet_for(id7, "Already committed")
  local clean_sha = nil
  local function clean_turn_runner(args)
    local wt = maki.fs.joinpath(worktree_root, args.task_id)
    maki.fs.write(maki.fs.joinpath(wt, "done.lua"), "return true\n")
    clean_sha = git.commit(wt, "feat: done")
    return { ok = true, text = "committed by the runner" }
  end
  local result7 = implement.run(run_opts(task7, clean_turn_runner))
  eq(result7.ok, true, "a clean tree after the runner's commit is a success: " .. tostring(result7.error))
  eq(result7.no_changes, false, "a turn that really committed reports changes")
  eq(result7.sha, clean_sha, "the sha is the head the runner left")
  eq(type(result7.sha) == "string" and #result7.sha, 40, "the clean turn sha is full length")
  local wt7 = maki.fs.joinpath(worktree_root, id7)
  eq(git.head_sha(wt7), result7.sha, "the benign commit leaves HEAD untouched")
  local rcode7, rsha7 = sh({ "git", "-C", remote, "rev-parse", "refs/heads/metronome/already-committed-f001" })
  eq(rcode7, 0, "the clean turn reaches the push: the branch is on the remote")
  eq((rsha7:gsub("%s+$", "")), result7.sha, "the remote holds the turn's commit")
  local after7 = state.load(root).tasks[id7]
  eq(after7 and after7.status, "running", "the clean turn keeps the task running")
  local failed_note = false
  for _, note in ipairs(after7 and after7.notes or {}) do
    if type(note) == "string" and note:find("git commit failed", 1, true) then
      failed_note = true
    end
  end
  eq(failed_note, false, "the clean turn writes no failure note")

  -- The temp dir is deliberately kept: tests/run-lua.sh validates its journal.
end
