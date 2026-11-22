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
  local conf, conferr, confinfo = merge.rebase({
    git = git, repo = repo, worktree = wt2, base = "main", remote = "origin",
  })
  eq(conf, nil, "conflicting rebase refused")
  eq(type(conferr), "string", "conflict explains itself")
  has(conferr, "conflict", "conflict message names the conflict")
  has(conferr, "README.md", "conflict names the file")
  eq(type(confinfo), "table", "the conflict is reported as a repairable state")
  eq(confinfo and confinfo.conflict and confinfo.conflict[1], "README.md",
    "the conflicting file is named for the repair")

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

  -- A deploy module is injected to prove the merge path never calls it.
  local deploy_called = false
  local deploy_spy = {
    run = function()
      deploy_called = true
      return { ok = true }
    end,
  }

  local res3 = merge.run({
    task = task3,
    repo = repo,
    worktree = wt3,
    root = root,
    git = git,
    state = state,
    gh = gh,
    checks = checks,
    deploy = deploy_spy,
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

  -- The merge records the base for a deployer and returns at `merged`: it
  -- never triggers or waits for a deploy itself.
  local pending3 = state.deploy_pending(root)
  eq(type(pending3), "table", "merge records a deploy-pending base")
  eq(pending3 and pending3.base, "main", "the deploy-pending base is the merged base")
  eq(res3 and res3.deploy_pending and res3.deploy_pending.base, "main", "the result reports the pending base")
  eq(deploy_called, false, "merge does not invoke deploy.run")
  eq(after3 and after3.status == "merged", true, "merge stops at merged, not deploying")

  -- The flag is journal-backed and the merge holds no lock: a deployer in
  -- another process must still see the pending base after a fresh reload, and
  -- must be free to take the single-flight lock itself.
  local reloaded = state.load(root)
  eq(reloaded.tasks[id3] and reloaded.tasks[id3].status, "merged",
    "state reload still reports the task as merged")
  eq(reloaded.deploy and reloaded.deploy.pending and reloaded.deploy.pending.base, "main",
    "the pending base survives a journal reload")
  eq(reloaded.deploy and reloaded.deploy.pending and type(reloaded.deploy.pending.at), "string",
    "the pending base records when it was set")
  eq(state.deploy_lock(root), nil, "merge never takes the deploy lock")

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
  state.set_deploy_pending(root, "keepme")

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
  eq(state.deploy_pending(root).base, "keepme", "a failed merge does not overwrite the pending base")
  maki.fs.rm(failfile)

  -- run: post-merge checks red ------------------------------------------------

  local wt5, id5 = seed_branch()
  local task5 = seed_task(id5, wt5)
  maki.fs.rm(failfile)
  state.set_deploy_pending(root, "keepme")

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
  eq(state.deploy_pending(root).base, "keepme", "red checks do not record a pending base")

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

  -- run: a rebase conflict is a repairable result, not a failure -------------

  -- A rebase conflict used to write `failed` before the runtime could decide:
  -- the task never went back to implement, so the same commit was replayed on
  -- the same lines and the same conflict came back. The conflict must now be
  -- returned whole, the status left alone, and the escalation must name the
  -- files, the base (with its SHA), the command and the faulty commit.
  local wt8, id8 = seed_branch()
  local task8 = seed_task(id8, wt8)
  maki.fs.write(maki.fs.joinpath(wt8, "README.md"), "# branch edit for conflict\n")
  local csha8, cserr8 = git.commit(wt8, "feat: branch edit for conflict")
  eq(cserr8, nil, "conflict branch commit: " .. tostring(cserr8))
  eq(type(csha8), "string", "conflict branch commit returns a sha")

  local conflict_main_sha = advance_main("README.md", "# main edit for conflict\n")

  maki.fs.rm(failfile)
  maki.fs.write(log, "")

  local res8 = merge.run({
    task = task8,
    repo = repo,
    worktree = wt8,
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
  eq(res8 and res8.ok, false, "a conflicting rebase is not ok")
  eq(res8 and res8.conflict, true, "a conflicting rebase is flagged as a conflict")
  eq(type(res8 and res8.conflict_files), "string", "conflict_files is a joined string")
  has(res8 and res8.conflict_files, "README.md", "conflict_files names the file")
  eq(type(res8 and res8.conflict_file_list), "table", "conflict_file_list is the raw list")
  eq(res8 and res8.conflict_file_list and res8.conflict_file_list[1], "README.md",
    "conflict_file_list names the file")
  -- The runtime fails the task with `result.error` once the repair bound is
  -- reached: that message must be the escalation, not git's bare output.
  has(res8 and res8.error, "README.md", "error is the escalation, naming the files")
  has(res8 and res8.error, "git rebase origin/main", "error names the command")
  eq(tostring(res8 and res8.error):find("rebase failed", 1, true), nil,
    "error is not the bare rebase-failed text")
  eq(type(res8 and res8.conflict_hunks), "table", "conflict_hunks is returned")
  eq(res8 and res8.conflict_hunks and res8.conflict_hunks[1]
    and res8.conflict_hunks[1].file, "README.md", "the first hunk names its file")
  has(res8 and res8.conflict_hunks and res8.conflict_hunks[1]
    and res8.conflict_hunks[1].text or "", "<<<<<<<", "the hunk keeps the conflict markers")
  eq(type(res8 and res8.conflict_commit), "string", "conflict_commit is returned")
  eq(res8 and res8.upstream, "origin/main", "the conflict names the upstream base")
  eq(res8 and res8.rebase_command, "git rebase origin/main", "the conflict names the exact command")
  eq(res8 and res8.base, "main", "the conflict names the base")
  eq(res8 and res8.base_sha, conflict_main_sha, "the conflict carries the base SHA")
  eq(type(res8 and res8.escalation), "string", "an escalation message is produced")
  has(res8 and res8.escalation, "README.md", "the escalation names the files")
  has(res8 and res8.escalation, "origin/main", "the escalation names the base")
  has(res8 and res8.escalation, "git rebase origin/main", "the escalation names the command")
  has(res8 and res8.escalation, conflict_main_sha, "the escalation names the base SHA")
  has(res8 and res8.escalation, res8 and res8.conflict_commit or "", "the escalation names the commit")

  -- No `failed` write for a repairable conflict: the task stays in merge so the
  -- runtime can send it back to implement with the files in hand.
  local after8 = state.load(root).tasks[id8]
  eq(after8 and after8.status, "merging", "a conflicting rebase leaves the status merging")
  local failed_note8, conflict_note8, unrepaired_note8 = false, false, false
  for _, note in ipairs(after8 and after8.notes or {}) do
    if type(note) == "string" then
      if note:find("merge failed", 1, true) then failed_note8 = true end
      if note:find("merge conflict", 1, true) then conflict_note8 = true end
      if note:find("cannot be repaired automatically", 1, true) then
        unrepaired_note8 = true
      end
    end
  end
  eq(failed_note8, false, "a repairable conflict writes no failure note")
  eq(conflict_note8, true, "the conflict is journaled as a note")
  eq(unrepaired_note8, false,
    "a repairable conflict is not journaled as unrepairable")
  eq(read_log(), "", "a conflicting rebase does not touch the PR")

  -- run: every shape of a repairable conflict -------------------------------
  --
  -- `merge.rebase` can report the same conflict three ways: `conflict = true`
  -- (the classifier only knew it conflicted), `conflict` as the list of files,
  -- or `conflict_files` alone. The repair must not depend on a single field: a
  -- turn merge.lua journals as repairable can never be turned into `failed`
  -- here, so all three shapes return the conflict whole, leave the status
  -- merging and journal the repairable note.
  local shapes = {
    {
      name = "conflict = true",
      info = {
        conflict = true,
        hunks = {
          { file = "README.md", start = 1,
            text = "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> 59738f2" },
        },
        commit = "59738f2",
      },
    },
    {
      name = "conflict as a file list",
      info = { conflict = { "README.md", "shop.lua" } },
    },
    {
      name = "conflict_files alone",
      info = { conflict_files = "README.md, shop.lua" },
    },
  }
  local shape_seq = 0
  for _, shape in ipairs(shapes) do
    shape_seq = shape_seq + 1
    local sid = string.format("T-20261114-mgs%d", shape_seq)
    local stask = seed_task(sid, wt8)
    local rebase_calls = 0
    local stub = {
      fetch = function() return true end,
      rebase = function()
        rebase_calls = rebase_calls + 1
        return nil, "rebase failed (conflicts: README.md)", shape.info
      end,
      rev_parse = function() return "sha-shape" end,
    }
    maki.fs.write(log, "")
    local sres = merge.run({
      task = stask,
      repo = repo,
      worktree = wt8,
      root = root,
      git = stub,
      state = state,
      gh = gh,
      checks = checks,
      commands = { "true" },
      pr = 42,
      base = "main",
      remote = "origin",
    })
    eq(rebase_calls, 1, shape.name .. ": the merge rebases once")
    eq(sres and sres.ok, false, shape.name .. ": a conflict is not ok")
    eq(sres and sres.conflict, true, shape.name .. ": the result is flagged repairable")
    eq(type(sres and sres.conflict_file_list), "table",
      shape.name .. ": the file list is returned to the repair")
    has(tostring(sres and sres.conflict_files or ""), "README.md",
      shape.name .. ": conflict_files names the file")
    has(tostring(sres and sres.error or ""), "README.md",
      shape.name .. ": the error names the file")
    has(tostring(sres and sres.error or ""), "git rebase origin/main",
      shape.name .. ": the error names the exact command")
    has(tostring(sres and sres.escalation or ""), "README.md",
      shape.name .. ": the escalation names the file")
    local safter = state.load(root).tasks[sid]
    eq(safter and safter.status, "merging",
      shape.name .. ": a repairable conflict leaves the status merging")
    local repairable_note, failed_note = false, false
    for _, note in ipairs(safter and safter.notes or {}) do
      if type(note) == "string" then
        if note:find("will be redone on the fresh base", 1, true) then
          repairable_note = true
        end
        if note:find("merge failed", 1, true) then failed_note = true end
      end
    end
    eq(repairable_note, true,
      shape.name .. ": the conflict is journaled as repairable")
    eq(failed_note, false,
      shape.name .. ": a repairable conflict writes no failure note")
  end

  -- escalation: names what a human needs --------------------------------------

  local esc = merge.escalation({
    conflict = { "docs/configuration.md", "src/app.lua" },
    upstream = "origin/main",
    rebase_command = "git rebase origin/main",
    base_sha = "0123456789abcdef0123456789abcdef01234567",
    conflict_commit = "59738f2aa1b2c3d4e5f60718293a4b5c6d7e8f90",
  })
  has(esc, "docs/configuration.md", "escalation names the first file")
  has(esc, "src/app.lua", "escalation names the second file")
  has(esc, "origin/main", "escalation names the base")
  has(esc, "git rebase origin/main", "escalation names the command")
  has(esc, "0123456789abcdef0123456789abcdef01234567", "escalation names the base SHA")
  has(esc, "59738f2aa1b2c3d4e5f60718293a4b5c6d7e8f90", "escalation names the faulty commit")
  eq(esc:find("rebase failed", 1, true), nil, "escalation is not the bare rebase-failed text")

  -- The escalation names the files whatever shape carried them: a bare
  -- `conflict = true` reads them from the hunks, and `conflict_files` alone is
  -- accepted as well, so an escalation can never say "unknown" when git named
  -- the files.
  local esc_flag = merge.escalation({
    conflict = true,
    hunks = { { file = "docs/runbook.md", start = 4, text = "<<<<<<< HEAD" } },
    upstream = "origin/main",
    rebase_command = "git rebase origin/main",
    base_sha = "0123456789abcdef0123456789abcdef01234567",
  })
  has(esc_flag, "docs/runbook.md",
    "escalation reads the files from the hunks when conflict is a flag")
  has(esc_flag, "origin/main", "the flag escalation names the base")
  has(esc_flag, "git rebase origin/main", "the flag escalation names the command")

  local esc_files = merge.escalation({
    conflict_files = { "src/app.lua", "src/db.lua" },
    upstream = "origin/main",
    rebase_command = "git rebase origin/main",
  })
  has(esc_files, "src/app.lua", "conflict_files alone names the first file")
  has(esc_files, "src/db.lua", "conflict_files alone names the second file")
  has(esc_files, "origin/main", "conflict_files alone names the base")
  has(esc_files, "git rebase origin/main", "conflict_files alone names the command")

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
