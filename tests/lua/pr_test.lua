-- Tests for the pull request helpers in maki/lua/metronome/git.lua
-- (REQ-20261114-21).
--
-- No real GitHub is involved: `gh` is a shell script written into a temp dir
-- that logs its argv and answers per mode. That proves the exact command shape
-- the pipeline sends, which is the part a real `gh` would never let us assert.

return function()
  local git = load_module("git")
  local state = load_module("state")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "pr")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local scripts = maki.fs.joinpath(base, "bin")
  maki.fs.mkdir(scripts, { parents = true })
  local log = maki.fs.joinpath(base, "gh.log")
  maki.fs.write(log, "")

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  local function read_log()
    return maki.fs.read(log) or ""
  end

  -- The log path is baked into the script body, so every fake `gh` records the
  -- argv it was handed without the caller having to pass it.
  local log_quoted = "'" .. log:gsub("'", "'\\''") .. "'"

  local function fake_gh(name, body)
    local path = maki.fs.joinpath(scripts, name)
    maki.fs.write(path, "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> " .. log_quoted .. "\n" .. body .. "\n")
    local code, out = sh({ "chmod", "+x", path })
    eq(code, 0, name .. " is executable: " .. out:sub(1, 80))
    return path
  end

  local ok_gh = fake_gh("gh-ok", [[
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/example/repo/pull/42"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN"}'
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])

  -- `pr create` refuses because a PR already exists; `pr view` finds it. The
  -- PR number is deliberately different from the happy-path one so a test
  -- cannot pass by accidentally reusing ok_gh's answer.
  local exists_gh = fake_gh("gh-exists", [[
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"number":7,"url":"https://github.com/example/repo/pull/7","state":"OPEN"}'
  exit 0
fi
echo 'a pull request for branch "metronome/x" already exists' >&2
exit 1
]])

  -- Same refusal, but no PR can be found afterwards: this must stay an error.
  local exists_noview_gh = fake_gh("gh-exists-noview", [[
echo 'a pull request for branch "metronome/x" already exists' >&2
exit 1
]])

  local badjson_gh = fake_gh("gh-badjson", [[
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo 'not json'
  exit 0
fi
exit 2
]])

  local nocreate_gh = fake_gh("gh-nocreate", [[
echo 'boom' >&2
exit 1
]])

  -- normalize_pr ------------------------------------------------------------

  local n0, n0err = git.normalize_pr({ number = 0, url = "https://x/1", state = "open" })
  eq(n0, nil, "number 0 refused")
  eq(type(n0err), "string", "number 0 explains itself")

  local nf, nferr = git.normalize_pr({ number = 1.5, url = "https://x/1" })
  eq(nf, nil, "fractional number refused")
  eq(type(nferr), "string", "fractional number explains itself")

  local nu, nuerr = git.normalize_pr({ number = 1, url = "ftp://x/1" })
  eq(nu, nil, "non-http url refused")
  eq(type(nuerr), "string", "non-http url explains itself")

  local ns, nserr = git.normalize_pr({ number = 1, url = "https://x/1", state = "weird" })
  eq(ns, nil, "unknown state refused")
  eq(type(nserr), "string", "unknown state explains itself")

  local nm, nmerr = git.normalize_pr({ number = 42, url = "https://github.com/example/repo/pull/42", state = "MERGED" })
  eq(nmerr, nil, "uppercase state accepted: " .. tostring(nmerr))
  eq(nm and nm.state, "merged", "gh MERGED is lowercased")
  eq(nm and nm.number, 42, "number kept as integer")
  eq(nm and nm.url, "https://github.com/example/repo/pull/42", "url kept")

  local nraw, nrawerr = git.normalize_pr("nope")
  eq(nraw, nil, "non-table refused")
  eq(type(nrawerr), "string", "non-table explains itself")

  -- pr_create with the happy path -------------------------------------------

  local pr, perr = git.pr_create({
    title = "feat: add export",
    body = "because finance",
    base = "main",
    head = "metronome/T-20261114-c001",
    worktree = base,
    gh = ok_gh,
  })
  eq(perr, nil, "pr_create has no error: " .. tostring(perr))
  eq(pr and pr.number, 42, "pr_create returns the PR number")
  eq(pr and pr.url, "https://github.com/example/repo/pull/42", "pr_create returns the PR url")
  eq(pr and pr.state, "open", "pr_create lowercases the state")

  local logtext = read_log()
  has(logtext, "pr create --base main --head metronome/T-20261114-c001 --title feat: add export --body because finance",
    "argv carries base, head, title and body in order")
  has(logtext, "pr view https://github.com/example/repo/pull/42 --json number,url,state",
    "pr_create re-reads the PR with gh pr view")
  eq(select(2, logtext:gsub("\n", "\n")), 2, "exactly two gh calls were made")

  -- pr_close: a failed task must not leave an open PR behind ---------------
  local close_gh = fake_gh("gh-close", [[
if [ "$1" = "pr" ] && [ "$2" = "close" ]; then exit 0; fi
exit 1
]])
  local closed, cerr = git.pr_close(42, { gh = close_gh, worktree = base })
  eq(cerr, nil, "pr_close has no error: " .. tostring(cerr))
  eq(closed and closed.closed, true, "pr_close reports the PR closed")
  has(read_log(), "pr close 42", "pr_close sends gh pr close with the number")

  local already_gh = fake_gh("gh-already-closed", [[
echo "pull request 42 is already closed" >&2
exit 1
]])
  local already = git.pr_close(42, { gh = already_gh, worktree = base })
  eq(already and already.already, true, "an already closed PR is not a failure")

  local no_ref, no_ref_err = git.pr_close(nil, { gh = close_gh })
  eq(no_ref, nil, "pr_close refuses without a reference")
  eq(type(no_ref_err), "string", "the refusal explains itself")

  -- An empty title must be refused before anything runs.
  local before = read_log()
  local empty, eerr = git.pr_create({ title = "   ", worktree = base, gh = ok_gh })
  eq(empty, nil, "empty title refused")
  eq(eerr, "PR title is empty", "empty title says so plainly")
  eq(read_log(), before, "empty title runs no command")

  -- pr_attach ---------------------------------------------------------------

  local root = maki.fs.joinpath(base, "state")
  local created, cerr = state.create(root, { id = "T-20261114-c001", title = "pr", status = "reviewing" })
  eq(cerr, nil, "task created: " .. tostring(cerr))
  eq(created and created.status, "reviewing", "task starts reviewing")

  local attached, aerr = git.pr_attach(state, root, "T-20261114-c001", pr)
  eq(aerr, nil, "pr_attach has no error: " .. tostring(aerr))
  eq(attached and attached.pr and attached.pr.number, 42, "attach returns the task with its PR")

  local loaded = state.load(root)
  local stored = loaded.tasks["T-20261114-c001"] and loaded.tasks["T-20261114-c001"].pr
  eq(stored and stored.number, 42, "PR number is stored on the task")
  eq(stored and stored.url, "https://github.com/example/repo/pull/42", "PR url is stored on the task")
  eq(stored and stored.state, "open", "PR state is stored on the task")

  -- The projection is only a cache: drop it and replay the journal.
  maki.fs.rm(state.paths(root).projection)
  local replayed = state.load(root)
  local survived = replayed.tasks["T-20261114-c001"] and replayed.tasks["T-20261114-c001"].pr
  eq(survived and survived.number, 42, "PR survives a journal replay")
  eq(survived and survived.state, "open", "PR state survives a journal replay")

  -- pr_open -----------------------------------------------------------------

  local created2, cerr2 = state.create(root, { id = "T-20261114-c002", title = "pr open", status = "reviewing" })
  eq(cerr2, nil, "second task created: " .. tostring(cerr2))

  local opened, oerr = git.pr_open(state, root, "T-20261114-c002", {
    title = "feat: add export",
    body = "because finance",
    base = "main",
    head = "metronome/T-20261114-c002",
    worktree = base,
    gh = ok_gh,
  })
  eq(oerr, nil, "pr_open has no error: " .. tostring(oerr))
  eq(opened and opened.number, 42, "pr_open returns the PR")

  local opened_task = state.load(root).tasks["T-20261114-c002"]
  eq(opened_task and opened_task.pr and opened_task.pr.number, 42, "pr_open stores the PR on the task")
  eq(opened_task and opened_task.pr and opened_task.pr.state, "open", "pr_open stores the state")

  -- Failures ----------------------------------------------------------------

  local exists, xerr = git.pr_create({
    title = "feat: add export",
    worktree = base,
    base = "main",
    head = "metronome/T-20261114-c001",
    gh = exists_gh,
  })
  eq(xerr, nil, "an existing PR is not an error: " .. tostring(xerr))
  eq(exists and exists.number, 7, "existing PR number returned")
  eq(exists and exists.url, "https://github.com/example/repo/pull/7", "existing PR url returned")
  eq(exists and exists.state, "open", "existing PR state returned")

  has(read_log(), "pr view metronome/T-20261114-c001 --json number,url,state",
    "the existing PR is looked up by the head branch")

  -- The refusal is still classified as pr_exists: it is the signal that makes
  -- pr_create look the PR up instead of failing.
  local xdiag = git.classify("gh pr create", {
    code = 1,
    stderr = 'a pull request for branch "metronome/x" already exists',
  })
  eq(xdiag and xdiag.cause, "pr_exists", "existing PR is classified pr_exists")
  eq(xdiag and xdiag.hint, "reuse the existing PR or push to a new branch", "pr_exists hint")

  -- pr_open attaches the existing PR and moves on, instead of aborting.
  local created3, cerr3 = state.create(root, { id = "T-20261114-c003", title = "existing pr", status = "reviewing" })
  eq(cerr3, nil, "third task created: " .. tostring(cerr3))

  local reopened, rerr = git.pr_open(state, root, "T-20261114-c003", {
    title = "feat: add export",
    worktree = base,
    base = "main",
    head = "metronome/T-20261114-c001",
    gh = exists_gh,
  })
  eq(rerr, nil, "pr_open with an existing PR has no error: " .. tostring(rerr))
  eq(reopened and reopened.number, 7, "pr_open returns the existing PR")
  local reopened_task = state.load(root).tasks["T-20261114-c003"]
  eq(reopened_task and reopened_task.pr and reopened_task.pr.number, 7, "pr_open stores the existing PR")
  eq(reopened_task and reopened_task.status, "pr_open", "pr_open moves the task on")

  -- pr_exists but nothing to look up: still an error, never a nil success.
  local nofind, nferr = git.pr_create({
    title = "feat: add export",
    worktree = base,
    base = "main",
    head = "metronome/T-20261114-c001",
    gh = exists_noview_gh,
  })
  eq(nofind, nil, "pr_exists with no retrievable PR is still an error")
  eq(type(nferr), "string", "the failed lookup explains itself")

  local badjson, berr = git.pr_view("42", { gh = badjson_gh, worktree = base })
  eq(badjson, nil, "invalid JSON refused")
  eq(type(berr), "string", "invalid JSON explains itself")
  has(berr, "invalid JSON", "invalid JSON message is explicit")

  local generic, gerr, gdiag = git.pr_create({ title = "feat: add export", worktree = base, gh = nocreate_gh })
  eq(generic, nil, "generic gh failure refused")
  eq(type(gerr), "string", "generic gh failure explains itself")
  has(gerr, "gh pr create failed", "generic gh failure names the command")
  eq(gdiag and gdiag.cause, "git_error", "generic gh failure falls back to git_error")

  local unknown, uerr = git.pr_attach(state, root, "T-20261114-nope", pr)
  eq(unknown, nil, "unknown task refused")
  eq(type(uerr), "string", "unknown task explains itself")
  has(uerr, "unknown task", "unknown task is named")

  maki.fs.rm(base, { recursive = true })
end
