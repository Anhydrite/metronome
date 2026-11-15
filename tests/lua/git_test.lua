-- Tests for maki/lua/metronome/git.lua (REQ-20261114-19).
--
-- These run real git against a throwaway repository with a bare remote, so the
-- command shapes are proven, not assumed. Everything lives under a temp dir
-- that is removed at the end.

return function()
  local git = load_module("git")
  local state = load_module("state")
  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "git")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local repo = maki.fs.joinpath(base, "repo")
  local remote = maki.fs.joinpath(base, "remote.git")
  local worktree = maki.fs.joinpath(base, "wt")

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  -- A bare remote and a working repo that pushes to it.
  local code, out = sh({ "git", "init", "--bare", "-b", "main", remote })
  eq(code, 0, "bare remote created: " .. out:sub(1, 80))

  maki.fs.mkdir(repo, { parents = true })
  code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "repo created")
  sh({ "git", "config", "user.email", "test@example.com" }, repo)
  sh({ "git", "config", "user.name", "Test" }, repo)
  sh({ "git", "remote", "add", "origin", remote }, repo)
  maki.fs.write(maki.fs.joinpath(repo, "README.md"), "# throwaway\n")
  code, out = sh({ "git", "add", "-A" }, repo)
  eq(code, 0, "initial add")
  code, out = sh({ "git", "commit", "-m", "chore: init" }, repo)
  eq(code, 0, "initial commit")
  code, out = sh({ "git", "push", "-u", "origin", "main" }, repo)
  eq(code, 0, "initial push: " .. out:sub(1, 80))

  -- Repository checks -------------------------------------------------------

  local is, ierr = git.is_repo(repo)
  eq(is, true, "repo is recognised")
  eq(ierr, nil, "no error for a real repo")

  local not_repo, nerr = git.is_repo(base)
  eq(not_repo, false, "a plain directory is not a repo")
  eq(nerr ~= nil, true, "not-a-repo explains itself")

  local branch, berr = git.current_branch(repo)
  eq(berr, nil, "current_branch has no error")
  eq(branch, "main", "current branch is main")

  -- Branch naming -----------------------------------------------------------

  eq(git.branch_name("metronome/", "T-20261114-a3f2"), "metronome/T-20261114-a3f2", "branch name composed")
  eq(git.branch_name(nil, "T-20261114-a3f2"), "metronome/T-20261114-a3f2", "default prefix applied")

  -- Conventional messages ---------------------------------------------------

  eq(git.conventional("feat", "export", "add CSV export"), "feat(export): add CSV export", "scoped message")
  eq(git.conventional("fix", nil, "stop the leak"), "fix: stop the leak", "unscoped message")
  eq(git.conventional("feat", "export", "add CSV export", "Because finance asked."),
    "feat(export): add CSV export\n\nBecause finance asked.", "message with body")
  local empty, eerr = git.conventional("feat", nil, "   ")
  eq(empty, nil, "empty subject refused")
  eq(eerr ~= nil, true, "empty subject explains itself")

  -- Fetch -------------------------------------------------------------------

  local fetched, ferr = git.fetch(repo, "origin")
  eq(fetched, true, "fetch works")
  eq(ferr, nil, "fetch has no error")

  -- Worktree ----------------------------------------------------------------

  local wt, werr = git.worktree_add(repo, worktree, "metronome/T-20261114-a3f2", "main", { remote = "origin" })
  eq(werr, nil, "worktree add has no error: " .. tostring(werr))
  eq(wt, worktree, "worktree path returned")

  local listed, lerr = git.worktree_list(repo)
  eq(lerr, nil, "worktree list has no error")
  local found = false
  for _, p in ipairs(listed) do
    if p == worktree then found = true end
  end
  eq(found, true, "new worktree is listed")

  local wt_branch = git.current_branch(worktree)
  eq(wt_branch, "metronome/T-20261114-a3f2", "worktree is on the task branch")

  -- A duplicate worktree must fail with a readable message, not crash.
  local dup, derr = git.worktree_add(repo, worktree, "metronome/T-20261114-a3f2", "main")
  eq(dup, nil, "duplicate worktree refused")
  eq(derr ~= nil and derr:find("worktree add failed") ~= nil, true, "duplicate worktree explains itself")

  -- Commit ------------------------------------------------------------------

  maki.fs.write(maki.fs.joinpath(worktree, "export.csv"), "a,b\n1,2\n")
  local sha, serr = git.commit(worktree, git.conventional("feat", "export", "add CSV export"))
  eq(serr, nil, "commit has no error: " .. tostring(serr))
  eq(type(sha), "string", "commit returns a sha")
  eq(#sha, 40, "sha is full length")

  local head = git.head_sha(worktree)
  eq(head, sha, "head matches the commit")

  -- An empty commit is reported as such, not as a crash.
  local nothing, nerr2 = git.commit(worktree, "feat: nothing")
  eq(nothing, nil, "empty commit returns nil")
  eq(nerr2, "nothing to commit", "empty commit says so plainly")

  -- Reset hard (REQ-20261114-28) --------------------------------------------
  --
  -- Going back to the last checkpoint must restore both the commit and the
  -- files: a reset that only moved HEAD would leave the failed turn's edits.

  local sha_a = sha
  maki.fs.write(maki.fs.joinpath(worktree, "export.csv"), "a,b\n3,4\n")
  local sha_b, berr2 = git.commit(worktree, "feat: second export")
  eq(berr2, nil, "second commit has no error: " .. tostring(berr2))
  eq(type(sha_b), "string", "second commit returns a sha")
  eq(sha_b ~= sha_a, true, "second commit is a new commit")

  local reset_sha, rserr = git.reset_hard(worktree, sha_a)
  eq(rserr, nil, "reset_hard has no error: " .. tostring(rserr))
  eq(reset_sha, sha_a, "reset_hard returns the target sha")
  eq(git.head_sha(worktree), sha_a, "HEAD is back at A")
  eq(maki.fs.read(maki.fs.joinpath(worktree, "export.csv")), "a,b\n1,2\n", "file content is back to A")

  local bad_reset, brserr = git.reset_hard(worktree, "not-a-sha")
  eq(bad_reset, nil, "invalid sha refused")
  eq(brserr, "reset needs a commit sha", "invalid sha says so plainly")

  -- Changed files -----------------------------------------------------------

  local files, cferr = git.changed_files(worktree, "origin/main")
  eq(cferr, nil, "changed_files has no error")
  local saw_file = false
  for _, f in ipairs(files) do
    if f == "export.csv" then saw_file = true end
  end
  eq(saw_file, true, "changed file is reported")

  -- Three-dot range (REQ-20261114-29) ----------------------------------------
  --
  -- `main...HEAD` compares the merge base to the branch head, so a commit made
  -- on main after the branch was cut is not reported as a branch change. The
  -- two-dot form compares main's tree to the working tree and does report it,
  -- which is exactly why convergence asks for the three-dot range.

  maki.fs.write(maki.fs.joinpath(repo, "main-only.txt"), "main\n")
  sh({ "git", "add", "-A" }, repo)
  local mcode, mout = sh({ "git", "commit", "-m", "chore: main moves on" }, repo)
  eq(mcode, 0, "main advanced: " .. mout:sub(1, 80))

  local two_dot, td_err = git.changed_files(worktree, "main")
  eq(td_err, nil, "two-dot changed_files has no error")
  local two_saw_main = false
  for _, f in ipairs(two_dot or {}) do
    if f == "main-only.txt" then two_saw_main = true end
  end
  eq(two_saw_main, true, "two-dot sees main's later change as a difference")

  local three_dot, th_err = git.changed_files(worktree, "main", { three_dot = true })
  eq(th_err, nil, "three-dot changed_files has no error")
  local three_saw_export, three_saw_main = false, false
  for _, f in ipairs(three_dot or {}) do
    if f == "export.csv" then three_saw_export = true end
    if f == "main-only.txt" then three_saw_main = true end
  end
  eq(three_saw_export, true, "three-dot sees the branch change")
  eq(three_saw_main, false, "three-dot ignores main's later change")

  -- Push --------------------------------------------------------------------

  local pushed, perr = git.push(worktree, "metronome/T-20261114-a3f2", { remote = "origin" })
  eq(pushed, true, "push works: " .. tostring(perr))
  eq(perr, nil, "push has no error")

  local code2, out2 = sh({ "git", "-C", remote, "rev-parse", "--verify", "metronome/T-20261114-a3f2" }, base)
  eq(code2, 0, "branch exists on the remote: " .. out2:sub(1, 80))

  -- Git failure diagnostics (REQ-20261114-20) -------------------------------
  --
  -- Each of the four real failures must produce a readable diagnostic AND leave
  -- the task failed with the reason in its journal notes. Both halves are proven
  -- here: a diagnostic nobody records is just a log line.

  local stroot = maki.fs.joinpath(base, "state")

  local function assert_diag(diag, cause, label)
    eq(type(diag), "table", label .. ": diagnostic returned")
    eq(diag and diag.cause, cause, label .. ": cause is " .. cause)
    eq(type(diag and diag.message) == "string" and #diag.message > 0, true, label .. ": message non-empty")
    eq(type(diag and diag.hint) == "string" and #diag.hint > 0, true, label .. ": hint non-empty")
    eq(type(diag and diag.detail) == "string" and #diag.detail > 0, true, label .. ": detail non-empty")
    eq(type(diag and diag.command) == "string" and #diag.command > 0, true, label .. ": command recorded")
    local line = git.describe(diag)
    eq(type(line), "string", label .. ": describe returns a line")
    has(line, cause, label .. ": describe names the cause")
    has(line, diag.message, label .. ": describe carries the message")
  end

  local function prove_failed(id, diag, label)
    local created, cerr = state.create(stroot, { id = id, title = "git failure " .. id, status = "running" })
    eq(cerr, nil, label .. ": running task created")
    eq(created and created.status, "running", label .. ": task starts running")
    local task, terr = git.fail_task(state, stroot, id, diag)
    eq(terr, nil, label .. ": fail_task has no error: " .. tostring(terr))
    eq(task and task.status, "failed", label .. ": task is failed")
    local loaded = state.load(stroot)
    local notes = loaded.tasks[id] and loaded.tasks[id].notes or {}
    local found = false
    for _, note in ipairs(notes) do
      if type(note) == "string" and note:find(diag.cause, 1, true) then
        found = true
      end
    end
    eq(found, true, label .. ": journal note records the failure")
  end

  -- (a) The worktree path is already present.
  local wt_dup, wt_err, wt_diag = git.worktree_add(repo, worktree, "metronome/other", "main")
  eq(wt_dup, nil, "existing worktree path refused")
  eq(type(wt_err), "string", "existing worktree path explains itself")
  assert_diag(wt_diag, "worktree_exists", "worktree_exists")
  prove_failed("T-20261114-b001", wt_diag, "worktree_exists")

  -- (b) The task branch already exists.
  local bcode, bout = sh({ "git", "branch", "metronome/dup", "main" }, repo)
  eq(bcode, 0, "duplicate branch seeded: " .. bout:sub(1, 80))
  local br_path = maki.fs.joinpath(base, "wt-dup")
  local br_dup, br_err, br_diag = git.worktree_add(repo, br_path, "metronome/dup", "main")
  eq(br_dup, nil, "existing branch refused")
  eq(type(br_err), "string", "existing branch explains itself")
  assert_diag(br_diag, "branch_exists", "branch_exists")
  prove_failed("T-20261114-b002", br_diag, "branch_exists")

  -- `existing` checks out the branch that already exists instead of creating
  -- it: that is how a task re-attaches its worktree after one was removed.
  local ex_wt, ex_err = git.worktree_add(repo, br_path, "metronome/dup", "main", { existing = true })
  eq(ex_err, nil, "existing branch checked out: " .. tostring(ex_err))
  eq(ex_wt, br_path, "existing worktree path returned")
  eq(git.current_branch(br_path), "metronome/dup", "existing worktree is on the existing branch")

  -- (c) The remote has a commit the task branch does not: the push is rejected.
  local rcode, rout = sh({ "git", "checkout", "-q", "-b", "metronome/rejected", "main" }, repo)
  eq(rcode, 0, "rejected branch seeded: " .. rout:sub(1, 80))
  maki.fs.write(maki.fs.joinpath(repo, "remote-only.txt"), "remote\n")
  sh({ "git", "add", "-A" }, repo)
  local rccode, rcout = sh({ "git", "commit", "-m", "feat: remote only" }, repo)
  eq(rccode, 0, "remote-only commit: " .. rcout:sub(1, 80))
  local rpcode, rpout = sh({ "git", "push", "origin", "metronome/rejected" }, repo)
  eq(rpcode, 0, "remote-only push: " .. rpout:sub(1, 80))
  sh({ "git", "checkout", "-q", "main" }, repo)
  local dcode, dout = sh({ "git", "branch", "-D", "metronome/rejected" }, repo)
  eq(dcode, 0, "local seeded branch removed: " .. dout:sub(1, 80))

  local wcode, wout = sh({ "git", "checkout", "-q", "-b", "metronome/rejected", "main" }, worktree)
  eq(wcode, 0, "worktree branch cut from stale main: " .. wout:sub(1, 80))
  maki.fs.write(maki.fs.joinpath(worktree, "local-only.txt"), "local\n")
  local lsha, lserr = git.commit(worktree, "feat: local only")
  eq(lserr, nil, "local-only commit: " .. tostring(lserr))
  eq(type(lsha), "string", "local-only commit returns a sha")
  local rej, rej_err, rej_diag = git.push(worktree, "metronome/rejected")
  eq(rej, nil, "diverged push refused")
  eq(type(rej_err), "string", "diverged push explains itself")
  assert_diag(rej_diag, "push_rejected", "push_rejected")
  prove_failed("T-20261114-b003", rej_diag, "push_rejected")
  -- The refusal names the reason, not only git's "To <url>" preamble.
  has(rej_err or "", "rejected", "the push refusal reports why")
  eq((rej_err or ""):find("^To ", 1) ~= nil, false, "the refusal is not git's preamble")

  -- The pipeline rewrites its own branches (rebase onto the fresh base,
  -- rollback to a checkpoint), so a task branch is pushed with a lease: the
  -- same diverged push succeeds, and the remote now holds the local commit.
  local forced, forced_err = git.push(worktree, "metronome/rejected", { force = true })
  eq(forced, true, "a leased push replaces a rewritten branch: " .. tostring(forced_err))
  local remote_sha_code, remote_sha = sh({ "git", "-C", remote, "rev-parse", "metronome/rejected" })
  eq(remote_sha_code, 0, "remote branch readable")
  eq((remote_sha:gsub("%s+$", "")), lsha, "the remote branch holds the rewritten commit")

  -- (d) The remote does not exist.
  local fetched_missing, fm_err, fm_diag = git.fetch(repo, "nope")
  eq(fetched_missing, nil, "missing remote refused")
  eq(type(fm_err), "string", "missing remote explains itself")
  assert_diag(fm_diag, "remote_missing", "remote_missing")
  prove_failed("T-20261114-b004", fm_diag, "remote_missing")

  -- Rebase and detached worktrees (REQ-20261114-31) --------------------------
  --
  -- A task branch is rebased onto the fresh base before the PR is merged, and
  -- the post-merge checks run in a detached worktree cut from that base. Both
  -- shapes are proven here, including the conflict path, which must leave the
  -- worktree clean and the branch head untouched.

  local mcode3, mout3 = sh({ "git", "push", "origin", "main" }, repo)
  eq(mcode3, 0, "main pushed before the rebase tests: " .. mout3:sub(1, 80))

  local rebase_wt = maki.fs.joinpath(base, "wt-rebase")
  local rebase_branch = "metronome/T-20261114-r001"
  local rwt, rwerr = git.worktree_add(repo, rebase_wt, rebase_branch, "main", { remote = "origin" })
  eq(rwerr, nil, "rebase worktree created: " .. tostring(rwerr))
  eq(rwt, rebase_wt, "rebase worktree path returned")

  maki.fs.write(maki.fs.joinpath(rebase_wt, "branch.txt"), "branch\n")
  local rsha, rserr = git.commit(rebase_wt, "feat: branch work")
  eq(rserr, nil, "rebase branch commit: " .. tostring(rserr))
  eq(type(rsha), "string", "rebase branch commit returns a sha")

  -- main advances on the remote after the branch was cut.
  maki.fs.write(maki.fs.joinpath(repo, "later.txt"), "later\n")
  sh({ "git", "add", "-A" }, repo)
  local lcode, lout = sh({ "git", "commit", "-m", "chore: main later" }, repo)
  eq(lcode, 0, "main advanced for rebase: " .. lout:sub(1, 80))
  local lpcode, lpout = sh({ "git", "push", "origin", "main" }, repo)
  eq(lpcode, 0, "main pushed for rebase: " .. lpout:sub(1, 80))
  local ms_code, ms_out = sh({ "git", "-C", repo, "rev-parse", "HEAD" })
  eq(ms_code, 0, "main sha read for rebase: " .. ms_out:sub(1, 80))
  local main_sha = (ms_out:gsub("%s+$", ""))

  local fetched3, ferr3 = git.fetch(repo, "origin")
  eq(fetched3, true, "fetch before rebase: " .. tostring(ferr3))

  local rebased, rberr = git.rebase(rebase_wt, "origin/main")
  eq(rberr, nil, "rebase has no error: " .. tostring(rberr))
  eq(type(rebased), "string", "rebase returns the new head")
  eq(#rebased, 40, "rebased head is full length")
  eq(rebased ~= rsha, true, "rebase rewrote the branch head")

  local anc_code, anc_out = sh({ "git", "-C", rebase_wt, "merge-base", "--is-ancestor", main_sha, "HEAD" })
  eq(anc_code, 0, "the base commit is in the branch history: " .. anc_out:sub(1, 80))

  -- A conflicting rebase is refused, aborted, and leaves the tree clean.
  local conflict_wt = maki.fs.joinpath(base, "wt-conflict")
  local conflict_branch = "metronome/T-20261114-r002"
  local cwt, cwerr = git.worktree_add(repo, conflict_wt, conflict_branch, "main", { remote = "origin" })
  eq(cwerr, nil, "conflict worktree created: " .. tostring(cwerr))

  maki.fs.write(maki.fs.joinpath(conflict_wt, "README.md"), "# branch edit\n")
  local ccsha, ccserr = git.commit(conflict_wt, "feat: branch edit")
  eq(ccserr, nil, "conflict branch commit: " .. tostring(ccserr))
  eq(type(ccsha), "string", "conflict branch commit returns a sha")

  maki.fs.write(maki.fs.joinpath(repo, "README.md"), "# main edit\n")
  sh({ "git", "add", "-A" }, repo)
  local ccode, cout = sh({ "git", "commit", "-m", "chore: main edit" }, repo)
  eq(ccode, 0, "main edited for the conflict: " .. cout:sub(1, 80))
  local cpcode, cpout = sh({ "git", "push", "origin", "main" }, repo)
  eq(cpcode, 0, "main pushed for the conflict: " .. cpout:sub(1, 80))
  git.fetch(repo, "origin")

  local before_conflict = git.head_sha(conflict_wt)
  local conf, conferr = git.rebase(conflict_wt, "origin/main")
  eq(conf, nil, "conflicting rebase refused")
  eq(type(conferr), "string", "conflict explains itself")
  has(conferr, "conflict", "conflict message names the conflict")
  has(conferr, "README.md", "conflict message names the file")

  local st_code, st_out = sh({ "git", "-C", conflict_wt, "status", "--porcelain" })
  eq(st_code, 0, "status ran after the abort")
  eq((st_out:gsub("%s+$", "")), "", "worktree is clean after the abort")
  eq(git.head_sha(conflict_wt), before_conflict, "branch head unchanged after the abort")

  -- A detached worktree has no branch: that is what the post-merge checks need.
  local detach_wt = maki.fs.joinpath(base, "wt-detach")
  local dwt, dwerr = git.worktree_add(repo, detach_wt, nil, "origin/main", { detach = true })
  eq(dwerr, nil, "detached worktree created: " .. tostring(dwerr))
  eq(dwt, detach_wt, "detached worktree path returned")
  eq(git.current_branch(detach_wt), "HEAD", "detached worktree has no branch")

  -- ls_tree / show_file: the qualifier reads the committed tree -------------
  --
  -- The qualifier must describe `origin/<base>`, not whatever the local
  -- checkout holds. These two read git, so a dirty working tree cannot leak
  -- into a task sheet.

  maki.fs.mkdir(maki.fs.joinpath(repo, "src"), { parents = true })
  maki.fs.write(maki.fs.joinpath(repo, "src", "lib.js"), "module.exports = 1\n")
  sh({ "git", "add", "-A" }, repo)
  code, out = sh({ "git", "commit", "-m", "feat: add lib" }, repo)
  eq(code, 0, "lib committed: " .. out:sub(1, 80))
  code, out = sh({ "git", "push", "origin", "main" }, repo)
  eq(code, 0, "lib pushed: " .. out:sub(1, 80))

  local tree, terr = git.ls_tree(repo, "origin/main")
  eq(terr, nil, "ls_tree has no error: " .. tostring(terr))
  local in_tree = {}
  for _, path in ipairs(tree or {}) do
    in_tree[path] = true
  end
  eq(in_tree["README.md"], true, "ls_tree lists a committed file")
  eq(in_tree["src/lib.js"], true, "ls_tree lists a nested committed file")

  -- A dirty working tree must not change what the ref says.
  maki.fs.write(maki.fs.joinpath(repo, "src", "lib.js"), "module.exports = 2\n")
  maki.fs.write(maki.fs.joinpath(repo, "uncommitted.js"), "nope\n")
  local dirty_tree = git.ls_tree(repo, "origin/main")
  local dirty = {}
  for _, path in ipairs(dirty_tree or {}) do
    dirty[path] = true
  end
  eq(dirty["uncommitted.js"], nil, "ls_tree ignores an uncommitted file")

  local text, serr = git.show_file(repo, "origin/main", "src/lib.js")
  eq(serr, nil, "show_file has no error: " .. tostring(serr))
  eq(text, "module.exports = 1", "show_file returns the committed content, not the dirty one")

  local missing_text, missing_err = git.show_file(repo, "origin/main", "does/not/exist.js")
  eq(missing_text, nil, "show_file refuses a missing path")
  has(missing_err or "", "does/not/exist.js", "the refusal names the path")

  local bad_ref, bad_ref_err = git.ls_tree(repo, "origin/no-such-branch")
  eq(bad_ref, nil, "ls_tree refuses an unknown ref")
  eq(type(bad_ref_err), "string", "ls_tree explains an unknown ref")

  local no_ref, no_ref_err = git.ls_tree(repo, "")
  eq(no_ref, nil, "ls_tree needs a ref")
  eq(type(no_ref_err), "string", "ls_tree says a ref is missing")

  -- Restore the working tree so the rest of the suite is unaffected.
  sh({ "git", "checkout", "--", "src/lib.js" }, repo)
  maki.fs.rm(maki.fs.joinpath(repo, "uncommitted.js"))

  -- Cleanup -----------------------------------------------------------------

  local removed, rerr = git.worktree_remove(repo, worktree, { force = true })
  eq(removed, true, "worktree removed: " .. tostring(rerr))

  local removed_rb, rerr_rb = git.worktree_remove(repo, rebase_wt, { force = true })
  eq(removed_rb, true, "rebase worktree removed: " .. tostring(rerr_rb))
  local removed_cf, rerr_cf = git.worktree_remove(repo, conflict_wt, { force = true })
  eq(removed_cf, true, "conflict worktree removed: " .. tostring(rerr_cf))
  local removed_dt, rerr_dt = git.worktree_remove(repo, detach_wt, { force = true })
  eq(removed_dt, true, "detached worktree removed: " .. tostring(rerr_dt))

  maki.fs.rm(base, { recursive = true })
end
