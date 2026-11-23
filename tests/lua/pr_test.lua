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

  -- pr_close is for an explicitly abandoned or deleted task only: a failed task
  -- is retryable and keeps its open PR for the retry to update ---------------
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

  -- pr_comment: findings are mirrored on the PR -----------------------------
  local comment_gh = fake_gh("gh-comment", [[
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  echo "commented"
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])
  maki.fs.write(log, "")
  local commented, comerr = git.pr_comment(42, "## review\n- **blocking** — nope", { gh = comment_gh, worktree = base })
  eq(comerr, nil, "pr_comment has no error: " .. tostring(comerr))
  eq(commented and commented.commented, true, "pr_comment reports the comment")
  has(read_log(), "pr comment 42 --body ## review", "pr_comment sends gh pr comment with the body")
  local no_body, no_body_err = git.pr_comment(42, "   ", { gh = comment_gh })
  eq(no_body, nil, "pr_comment refuses an empty body")
  has(tostring(no_body_err), "non-empty body", "pr_comment names the empty body")
  local no_pr, no_pr_err = git.pr_comment(nil, "hi", { gh = comment_gh })
  eq(no_pr, nil, "pr_comment refuses without a reference")
  has(tostring(no_pr_err), "pull request", "pr_comment names the missing reference")
  local fail_gh = fake_gh("gh-comment-fail", [[
echo "boom" >&2
exit 1
]])
  local failed, ferr = git.pr_comment(42, "hi", { gh = fail_gh, worktree = base })
  eq(failed, nil, "pr_comment reports a non-zero gh")
  has(tostring(ferr), "gh pr comment failed", "pr_comment names the command")
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

  -- pr_open reuses the open PR a retry finds on the task ---------------------
  --
  -- A failed task keeps its PR through prune, so the retry must update that PR
  -- rather than close it and open a second one. Reuse re-reads the PR first,
  -- so this fake `gh` answers the view with the preserved PR; any close or
  -- create is logged and asserted absent.
  local reuse_gh = fake_gh("gh-reuse", [[
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "54" ]; then
  echo '{"number":54,"url":"https://github.com/example/repo/pull/54","state":"OPEN"}'
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])

  local created4, cerr4 = state.create(root, { id = "T-20261114-c004", title = "retry", status = "reviewing" })
  eq(cerr4, nil, "fourth task created: " .. tostring(cerr4))
  local preserved = {
    number = 54,
    url = "https://github.com/example/repo/pull/54",
    state = "open",
  }
  local _, p4err = git.pr_attach(state, root, "T-20261114-c004", preserved)
  eq(p4err, nil, "the preserved PR is attached: " .. tostring(p4err))

  maki.fs.write(log, "")
  local reused, r4err = git.pr_open(state, root, "T-20261114-c004", {
    title = "feat: add export",
    body = "because finance",
    base = "main",
    head = "metronome/T-20261114-c004",
    worktree = base,
    gh = reuse_gh,
  })
  eq(r4err, nil, "pr_open reusing an open PR has no error: " .. tostring(r4err))
  eq(reused and reused.number, 54, "pr_open returns the preserved PR number")
  eq(reused and reused.url, "https://github.com/example/repo/pull/54", "pr_open returns the preserved PR url")

  local reused_task = state.load(root).tasks["T-20261114-c004"]
  eq(reused_task and reused_task.pr and reused_task.pr.number, 54, "the preserved PR is re-recorded on the task")
  eq(reused_task and reused_task.pr and reused_task.pr.state, "open", "the reused PR stays open")
  eq(reused_task and reused_task.status, "pr_open", "reuse still honours the pr_open transition")

  local reuse_log = read_log()
  eq(reuse_log:find("pr close", 1, true), nil, "reuse never closes the preserved PR")
  eq(reuse_log:find("pr create", 1, true), nil, "reuse never creates a second PR")
  has(reuse_log, "pr view 54 --json number,url,state", "reuse confirms the PR with gh before trusting it")
  eq(select(2, reuse_log:gsub("\n", "\n")), 1, "reuse runs exactly one gh call, the confirming view")

  -- attach_only still suppresses the transition on the reuse path.
  local created5, cerr5 = state.create(root, { id = "T-20261114-c005", title = "retry attach", status = "reviewing" })
  eq(cerr5, nil, "fifth task created: " .. tostring(cerr5))
  local _, p5err = git.pr_attach(state, root, "T-20261114-c005", preserved)
  eq(p5err, nil, "the preserved PR is attached again: " .. tostring(p5err))
  maki.fs.write(log, "")
  local reused5, r5err = git.pr_open(state, root, "T-20261114-c005", {
    title = "feat: add export",
    worktree = base,
    gh = reuse_gh,
    attach_only = true,
  })
  eq(r5err, nil, "attach_only reuse has no error: " .. tostring(r5err))
  eq(reused5 and reused5.number, 54, "attach_only reuse returns the preserved PR")
  local reused5_task = state.load(root).tasks["T-20261114-c005"]
  eq(reused5_task and reused5_task.status, "reviewing", "attach_only reuse does not move the task")
  local reuse5_log = read_log()
  eq(reuse5_log:find("pr close", 1, true), nil, "attach_only reuse never closes the preserved PR")
  eq(reuse5_log:find("pr create", 1, true), nil, "attach_only reuse never creates a second PR")
  has(reuse5_log, "pr view 54 --json number,url,state", "attach_only reuse confirms the PR with gh too")

  -- A merged or closed PR is not reusable: the create path still runs.
  local created6, cerr6 = state.create(root, { id = "T-20261114-c006", title = "stale pr", status = "reviewing" })
  eq(cerr6, nil, "sixth task created: " .. tostring(cerr6))
  local _, p6err = git.pr_attach(state, root, "T-20261114-c006", {
    number = 9,
    url = "https://github.com/example/repo/pull/9",
    state = "merged",
  })
  eq(p6err, nil, "the merged PR is attached: " .. tostring(p6err))
  maki.fs.write(log, "")
  local recreated, r6err = git.pr_open(state, root, "T-20261114-c006", {
    title = "feat: add export",
    base = "main",
    head = "metronome/T-20261114-c006",
    worktree = base,
    gh = ok_gh,
  })
  eq(r6err, nil, "pr_open over a merged PR has no error: " .. tostring(r6err))
  eq(recreated and recreated.number, 42, "a merged PR is replaced through the create path")
  has(read_log(), "pr create", "a merged PR does not stop the create path")
  eq(read_log():find("pr close", 1, true), nil, "a merged PR is not closed")
  local recreated_task = state.load(root).tasks["T-20261114-c006"]
  eq(recreated_task and recreated_task.pr and recreated_task.pr.number, 42,
    "the fresh PR replaces the merged one on the task")

  -- A closed PR is not reusable either: it also takes the create path.
  local created7, cerr7 = state.create(root, { id = "T-20261114-c007", title = "closed pr", status = "reviewing" })
  eq(cerr7, nil, "seventh task created: " .. tostring(cerr7))
  local _, p7err = git.pr_attach(state, root, "T-20261114-c007", {
    number = 11,
    url = "https://github.com/example/repo/pull/11",
    state = "closed",
  })
  eq(p7err, nil, "the closed PR is attached: " .. tostring(p7err))
  maki.fs.write(log, "")
  local recreated7, r7err = git.pr_open(state, root, "T-20261114-c007", {
    title = "feat: add export",
    base = "main",
    head = "metronome/T-20261114-c007",
    worktree = base,
    gh = ok_gh,
  })
  eq(r7err, nil, "pr_open over a closed PR has no error: " .. tostring(r7err))
  eq(recreated7 and recreated7.number, 42, "a closed PR is replaced through the create path")
  has(read_log(), "pr create", "a closed PR does not stop the create path")
  eq(read_log():find("pr close", 1, true), nil, "a closed PR is not closed again")
  local recreated7_task = state.load(root).tasks["T-20261114-c007"]
  eq(recreated7_task and recreated7_task.pr and recreated7_task.pr.number, 42,
    "the fresh PR replaces the closed one on the task")

  -- A PR cached as open but since closed on GitHub is not reused: the live
  -- state wins, so the create path runs instead of re-attaching a dead PR.
  local stale_gh = fake_gh("gh-stale", [[
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "13" ]; then
  echo '{"number":13,"url":"https://github.com/example/repo/pull/13","state":"CLOSED"}'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/example/repo/pull/42"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "https://github.com/example/repo/pull/42" ]; then
  echo '{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN"}'
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])
  local created8, cerr8 = state.create(root, { id = "T-20261114-c008", title = "stale open pr", status = "reviewing" })
  eq(cerr8, nil, "eighth task created: " .. tostring(cerr8))
  local _, p8err = git.pr_attach(state, root, "T-20261114-c008", {
    number = 13,
    url = "https://github.com/example/repo/pull/13",
    state = "open",
  })
  eq(p8err, nil, "the stale open PR is attached: " .. tostring(p8err))
  maki.fs.write(log, "")
  local recreated8, r8err = git.pr_open(state, root, "T-20261114-c008", {
    title = "feat: add export",
    base = "main",
    head = "metronome/T-20261114-c008",
    worktree = base,
    gh = stale_gh,
  })
  eq(r8err, nil, "pr_open over a stale open PR has no error: " .. tostring(r8err))
  eq(recreated8 and recreated8.number, 42, "a PR closed on GitHub is replaced, not reused")
  has(read_log(), "pr view 13 --json number,url,state", "the cached PR is re-read before reuse")
  has(read_log(), "pr create", "a PR closed on GitHub takes the create path")
  eq(read_log():find("pr close", 1, true), nil, "a stale PR is not closed")

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
