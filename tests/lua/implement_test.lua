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

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "implement")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

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
  eq(ctx1 and ctx1.branch, "metronome/" .. id, "prepare returns the branch")
  eq(ctx1 and ctx1.base_ref, "main", "prepare returns the base")

  local loaded = state.load(root).tasks[id]
  eq(loaded and loaded.status, "running", "prepare moves the task to running")
  eq(loaded and loaded.branch, "metronome/" .. id, "prepare stores the branch")
  eq(loaded and loaded.worktree, maki.fs.joinpath(worktree_root, id), "prepare stores the worktree")
  eq(loaded and loaded.base_ref, "main", "prepare stores the base")
  eq(git.current_branch(ctx1.worktree), "metronome/" .. id, "the worktree is on the task branch")

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
  eq(git.current_branch(ctx3.worktree), "metronome/" .. id,
    "re-attached worktree is on the existing branch")

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

  local rcode, rout = sh({ "git", "-C", remote, "rev-parse", "--verify", "refs/heads/metronome/" .. id2 })
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
  local fcode = sh({ "git", "-C", remote, "rev-parse", "--verify", "refs/heads/metronome/" .. id4 })
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

  -- The temp dir is deliberately kept: tests/run-lua.sh validates its journal.
end
