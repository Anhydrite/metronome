-- Tests for maki/lua/metronome/checks.lua (REQ-20261114-28).
--
-- The checks are the proof that a task is done: they run in the worktree, they
-- must exit 0, and a red check sends the branch back to the last checkpoint.
-- Everything here runs real `sh` commands and, for the rollback half, a real
-- throwaway repository, so the behaviour is proven rather than assumed.

return function()
  local checks = load_module("checks")
  local git = load_module("git")
  local state = load_module("state")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "checks")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local work = maki.fs.joinpath(base, "work")
  maki.fs.mkdir(work, { parents = true })

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  -- Running the declared checks ---------------------------------------------

  local green, gerr = checks.run({ "true", "echo hi" }, { worktree = work })
  eq(gerr, nil, "green run has no error: " .. tostring(gerr))
  eq(green and green.ok, true, "green run is ok")
  eq(green and #green.results, 2, "both checks ran")
  eq(green and green.ran, 2, "ran counts both checks")
  eq(green and #green.failed, 0, "no failed check")
  eq(green and green.results[1].code, 0, "first check exits 0")
  eq(green and green.results[1].ok, true, "first check is ok")
  eq(green and green.results[2].code, 0, "second check exits 0")
  has(green and green.results[2].stdout, "hi", "stdout is captured")
  eq(green and green.results[2].command, "echo hi", "command is recorded")
  eq(green and type(green.results[2].duration_ms), "number", "duration is recorded")

  local red, rerr = checks.run({ "false" }, { worktree = work })
  eq(rerr, nil, "red run has no error: " .. tostring(rerr))
  eq(red and red.ok, false, "red run is not ok")
  eq(red and #red.failed, 1, "one failed check")
  eq(red and red.failed[1].command, "false", "failed command is recorded")
  eq(red and red.failed[1].code, 1, "failed command keeps its exit code")
  eq(red and red.failed[1].ok, false, "failed command is not ok")

  local mixed, merr = checks.run({ "echo out; echo err >&2; exit 3" }, { worktree = work })
  eq(merr, nil, "mixed run has no error: " .. tostring(merr))
  eq(mixed and mixed.results[1].code, 3, "exit code 3 is kept")
  has(mixed and mixed.results[1].stdout, "out", "stdout is kept")
  has(mixed and mixed.results[1].stderr, "err", "stderr is kept")
  eq(mixed and mixed.results[1].ok, false, "non-zero exit is not ok")

  -- A check that never finishes is a failure, not a hang.
  local slow, serr = checks.run({ "sleep 5" }, { worktree = work, timeout_ms = 100 })
  eq(serr, nil, "timeout run has no error: " .. tostring(serr))
  eq(slow and slow.ok, false, "timed out run is not ok")
  eq(slow and slow.results[1].timed_out, true, "timed out check is marked")
  eq(slow and slow.results[1].ok, false, "timed out check is not ok")
  eq(slow and slow.results[1].code, nil, "timed out check has no exit code")

  -- fail_fast stops at the first red check.
  local ff, fferr = checks.run({ "false", "true" }, { worktree = work, fail_fast = true })
  eq(fferr, nil, "fail_fast run has no error: " .. tostring(fferr))
  eq(ff and ff.ran, 1, "fail_fast stops after the first failure")
  eq(ff and #ff.results, 1, "fail_fast keeps one result")
  eq(ff and ff.ok, false, "fail_fast run is not ok")

  -- No declared checks is a valid, green run.
  local none, nerr = checks.run({}, { worktree = work })
  eq(nerr, nil, "empty run has no error: " .. tostring(nerr))
  eq(none and none.ok, true, "empty run is ok")
  eq(none and none.ran, 0, "empty run ran nothing")

  -- A malformed check is refused with the index that is wrong.
  local bad, baderr = checks.run({ 123 }, { worktree = work })
  eq(bad, nil, "non-string check refused")
  eq(baderr, "check 1 is not a non-empty string", "non-string check names its index")
  local blank, blankerr = checks.run({ "true", "   " }, { worktree = work })
  eq(blank, nil, "blank check refused")
  eq(blankerr, "check 2 is not a non-empty string", "blank check names its index")

  -- Output is truncated to max_output, so a noisy check cannot flood the report.
  local loud, lerr = checks.run({ "printf abcdefghij" }, { worktree = work, max_output = 4 })
  eq(lerr, nil, "truncated run has no error: " .. tostring(lerr))
  eq(loud and loud.results[1].stdout, "abcd", "stdout is truncated to max_output")

  -- Last checkpoint ---------------------------------------------------------

  local explicit = checks.last_checkpoint({ checkpoint = "abc1234" })
  eq(explicit, "abc1234", "explicit checkpoint wins")

  local stroot = maki.fs.joinpath(base, "state")
  local task_id = "T-20261114-c001"
  local created, cerr = state.create(stroot, {
    id = task_id,
    title = "checks",
    status = "ready",
    checkpoints = { "aaaaaaa", "bbbbbbb" },
  })
  eq(cerr, nil, "task with checkpoints created: " .. tostring(cerr))
  eq(created and created.status, "ready", "task is ready")

  local last, lasterr = checks.last_checkpoint({ state = state, root = stroot, task_id = task_id })
  eq(lasterr, nil, "last checkpoint has no error: " .. tostring(lasterr))
  eq(last, "bbbbbbb", "last checkpoint is the newest one")

  local wins = checks.last_checkpoint({
    checkpoint = "ccccccc",
    state = state,
    root = stroot,
    task_id = task_id,
  })
  eq(wins, "ccccccc", "explicit checkpoint wins over the state")

  local bare_id = "T-20261114-c002"
  local bare, berr = state.create(stroot, { id = bare_id, title = "no checkpoint", status = "ready" })
  eq(berr, nil, "task without checkpoints created: " .. tostring(berr))
  eq(bare and bare.status, "ready", "bare task is ready")
  local missing, merr2 = checks.last_checkpoint({ state = state, root = stroot, task_id = bare_id })
  eq(missing, nil, "no checkpoint is refused")
  eq(merr2, "no checkpoint to return to", "no checkpoint says so plainly")

  -- Rollback on a real repository -------------------------------------------

  local repo = maki.fs.joinpath(base, "repo")
  maki.fs.mkdir(repo, { parents = true })
  local code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "repo created: " .. out:sub(1, 80))
  sh({ "git", "config", "user.email", "test@example.com" }, repo)
  sh({ "git", "config", "user.name", "Test" }, repo)

  maki.fs.write(maki.fs.joinpath(repo, "file.txt"), "one\n")
  local sha_a, aerr = git.commit(repo, "feat: A")
  eq(aerr, nil, "commit A: " .. tostring(aerr))
  eq(type(sha_a), "string", "commit A returns a sha")

  maki.fs.write(maki.fs.joinpath(repo, "file.txt"), "two\n")
  local sha_b, berr2 = git.commit(repo, "feat: B")
  eq(berr2, nil, "commit B: " .. tostring(berr2))
  eq(type(sha_b), "string", "commit B returns a sha")
  eq(sha_b ~= sha_a, true, "B is a different commit")

  local rb, rberr = checks.rollback({ git = git, worktree = repo, checkpoint = sha_a })
  eq(rberr, nil, "rollback has no error: " .. tostring(rberr))
  eq(rb and rb.ok, true, "rollback is ok")
  eq(rb and rb.checkpoint, sha_a, "rollback names the checkpoint")
  eq(rb and rb.sha, sha_a, "rollback returns the new HEAD")
  eq(git.head_sha(repo), sha_a, "HEAD is back at A")
  eq(maki.fs.read(maki.fs.joinpath(repo, "file.txt")), "one\n", "file content is back to A")

  -- Verify: green, red with rollback, red without rollback -------------------

  local repo2 = maki.fs.joinpath(base, "repo2")
  maki.fs.mkdir(repo2, { parents = true })
  code, out = sh({ "git", "init", "-b", "main" }, repo2)
  eq(code, 0, "second repo created: " .. out:sub(1, 80))
  sh({ "git", "config", "user.email", "test@example.com" }, repo2)
  sh({ "git", "config", "user.name", "Test" }, repo2)

  maki.fs.write(maki.fs.joinpath(repo2, "file.txt"), "one\n")
  local sha_a2, aerr2 = git.commit(repo2, "feat: A")
  eq(aerr2, nil, "second commit A: " .. tostring(aerr2))
  maki.fs.write(maki.fs.joinpath(repo2, "file.txt"), "two\n")
  local sha_b2, berr3 = git.commit(repo2, "feat: B")
  eq(berr3, nil, "second commit B: " .. tostring(berr3))
  eq(git.head_sha(repo2), sha_b2, "second repo starts at B")

  local green_v, gverr = checks.verify({
    checks = { "true" },
    worktree = repo2,
    checkpoint = sha_a2,
    git = git,
  })
  eq(gverr, nil, "green verify has no error: " .. tostring(gverr))
  eq(green_v and green_v.ok, true, "green verify is ok")
  eq(green_v and green_v.rolled_back, false, "green verify does not roll back")
  eq(green_v and green_v.ran, 1, "green verify ran the check")
  eq(green_v and #green_v.failed, 0, "green verify has no failed check")
  eq(git.head_sha(repo2), sha_b2, "green verify leaves HEAD alone")

  local red_v, rverr = checks.verify({
    checks = { "false" },
    worktree = repo2,
    checkpoint = sha_a2,
    git = git,
  })
  eq(rverr, nil, "red verify has no error: " .. tostring(rverr))
  eq(red_v and red_v.ok, false, "red verify is not ok")
  eq(red_v and red_v.rolled_back, true, "red verify rolls back")
  eq(red_v and red_v.checkpoint, sha_a2, "red verify names the checkpoint")
  eq(red_v and red_v.sha, sha_a2, "red verify reports the restored HEAD")
  eq(red_v and red_v.failed[1] and red_v.failed[1].command, "false", "red verify keeps the failed command")
  eq(git.head_sha(repo2), sha_a2, "red verify moved HEAD to the checkpoint")
  eq(maki.fs.read(maki.fs.joinpath(repo2, "file.txt")), "one\n", "red verify restored the files")

  -- Put B back so the no-rollback case starts from the same place.
  local back, backerr = git.reset_hard(repo2, sha_b2)
  eq(backerr, nil, "repo restored to B: " .. tostring(backerr))
  eq(back, sha_b2, "repo is at B again")

  local noroll, nrerr = checks.verify({
    checks = { "false" },
    worktree = repo2,
    checkpoint = sha_a2,
    git = git,
    rollback = false,
  })
  eq(nrerr, nil, "no-rollback verify has no error: " .. tostring(nrerr))
  eq(noroll and noroll.ok, false, "no-rollback verify is not ok")
  eq(noroll and noroll.rolled_back, false, "no-rollback verify does not roll back")
  eq(git.head_sha(repo2), sha_b2, "no-rollback verify leaves HEAD unchanged")
  eq(maki.fs.read(maki.fs.joinpath(repo2, "file.txt")), "two\n", "no-rollback verify leaves the files alone")

  -- Report ------------------------------------------------------------------

  local path, werr = checks.write_report(base, task_id, noroll, { now = "2026-11-14T00:00:00Z" })
  eq(werr, nil, "write_report has no error: " .. tostring(werr))
  eq(path, maki.fs.joinpath(base, "checks", task_id .. ".json"), "report path is checks/<task>.json")
  local text = maki.fs.read(path)
  eq(type(text), "string", "report file exists")
  has(text, task_id, "report contains the task id")
  has(text, "false", "report contains the failed command")
  local decoded_ok, decoded = pcall(maki.json.decode, text)
  eq(decoded_ok, true, "report is valid JSON")
  eq(decoded and decoded.task_id, task_id, "report task id round-trips")
  eq(decoded and decoded.ok, false, "report records the red verdict")
  eq(decoded and decoded.rolled_back, false, "report records the rollback decision")
  eq(decoded and decoded.ran, 1, "report records how many checks ran")
  eq(decoded and decoded.at, "2026-11-14T00:00:00Z", "report honours the injected clock")
  eq(decoded and type(decoded.results), "table", "report embeds the results")

  -- Cleanup -----------------------------------------------------------------
  --
  -- The last_checkpoint test writes a state journal through state.lua; keep the
  -- base when it does, so a journal is never deleted from under the suite.
  if not maki.fs.read(maki.fs.joinpath(stroot, "state.jsonl")) then
    maki.fs.rm(base, { recursive = true })
  end
end
