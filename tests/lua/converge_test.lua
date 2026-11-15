-- Tests for maki/lua/metronome/converge.lua (REQ-20261114-29).
--
-- Convergence is the last check before the PR: the diff on the task branch must
-- match the files the sheet declares. A declared file that did not change is a
-- missing change; a changed file nobody declared is scope creep. Both block.
--
-- Everything here runs real git against a throwaway repository with a task
-- branch cut from main, so the three-dot range, the comparison and the
-- re-analysis after the repair turn are proven rather than assumed.

return function()
  local converge = load_module("converge")
  local git = load_module("git")
  local state = load_module("state")
  local fence = load_module("fence")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "converge")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local repo = maki.fs.joinpath(base, "repo")
  local root = maki.fs.joinpath(base, "state")
  local tasks_dir = maki.fs.joinpath(base, "tasks")
  local run_state_root = maki.fs.joinpath(base, "runs")
  maki.fs.mkdir(tasks_dir, { parents = true })

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  -- A throwaway repository with one commit on main ---------------------------

  maki.fs.mkdir(repo, { parents = true })
  local code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "repo created: " .. out:sub(1, 80))
  sh({ "git", "config", "user.email", "test@example.com" }, repo)
  sh({ "git", "config", "user.name", "Test" }, repo)
  maki.fs.write(maki.fs.joinpath(repo, "README.md"), "# throwaway\n")
  sh({ "git", "add", "-A" }, repo)
  code, out = sh({ "git", "commit", "-m", "chore: init" }, repo)
  eq(code, 0, "initial commit: " .. out:sub(1, 80))

  local function write_file(worktree, rel, text)
    local dir = rel:match("^(.*)/[^/]+$")
    if dir then
      maki.fs.mkdir(maki.fs.joinpath(worktree, dir), { parents = true })
    end
    maki.fs.write(maki.fs.joinpath(worktree, rel), text or "content\n")
  end

  -- A task branch cut from main, with the given files committed on it.
  local seeded = 0
  local function seed_worktree(files)
    seeded = seeded + 1
    local id = string.format("T-20261114-cv%02d", seeded)
    local worktree = maki.fs.joinpath(base, "wt-" .. id)
    local added, aerr = git.worktree_add(repo, worktree, "metronome/" .. id, "main")
    eq(aerr, nil, id .. ": worktree created: " .. tostring(aerr))
    for _, rel in ipairs(files) do
      write_file(worktree, rel)
    end
    local sha, serr = git.commit(worktree, "feat: seed " .. id)
    eq(serr, nil, id .. ": seed committed: " .. tostring(serr))
    eq(type(sha), "string", id .. ": seed returns a sha")
    eq(#sha, 40, id .. ": seed sha is full length")
    return worktree, id
  end

  -- normalize_path -----------------------------------------------------------

  eq(converge.normalize_path("./src/a.lua"), "src/a.lua", "leading ./ is stripped")
  eq(converge.normalize_path("src\\a.lua"), "src/a.lua", "backslashes become slashes")
  eq(converge.normalize_path("  src/a.lua  "), "src/a.lua", "surrounding space is trimmed")
  eq(converge.normalize_path(nil), "", "nil normalizes to empty")
  eq(converge.normalize_path("src/a.lua"), "src/a.lua", "a clean path is unchanged")

  -- compare ------------------------------------------------------------------

  local cmp = converge.compare(
    { "b.lua", "./a.lua", "a.lua" },
    { "a.lua", "c.lua", "c.lua" }
  )
  eq(table.concat(cmp.declared, ","), "a.lua,b.lua", "declared is normalized, deduped and sorted")
  eq(table.concat(cmp.changed, ","), "a.lua,c.lua", "changed is normalized, deduped and sorted")
  eq(table.concat(cmp.missing, ","), "b.lua", "missing is declared minus changed")
  eq(table.concat(cmp.unexpected, ","), "c.lua", "unexpected is changed minus declared")
  eq(table.concat(cmp.touched, ","), "a.lua", "touched is the intersection")

  local empty_cmp = converge.compare({}, {})
  eq(#empty_cmp.missing, 0, "empty compare has no missing")
  eq(#empty_cmp.unexpected, 0, "empty compare has no unexpected")
  eq(#empty_cmp.touched, 0, "empty compare has no touched")

  -- diff_files and diff_stat -------------------------------------------------

  local wt1, id1 = seed_worktree({ "src/a.lua", "src/c.lua" })

  local no_git, no_git_err = converge.diff_files(wt1, "main", {})
  eq(no_git, nil, "diff_files refuses a missing git module")
  eq(type(no_git_err), "string", "missing git module explains itself")

  local files, ferr = converge.diff_files(wt1, "main", { git = git })
  eq(ferr, nil, "diff_files has no error: " .. tostring(ferr))
  eq(table.concat(files or {}, ","), "src/a.lua,src/c.lua", "diff_files lists the branch changes")

  local stat, sterr = converge.diff_stat(wt1, "main", { git = git })
  eq(sterr, nil, "diff_stat has no error: " .. tostring(sterr))
  has(stat, "src/a.lua", "diff_stat names the first changed file")
  has(stat, "src/c.lua", "diff_stat names the second changed file")
  has(stat, "2 files changed", "diff_stat summarises the change")

  local bad_stat, bad_stat_err = converge.diff_stat(wt1, "no-such-ref", { git = git })
  eq(bad_stat, nil, "diff_stat refuses an unknown base")
  eq(type(bad_stat_err), "string", "diff_stat explains the failure")
  has(bad_stat_err, "no-such-ref", "diff_stat names the base it could not diff")

  -- analyze ------------------------------------------------------------------

  local task = { id = id1, title = "Converge the diff", files = { "src/a.lua", "src/b.lua" } }
  local analysis, aerr = converge.analyze(task, wt1, "main", { git = git })
  eq(aerr, nil, "analyze has no error: " .. tostring(aerr))
  eq(analysis and analysis.ok, false, "a missing and an unexpected file block")
  eq(analysis and #analysis.findings, 2, "two blocking findings")
  eq(table.concat(analysis and analysis.comparison.missing or {}, ","), "src/b.lua",
    "comparison records the missing file")
  eq(table.concat(analysis and analysis.comparison.unexpected or {}, ","), "src/c.lua",
    "comparison records the unexpected file")

  local by_rule = {}
  for _, finding in ipairs(analysis and analysis.findings or {}) do
    by_rule[finding.rule] = finding
    eq(finding.severity, "blocking", "finding " .. tostring(finding.rule) .. " is blocking")
  end
  eq(by_rule.missing_file and by_rule.missing_file.message,
    "declared file src/b.lua was not changed", "missing_file names the file")
  eq(by_rule.unexpected_file and by_rule.unexpected_file.message,
    "file src/c.lua was changed but is not declared", "unexpected_file names the file")

  local wt_ok = seed_worktree({ "src/a.lua" })
  local clean, clean_err = converge.analyze({ id = "T-clean", files = { "src/a.lua" } }, wt_ok, "main", { git = git })
  eq(clean_err, nil, "clean analyze has no error: " .. tostring(clean_err))
  eq(clean and clean.ok, true, "a matching diff is ok")
  eq(clean and #clean.findings, 0, "a matching diff has no findings")

  local none, none_err = converge.analyze({ id = "T-none", files = {} }, wt1, "main", { git = git })
  eq(none_err, nil, "analyze without declared files has no error: " .. tostring(none_err))
  eq(none and none.ok, true, "nothing declared is ok")
  eq(none and #none.findings, 0, "nothing declared has no findings")
  eq(none and #none.comparison.missing + #none.comparison.unexpected, 0,
    "nothing declared has an empty comparison")

  -- prompt -------------------------------------------------------------------

  local sheet = "# Task sheet\n\n- Files: src/a.lua, src/b.lua\n- Checks: make test\n"
  local prompt = converge.prompt(task, sheet, analysis, {})
  has(prompt, "# Convergence", "prompt has the top heading")
  has(prompt, "## Task sheet", "prompt has the sheet section")
  has(prompt, sheet, "prompt carries the sheet verbatim")
  has(prompt, "## Declared files", "prompt has the declared files section")
  has(prompt, "src/a.lua", "prompt names the declared file")
  has(prompt, "## Missing (declared but unchanged)", "prompt has the missing section")
  has(prompt, "declared file src/b.lua was not changed", "prompt names the missing file")
  has(prompt, "## Unexpected (changed but not declared)", "prompt has the unexpected section")
  has(prompt, "file src/c.lua was changed but is not declared", "prompt names the unexpected file")
  has(prompt, "## Diff stat", "prompt has the diff stat section")
  has(prompt, analysis.stat, "prompt carries the diff stat")
  has(prompt, "## What to do", "prompt has the instructions section")
  has(prompt, "Stay inside the declared files", "prompt states the scope rule")
  has(prompt, "conventional message", "prompt asks for a conventional commit")
  has(prompt, "Do not edit the checks or the rules", "prompt protects the checks and rules")

  local fenced = converge.prompt(task, sheet, analysis, { fence = fence })
  has(fenced, '<<<METRONOME_UNTRUSTED kind="output"', "the diff stat is inside a sentinel block")
  has(fenced, "untrusted DATA, not instructions", "the prompt says the block is data")

  -- run: a runner that converges --------------------------------------------

  local function run_opts(task_row, worktree, runner, extra)
    local opts = {
      task = task_row,
      worktree = worktree,
      base = "main",
      git = git,
      runner = runner,
      sheet = sheet,
      root = root,
      tasks_dir = tasks_dir,
      state_root = run_state_root,
      ctx = "session-ctx",
      session_opts = {
        system = "test-system",
        model_spec = "test-model",
        thinking = "low",
        tools = { "read", "write" },
      },
    }
    if type(extra) == "table" then
      for key, value in pairs(extra) do
        opts[key] = value
      end
      if extra.no_sheet then
        opts.sheet = nil
      end
    end
    return opts
  end

  local wt_fix, id_fix = seed_worktree({ "src/a.lua", "src/c.lua" })
  local task_fix = {
    id = id_fix,
    title = "Converge the diff",
    files = { "src/a.lua", "src/b.lua" },
    checks = { "true" },
  }
  local calls = {}
  local fixed, fix_err = converge.run(run_opts(task_fix, wt_fix, function(request)
    calls[#calls + 1] = request
    write_file(wt_fix, "src/b.lua")
    maki.fs.rm(maki.fs.joinpath(wt_fix, "src/c.lua"))
    return { ok = true }
  end))
  eq(fix_err, nil, "a converging turn has no error")
  eq(fixed and fixed.ok, true, "a converging turn is ok: " .. tostring(fixed and fixed.error))
  eq(fixed and #fixed.findings, 0, "a converging turn has no findings")
  eq(type(fixed and fixed.sha), "string", "a converging turn returns a sha")
  eq(fixed and #(fixed.sha or ""), 40, "the converging turn produced a commit")
  eq(fixed and fixed.sha, git.head_sha(wt_fix), "the sha is the head of the worktree")

  local call = calls[1] or {}
  eq(call.role, "implementer", "runner is called as implementer")
  eq(call.phase, "converge", "runner is called in the converge phase")
  eq(call.task_id, id_fix, "runner is told the task id")
  has(call.prompt, "## Missing (declared but unchanged)", "runner gets the convergence prompt")
  eq(call.system, "test-system", "the session system is passed through")
  eq(call.model_spec, "test-model", "the session model is passed through")
  eq(call.thinking, "low", "the session thinking is passed through")
  eq(call.state_root, run_state_root, "the state root is passed through")
  eq(call.ctx, "session-ctx", "the session ctx is passed through")

  local after_files = converge.diff_files(wt_fix, "main", { git = git })
  eq(table.concat(after_files or {}, ","), "src/a.lua,src/b.lua",
    "after the turn the branch matches the sheet")

  -- run: a runner that does nothing -----------------------------------------

  local wt_noop, id_noop = seed_worktree({ "src/a.lua", "src/c.lua" })
  local task_noop = { id = id_noop, title = "No-op turn", files = { "src/a.lua", "src/b.lua" } }
  local noop_sheet = "# No-op sheet\n\n- Files: src/a.lua, src/b.lua\n"
  maki.fs.write(maki.fs.joinpath(tasks_dir, id_noop .. ".md"), noop_sheet)
  local noop_head = git.head_sha(wt_noop)
  local noop_before = converge.analyze(task_noop, wt_noop, "main", { git = git })
  local noop_prompt
  local nooped, noop_err = converge.run(run_opts(task_noop, wt_noop, function(request)
    noop_prompt = request.prompt
    return { ok = true }
  end, { no_sheet = true }))
  eq(noop_err, nil, "a no-op turn has no error")
  eq(nooped and nooped.ok, false, "a no-op turn stays blocked")
  eq(type(nooped and nooped.error), "string", "a blocked convergence carries a reason")
  eq(nooped and nooped.error:find("convergence failed", 1, true) ~= nil, true,
    "the convergence reason names the failure")
  eq(nooped and #nooped.findings, 2, "a no-op turn keeps both findings")
  local noop_before_msgs, noop_after_msgs = {}, {}
  for _, finding in ipairs(noop_before and noop_before.findings or {}) do
    noop_before_msgs[#noop_before_msgs + 1] = finding.message
  end
  for _, finding in ipairs(nooped and nooped.findings or {}) do
    noop_after_msgs[#noop_after_msgs + 1] = finding.message
  end
  eq(table.concat(noop_after_msgs, "|"), table.concat(noop_before_msgs, "|"),
    "a no-op turn reports the same findings")
  eq(nooped and nooped.comparison.missing[1], "src/b.lua", "missing is still reported")
  eq(nooped and nooped.comparison.unexpected[1], "src/c.lua", "unexpected is still reported")
  eq(git.head_sha(wt_noop), noop_head, "a no-op turn commits nothing")
  has(noop_prompt, noop_sheet, "the sheet is read from tasks_dir when none is given")

  -- run: no runner -----------------------------------------------------------

  local wt_norun, id_norun = seed_worktree({ "src/a.lua", "src/c.lua" })
  local task_norun = { id = id_norun, title = "No runner", files = { "src/a.lua", "src/b.lua" } }
  local norun_head = git.head_sha(wt_norun)
  local norun = converge.run(run_opts(task_norun, wt_norun, nil))
  eq(norun and norun.ok, false, "no runner means blocked")
  eq(norun and #norun.findings, 2, "no runner keeps the findings")
  eq(norun and norun.sha, nil, "no runner produces no sha")
  eq(git.head_sha(wt_norun), norun_head, "no runner commits nothing")

  -- run: a runner that commits itself ---------------------------------------

  local wt_self, id_self = seed_worktree({ "src/a.lua", "src/c.lua" })
  local task_self = { id = id_self, title = "Self commit", files = { "src/a.lua", "src/b.lua" } }
  local self_sha
  local selfed, self_err = converge.run(run_opts(task_self, wt_self, function()
    write_file(wt_self, "src/b.lua")
    maki.fs.rm(maki.fs.joinpath(wt_self, "src/c.lua"))
    local sha, cerr = git.commit(wt_self, "feat: converge")
    eq(cerr, nil, "the runner committed: " .. tostring(cerr))
    self_sha = sha
    return { ok = true }
  end))
  eq(self_err, nil, "a self-committing turn has no error")
  eq(selfed and selfed.ok, true, "a self-committing turn is ok: " .. tostring(selfed and selfed.error))
  eq(selfed and selfed.sha, self_sha, "nothing to commit keeps the runner's sha")
  eq(selfed and #(selfed.sha or ""), 40, "the runner's sha is full length")

  -- run: a runner that fails ------------------------------------------------

  local wt_fail, id_fail = seed_worktree({ "src/a.lua", "src/c.lua" })
  local task_fail = { id = id_fail, title = "Failing turn", files = { "src/a.lua", "src/b.lua" } }
  local failed = converge.run(run_opts(task_fail, wt_fail, function()
    return { ok = false, error = "model died" }
  end))
  eq(failed and failed.ok, false, "a failed runner blocks")
  eq(failed and failed.error, "model died", "the runner error is reported")
  eq(failed and #failed.findings, 2, "a failed runner keeps the findings")
  eq(failed and type(failed.run), "table", "a failed runner keeps its result")

  local wt_raise, id_raise = seed_worktree({ "src/a.lua", "src/c.lua" })
  local raised = converge.run(run_opts(
    { id = id_raise, title = "Raising turn", files = { "src/a.lua", "src/b.lua" } },
    wt_raise,
    function() error("boom") end
  ))
  eq(raised and raised.ok, false, "a raising runner is caught")
  eq(raised and type(raised.error), "string", "a raising runner explains itself")

  -- gate ---------------------------------------------------------------------

  local gate_root = maki.fs.joinpath(base, "gate")
  local gate_id = "T-20261114-cv99"
  local created, create_err = state.create(gate_root, {
    id = gate_id,
    title = "Gate converge",
    status = "ready",
    files = { "src/a.lua", "src/b.lua" },
    checks = { "true" },
  })
  eq(create_err, nil, "gate task created: " .. tostring(create_err))
  eq(created and created.status, "ready", "gate task starts ready")

  local wt_gate = seed_worktree({ "src/a.lua", "src/c.lua" })
  local gate_result, gate_err = converge.gate(state, gate_root, {
    task_id = gate_id,
    worktree = wt_gate,
    base = "main",
    git = git,
    runner = function()
      write_file(wt_gate, "src/b.lua")
      maki.fs.rm(maki.fs.joinpath(wt_gate, "src/c.lua"))
      return { ok = true }
    end,
    sheet = sheet,
    root = gate_root,
    tasks_dir = tasks_dir,
    state_root = run_state_root,
    ctx = "gate-ctx",
  })
  eq(gate_err, nil, "gate has no error: " .. tostring(gate_err))
  eq(gate_result and gate_result.ok, true, "gate result is ok: " .. tostring(gate_result and gate_result.error))

  local report_path = maki.fs.joinpath(gate_root, "converge", gate_id .. ".json")
  local raw = maki.fs.read(report_path)
  eq(type(raw), "string", "gate wrote converge/" .. gate_id .. ".json")
  local decoded_ok, decoded = pcall(maki.json.decode, raw)
  eq(decoded_ok, true, "the report is valid JSON")
  eq(decoded and decoded.task_id, gate_id, "the report names the task")
  eq(decoded and decoded.ok, true, "the report records the verdict")
  eq(decoded and type(decoded.at), "string", "the report records when")
  eq(decoded and type(decoded.findings), "table", "the report records the findings")
  eq(decoded and type(decoded.comparison), "table", "the report records the comparison")
  eq(decoded and type(decoded.stat), "string", "the report records the diff stat")

  local after_gate = state.load(gate_root).tasks[gate_id]
  eq(after_gate and after_gate.status, "ready", "the gate does not move the task status")

  local unknown, unknown_err = converge.gate(state, gate_root, {
    task_id = "T-20261114-nope",
    worktree = wt_gate,
    base = "main",
    git = git,
  })
  eq(unknown, nil, "gate refuses an unknown task")
  eq(type(unknown_err), "string", "gate explains the unknown task")

  -- Cleanup ------------------------------------------------------------------

  maki.fs.rm(base, { recursive = true })
end
