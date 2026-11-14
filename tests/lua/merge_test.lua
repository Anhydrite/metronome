-- Tests for maki/lua/metronome/merge.lua (REQ-20261114-31).
--
-- Merge is the last step that can still fail: the branch is rebased onto the
-- fresh base, the PR is squash-merged, and the declared checks are re-run on
-- the merged base. Everything here runs real git against a throwaway
-- repository with a bare remote and a fake `gh`, so the command shapes and the
-- state moves are proven rather than assumed.
--
-- The temp dir is deliberately kept at the end so tests/run-lua.sh can validate
-- the journal the merge path wrote; the next run removes it first.

return function()
  local merge = load_module("merge")
  local git = load_module("git")
  local state = load_module("state")
  local checks = load_module("checks")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "merge")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local remote = maki.fs.joinpath(base, "remote.git")
  local repo = maki.fs.joinpath(base, "repo")
  local scripts = maki.fs.joinpath(base, "bin")
  local log = maki.fs.joinpath(base, "gh.log")
  local failfile = maki.fs.joinpath(base, "gh-fail")
  local root = maki.fs.joinpath(base, "state")

  maki.fs.mkdir(scripts, { parents = true })
  maki.fs.write(log, "")

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  local function read_log()
    return maki.fs.read(log) or ""
  end

  -- Single-quote escaping for the paths baked into the script body.
  local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end

  -- A throwaway repository with a bare remote ---------------------------------

  local code, out = sh({ "git", "init", "--bare", "-b", "main", remote })
  eq(code, 0, "bare remote created: " .. out:sub(1, 80))

  maki.fs.mkdir(repo, { parents = true })
  code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "working repo created: " .. out:sub(1, 80))
  sh({ "git", "config", "user.email", "test@example.com" }, repo)
  sh({ "git", "config", "user.name", "Test" }, repo)
  sh({ "git", "remote", "add", "origin", remote }, repo)
  maki.fs.write(maki.fs.joinpath(repo, "README.md"), "# throwaway shop\n")
  code, out = sh({ "git", "add", "-A" }, repo)
  eq(code, 0, "initial add: " .. out:sub(1, 80))
  code, out = sh({ "git", "commit", "-m", "chore: init" }, repo)
  eq(code, 0, "initial commit: " .. out:sub(1, 80))
  code, out = sh({ "git", "push", "-u", "origin", "main" }, repo)
  eq(code, 0, "initial push: " .. out:sub(1, 80))

  -- The fake `gh`: it logs every argv, merges unless a failure file exists, and
  -- always answers `pr view` with a MERGED PR. The failure file lets a test pick
  -- the exact `gh` complaint without writing a script per mode.
  local gh = maki.fs.joinpath(scripts, "gh")
  maki.fs.write(gh, table.concat({
    "#!/usr/bin/env bash",
    "LOG=" .. quote(log),
    "FAIL=" .. quote(failfile),
    "printf '%s\\n' \"$*\" >> \"$LOG\"",
    "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"merge\" ]; then",
    "  if [ -f \"$FAIL\" ]; then cat \"$FAIL\" >&2; exit 1; fi",
    "  exit 0",
    "fi",
    "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then",
    "  echo '{\"number\":42,\"url\":\"https://github.com/example/shop/pull/42\",\"state\":\"MERGED\"}'",
    "  exit 0",
    "fi",
    "echo \"unexpected: $*\" >&2",
    "exit 2",
    "",
  }, "\n"))
  code, out = sh({ "chmod", "+x", gh })
  eq(code, 0, "fake gh is executable: " .. out:sub(1, 80))

  -- Helpers -------------------------------------------------------------------

  local seeded = 0

  -- A fresh worktree cut from the freshest origin/main, with one commit on it.
  local function seed_branch()
    seeded = seeded + 1
    local id = string.format("T-20261114-mg%02d", seeded)
    local wt = maki.fs.joinpath(base, "wt-" .. id)
    local branch = "metronome/" .. id
    git.fetch(repo, "origin")
    local added, aerr = git.worktree_add(repo, wt, branch, "main", { remote = "origin" })
    eq(aerr, nil, id .. ": worktree created: " .. tostring(aerr))
    maki.fs.write(maki.fs.joinpath(wt, "shop.lua"), "return { products = {} }\n")
    local sha, serr = git.commit(wt, "feat: seed " .. id)
    eq(serr, nil, id .. ": seed committed: " .. tostring(serr))
    eq(type(sha), "string", id .. ": seed returns a sha")
    local pushed, perr = git.push(wt, branch, { remote = "origin" })
    eq(perr, nil, id .. ": branch pushed: " .. tostring(perr))
    eq(pushed, true, id .. ": branch push is ok")
    return wt, id, branch, sha
  end

  local function seed_task(id, wt, extra)
    local task = {
      id = id,
      title = "merge " .. id,
      status = "pr_open",
      branch = "metronome/" .. id,
      worktree = wt,
      base_ref = "main",
      checks = { "true" },
      pr = { number = 42, url = "https://github.com/example/shop/pull/42", state = "open" },
    }
    for k, v in pairs(extra or {}) do
      task[k] = v
    end
    local created, cerr = state.create(root, task)
    eq(cerr, nil, id .. ": task created: " .. tostring(cerr))
    return created
  end

  -- Advance main on the remote and return the new commit sha.
  local function advance_main(rel, text)
    maki.fs.write(maki.fs.joinpath(repo, rel), text or "advance\n")
    sh({ "git", "add", "-A" }, repo)
    local ccode, cout = sh({ "git", "commit", "-m", "chore: advance " .. rel }, repo)
    eq(ccode, 0, "main advanced (" .. rel .. "): " .. cout:sub(1, 80))
    local pcode, pout = sh({ "git", "push", "origin", "main" }, repo)
    eq(pcode, 0, "main pushed (" .. rel .. "): " .. pout:sub(1, 80))
    local scop, sout = sh({ "git", "-C", repo, "rev-parse", "HEAD" })
    eq(scop, 0, "main sha read: " .. sout:sub(1, 80))
    return (sout:gsub("%s+$", ""))
  end

  -- rebase: success -----------------------------------------------------------

  local wt1, id1, branch1, sha1 = seed_branch()
  local main_sha = advance_main("main-advance.txt", "advance\n")

  local rb, rberr = merge.rebase({
    git = git, repo = repo, worktree = wt1, base = "main", remote = "origin",
  })
  eq(rberr, nil, "rebase has no error: " .. tostring(rberr))
  eq(rb and rb.ok, true, "rebase is ok")
  eq(rb and rb.skipped, nil, "rebase did not skip")
  eq(rb and rb.base, "origin/main", "rebase names the fresh base")
  eq(type(rb and rb.sha), "string", "rebase returns the head")
  eq(rb and rb.sha ~= sha1, true, "rebase moved the branch head")

  local anc, anc_out = sh({ "git", "-C", wt1, "merge-base", "--is-ancestor", main_sha, "HEAD" })
  eq(anc, 0, "the fresh base commit is in the branch history: " .. anc_out:sub(1, 80))

  -- auto_rebase=false is a deliberate skip, not a failure.
  local head_before_skip = git.head_sha(wt1)
  local skip, skerr = merge.rebase({
    git = git, repo = repo, worktree = wt1, base = "main", remote = "origin", auto_rebase = false,
  })
  eq(skerr, nil, "skipped rebase has no error: " .. tostring(skerr))
  eq(skip and skip.ok, true, "skipped rebase is ok")
  eq(skip and skip.skipped, true, "auto_rebase=false skips")
  eq(git.head_sha(wt1), head_before_skip, "skipped rebase leaves the head alone")

  -- rebase: conflict ----------------------------------------------------------

  local wt2, id2, branch2 = seed_branch()
  maki.fs.write(maki.fs.joinpath(wt2, "README.md"), "# branch edit\n")
  local csha2, cserr2 = git.commit(wt2, "feat: branch edit")
  eq(cserr2, nil, "conflict branch commit: " .. tostring(cserr2))
  eq(type(csha2), "string", "conflict branch commit returns a sha")

  advance_main("README.md", "# main edit\n")

  local before_conflict = git.head_sha(wt2)
  local conf, conferr = merge.rebase({
    git = git, repo = repo, worktree = wt2, base = "main", remote = "origin",
  })
  eq(conf, nil, "conflicting rebase refused")
  eq(type(conferr), "string", "conflict explains itself")
  has(conferr, "conflict", "conflict message names the conflict")
  has(conferr, "README.md", "conflict names the file")

  local scode, sout = sh({ "git", "-C", wt2, "status", "--porcelain" })
  eq(scode, 0, "status ran after the abort")
  eq((sout:gsub("%s+$", "")), "", "worktree is clean after the abort")
  eq(git.head_sha(wt2), before_conflict, "branch head unchanged after the abort")

  -- merge_pr: success ---------------------------------------------------------

  maki.fs.rm(failfile)
  maki.fs.write(log, "")

  local m, merr = merge.merge_pr({ git = git, gh = gh, pr = 42, worktree = wt1, method = "squash" })
  eq(merr, nil, "merge_pr has no error: " .. tostring(merr))
  eq(m and m.ok, true, "merge_pr is ok")
  eq(m and m.state, "merged", "merge_pr reports merged")
  eq(m and m.already_merged, nil, "merge_pr did not take the already-merged path")

  local logtext = read_log()
  has(logtext, "pr merge 42 --squash", "gh was asked to squash-merge")
  has(logtext, "pr view 42 --json number,url,state", "gh was asked to re-read the PR")

  -- The method maps to the flag `gh` expects.
  local mm, mmerr = merge.merge_pr({ git = git, gh = gh, pr = 42, worktree = wt1, method = "merge" })
  eq(mmerr, nil, "merge method merge has no error: " .. tostring(mmerr))
  eq(mm and mm.ok, true, "merge method merge is ok")
  has(read_log(), "pr merge 42 --merge", "merge method sends --merge")

  local mr, mrerr = merge.merge_pr({ git = git, gh = gh, pr = 42, worktree = wt1, method = "rebase" })
  eq(mrerr, nil, "merge method rebase has no error: " .. tostring(mrerr))
  eq(mr and mr.ok, true, "merge method rebase is ok")
  has(read_log(), "pr merge 42 --rebase", "merge method sends --rebase")

  local mu, muerr = merge.merge_pr({ git = git, gh = gh, pr = 42, worktree = wt1, method = "fast-forward" })
  eq(mu, nil, "unknown merge method refused")
  eq(muerr, "unknown merge method: fast-forward", "unknown merge method says so plainly")

  -- merge_pr: already merged --------------------------------------------------

  maki.fs.write(failfile, "GraphQL: Pull request is already merged\n")
  local am, amerr = merge.merge_pr({ git = git, gh = gh, pr = 42, worktree = wt1 })
  eq(amerr, nil, "already-merged is not an error: " .. tostring(amerr))
  eq(am and am.ok, true, "already-merged is ok")
  eq(am and am.already_merged, true, "already-merged is flagged")
  eq(am and am.state, "merged", "already-merged reports merged")
  maki.fs.rm(failfile)

  -- merge_pr: not mergeable ---------------------------------------------------

  maki.fs.write(failfile, "Pull request is not mergeable: the merge commit cannot be cleanly created\n")
  local nm, nmerr = merge.merge_pr({ git = git, gh = gh, pr = 42, worktree = wt1 })
  eq(nm, nil, "not-mergeable refused")
  eq(type(nmerr), "string", "not-mergeable explains itself")
  has(nmerr, "not_mergeable", "not-mergeable is classified")
  has(nmerr, "cannot be merged", "not-mergeable message is readable")
  maki.fs.rm(failfile)

  -- verify_after_merge --------------------------------------------------------

  local temp = maki.fs.joinpath(root, "merge-check", id1)
  local seen_worktree = nil
  local fake_checks = {
    run = function(commands, opts)
      seen_worktree = opts.worktree
      return checks.run(commands, opts)
    end,
  }

  local vr, verr = merge.verify_after_merge({
    git = git,
    checks = fake_checks,
    repo = repo,
    root = root,
    task_id = id1,
    base = "main",
    remote = "origin",
    commands = {
      'test "$(git rev-parse --abbrev-ref HEAD)" = "HEAD"',
      "test -f README.md",
    },
  })
  eq(verr, nil, "verify_after_merge has no error: " .. tostring(verr))
  eq(vr and vr.ok, true, "verify_after_merge is green")
  eq(vr and vr.ran, 2, "both post-merge checks ran")
  eq(seen_worktree, temp, "the checks ran in the temp worktree")

  local listed, lerr = git.worktree_list(repo)
  eq(lerr, nil, "worktree list has no error")
  local still_there = false
  for _, p in ipairs(listed or {}) do
    if p == temp then still_there = true end
  end
  eq(still_there, false, "the temp worktree was removed")
  eq(maki.fs.read(maki.fs.joinpath(temp, "README.md")), nil, "the temp directory is gone")

  -- run: the full flow --------------------------------------------------------

  local wt3, id3, branch3 = seed_branch()
  local task3 = seed_task(id3, wt3)
  maki.fs.rm(failfile)
  maki.fs.write(log, "")

  local res3 = merge.run({
    task = task3,
    repo = repo,
    worktree = wt3,
    root = root,
    git = git,
    state = state,
    gh = gh,
    checks = checks,
    commands = { "true" },
    pr = 42,
    base = "main",
    remote = "origin",
  })
  eq(type(res3), "table", "run returns a result")
  eq(res3 and res3.ok, true, "run is ok: " .. tostring(res3 and res3.error))
  eq(res3 and res3.rebase and res3.rebase.ok, true, "run rebased")
  eq(res3 and res3.merge and res3.merge.ok, true, "run merged")
  eq(res3 and res3.checks and res3.checks.ok, true, "run re-ran the checks")

  local after3 = state.load(root).tasks[id3]
  eq(after3 and after3.status, "merged", "task is merged")
  eq(after3 and after3.pr and after3.pr.state, "merged", "task PR is merged")
  eq(after3 and after3.pr and after3.pr.number, 42, "task PR number is kept")
  eq(after3 and after3.pr and after3.pr.url, "https://github.com/example/shop/pull/42", "task PR url is kept")

  -- The merged branch is cleaned up: worktree removed, remote and local
  -- branches gone, so no branch is left behind forever.
  eq(res3 and res3.branch_cleanup and res3.branch_cleanup.ok, true, "run reports the branch cleanup")
  eq(res3 and res3.branch_cleanup and res3.branch_cleanup.remote_deleted, true, "the remote branch is deleted")
  eq(res3 and res3.branch_cleanup and res3.branch_cleanup.local_deleted, true, "the local branch is deleted")

  local bcode, bout = sh({ "git", "-C", repo, "branch", "--list", branch3 })
  eq(bcode, 0, "local branch list ran")
  eq((bout:gsub("%s+$", "")), "", "the merged local branch is gone")
  local rcode, rout = sh({ "git", "-C", repo, "ls-remote", "--heads", "origin", branch3 })
  eq(rcode, 0, "remote branch list ran")
  eq((rout:gsub("%s+$", "")), "", "the merged remote branch is gone")
  local listed3 = git.worktree_list(repo)
  local wt3_there = false
  for _, path in ipairs(listed3 or {}) do
    if path == wt3 then wt3_there = true end
  end
  eq(wt3_there, false, "the merged task worktree is removed")

  -- run: merge failure --------------------------------------------------------

  local wt4, id4 = seed_branch()
  local task4 = seed_task(id4, wt4)
  maki.fs.write(failfile, "Pull request is not mergeable\n")

  local res4 = merge.run({
    task = task4,
    repo = repo,
    worktree = wt4,
    root = root,
    git = git,
    state = state,
    gh = gh,
    checks = checks,
    commands = { "true" },
    pr = 42,
  })
  eq(res4 and res4.ok, false, "merge failure is not ok")
  eq(res4 and type(res4.error), "string", "merge failure explains itself")

  local after4 = state.load(root).tasks[id4]
  eq(after4 and after4.status, "failed", "task is failed after a merge failure")
  local note_found = false
  for _, note in ipairs(after4 and after4.notes or {}) do
    if type(note) == "string" and note:find("merge failed", 1, true) then
      note_found = true
    end
  end
  eq(note_found, true, "journal note records the merge failure")
  maki.fs.rm(failfile)

  -- run: post-merge checks red ------------------------------------------------

  local wt5, id5 = seed_branch()
  local task5 = seed_task(id5, wt5)
  maki.fs.rm(failfile)

  local res5 = merge.run({
    task = task5,
    repo = repo,
    worktree = wt5,
    root = root,
    git = git,
    state = state,
    gh = gh,
    checks = checks,
    commands = { "false" },
    pr = 42,
  })
  eq(res5 and res5.ok, false, "red post-merge checks are not ok")
  eq(res5 and res5.error, "post-merge checks failed", "red checks say so plainly")
  eq(res5 and res5.checks and res5.checks.ok, false, "the checks result is red")

  local after5 = state.load(root).tasks[id5]
  eq(after5 and after5.status, "failed", "task is failed after red post-merge checks")

  -- run: auto_rebase=false ----------------------------------------------------

  local wt6, id6 = seed_branch()
  local task6 = seed_task(id6, wt6)

  local res6 = merge.run({
    task = task6,
    repo = repo,
    worktree = wt6,
    root = root,
    git = git,
    state = state,
    gh = gh,
    checks = checks,
    commands = { "true" },
    pr = 42,
    auto_rebase = false,
  })
  eq(res6 and res6.ok, true, "run with auto_rebase=false is ok: " .. tostring(res6 and res6.error))
  eq(res6 and res6.rebase and res6.rebase.skipped, true, "run skipped the rebase")
  eq(state.load(root).tasks[id6].status, "merged", "task merged without a rebase")

  -- run: refusals -------------------------------------------------------------

  local no_pr = merge.run({
    task = { id = "T-20261114-mg99", status = "pr_open" },
    repo = repo,
    worktree = wt6,
    root = root,
    git = git,
    state = state,
    gh = gh,
  })
  eq(no_pr and no_pr.ok, false, "run without a PR is refused")
  has(no_pr and no_pr.error, "pull request", "the refusal names the missing PR")

  local wt7, id7 = seed_branch()
  local task7 = seed_task(id7, wt7, { status = "merged" })
  local res7 = merge.run({
    task = task7,
    repo = repo,
    worktree = wt7,
    root = root,
    git = git,
    state = state,
    gh = gh,
    checks = checks,
    commands = { "true" },
    pr = 42,
  })
  eq(res7 and res7.ok, false, "cannot merge from merged")
  eq(res7 and res7.error, "cannot merge from merged", "the refusal names the status")

  -- Cleanup -------------------------------------------------------------------
  --
  -- The temp dir stays: tests/run-lua.sh validates the journal it holds. The
  -- next run removes the dir before rebuilding it.
end
