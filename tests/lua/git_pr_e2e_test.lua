-- End-to-end git + PR chain on a throwaway repository (REQ-20261114-22).
--
-- The other git/PR tests each prove one command shape. This one proves the
-- chain: fetch -> worktree add -> commit -> push -> pr_open -> PR stored on the
-- task, against a LOCAL BARE REMOTE and a fake `gh`.
--
-- The fake `gh` is the interesting part: before it answers `pr create` it asks
-- the bare remote whether the head branch is actually there. So a green run
-- proves the push really happened before the PR was opened, not merely that a
-- command was sent in that order.
--
-- No real GitHub repository is involved, and nothing outside this temp dir is
-- written. The temp dir is deliberately kept at the end so tests/run-lua.sh can
-- validate the journal it produced; the next run removes it first.

return function()
  local git = load_module("git")
  local state = load_module("state")

  -- test_dir() empties and recreates the per-test workspace, so two runs (or
  -- two tests) never share a journal, a temporary repository or a worktree.
  local base = test_dir("git-pr-e2e")

  local remote = maki.fs.joinpath(base, "remote.git")
  local repo = maki.fs.joinpath(base, "repo")
  local worktree = maki.fs.joinpath(base, "wt")
  local scripts = maki.fs.joinpath(base, "bin")
  local log = maki.fs.joinpath(base, "gh.log")
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

  -- The fake `gh`: it refuses to open a PR for a branch the remote lacks ------

  local gh = maki.fs.joinpath(scripts, "gh")
  maki.fs.write(gh, table.concat({
    "#!/usr/bin/env bash",
    "REMOTE=" .. quote(remote),
    "LOG=" .. quote(log),
    "printf '%s\\n' \"$*\" >> \"$LOG\"",
    "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then",
    "  head=\"\"",
    "  base=\"\"",
    "  while [ $# -gt 0 ]; do",
    "    case \"$1\" in",
    "      --head) head=\"$2\"; shift 2 ;;",
    "      --base) base=\"$2\"; shift 2 ;;",
    "      *) shift ;;",
    "    esac",
    "  done",
    "  if [ -z \"$head\" ]; then",
    "    echo 'no --head' >&2",
    "    exit 1",
    "  fi",
    "  if ! git -C \"$REMOTE\" rev-parse --verify \"refs/heads/$head\" >/dev/null 2>&1; then",
    "    echo \"branch $head is not on the remote\" >&2",
    "    exit 1",
    "  fi",
    "  echo 'https://github.com/example/shop/pull/7'",
    "  exit 0",
    "fi",
    "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then",
    "  echo '{\"number\":7,\"url\":\"https://github.com/example/shop/pull/7\",\"state\":\"OPEN\"}'",
    "  exit 0",
    "fi",
    "echo \"unexpected: $*\" >&2",
    "exit 2",
    "",
  }, "\n"))
  code, out = sh({ "chmod", "+x", gh })
  eq(code, 0, "fake gh is executable: " .. out:sub(1, 80))

  -- Scenario A: the happy path ------------------------------------------------

  local branch = "metronome/T-20261114-d001"
  local id = "T-20261114-d001"

  local fetched, ferr = git.fetch(repo, "origin")
  eq(fetched, true, "fetch works: " .. tostring(ferr))
  eq(ferr, nil, "fetch has no error")

  local wt, werr = git.worktree_add(repo, worktree, branch, "main", { remote = "origin" })
  eq(werr, nil, "worktree add has no error: " .. tostring(werr))
  eq(wt, worktree, "worktree path returned")

  maki.fs.write(maki.fs.joinpath(worktree, "shop.lua"), "return { products = {} }\n")
  local sha, serr = git.commit(worktree, git.conventional("feat", "shop", "add product list"))
  eq(serr, nil, "commit has no error: " .. tostring(serr))
  eq(type(sha), "string", "commit returns a sha")
  eq(#sha, 40, "sha is full length")

  local pushed, perr = git.push(worktree, branch)
  eq(pushed, true, "push works: " .. tostring(perr))
  eq(perr, nil, "push has no error")

  local rcode, rout = sh({ "git", "-C", remote, "rev-parse", "--verify", "refs/heads/" .. branch })
  eq(rcode, 0, "branch is on the bare remote: " .. rout:sub(1, 80))

  -- Nothing has called `gh` yet: the PR step comes after the push, not before.
  eq(read_log(), "", "no gh call before the PR step")

  local created, cerr = state.create(root, { id = id, title = "e2e", status = "reviewing" })
  eq(cerr, nil, "task created: " .. tostring(cerr))
  eq(created and created.status, "reviewing", "task starts reviewing")

  local pr, oerr = git.pr_open(state, root, id, {
    title = "feat: add product list",
    body = "e2e",
    base = "main",
    head = branch,
    worktree = worktree,
    gh = gh,
  })
  eq(oerr, nil, "pr_open has no error: " .. tostring(oerr))
  eq(pr and pr.number, 7, "pr_open returns the PR number")
  eq(pr and pr.url, "https://github.com/example/shop/pull/7", "pr_open returns the PR url")
  eq(pr and pr.state, "open", "pr_open returns the normalised state")

  -- The gap this requirement exists for: opening a PR moves the task.
  local loaded = state.load(root)
  local task = loaded.tasks[id]
  eq(task and task.status, "pr_open", "task moved to pr_open")

  eq(task and task.pr and task.pr.number, 7, "PR number is stored on the task")
  eq(task and task.pr and task.pr.url, "https://github.com/example/shop/pull/7", "PR url is stored on the task")
  eq(task and task.pr and task.pr.state, "open", "PR state is stored on the task")

  local logtext = read_log()
  has(logtext, "pr create --base main --head " .. branch .. " --title feat: add product list --body e2e",
    "gh was asked to create the PR for the pushed branch")
  has(logtext, "pr view https://github.com/example/shop/pull/7 --json number,url,state,mergeable,baseRefName",
    "gh was asked to re-read the PR")
  local create_at = logtext:find("pr create", 1, true)
  local view_at = logtext:find("pr view", 1, true)
  eq(create_at ~= nil and view_at ~= nil and create_at < view_at, true, "create is logged before view")

  -- The remote really is a local bare repository, not a stand-in.
  local bcode, bout = sh({ "git", "-C", remote, "rev-parse", "--is-bare-repository" })
  eq(bcode, 0, "bare check ran: " .. bout:sub(1, 80))
  eq((bout:gsub("%s+$", "")), "true", "remote is a bare repository")
  eq(remote:sub(1, #base) == base, true, "remote lives inside the throwaway dir")

  -- Scenario B: a PR for a branch that was never pushed -----------------------

  local id2 = "T-20261114-d002"
  local created2, cerr2 = state.create(root, { id = id2, title = "e2e failure", status = "reviewing" })
  eq(cerr2, nil, "second task created: " .. tostring(cerr2))

  local unpushed = "metronome/T-20261114-not-pushed"
  local nopr, noerr = git.pr_open(state, root, id2, {
    title = "feat: never pushed",
    body = "e2e",
    base = "main",
    head = unpushed,
    worktree = worktree,
    gh = gh,
  })
  eq(nopr, nil, "pr_open refuses a branch that is not on the remote")
  eq(type(noerr), "string", "the refusal explains itself")
  has(noerr, "not on the remote", "the refusal names the missing branch")

  local after = state.load(root).tasks[id2]
  eq(after and after.status, "reviewing", "a failed PR leaves the task reviewing")
  eq(after and after.pr, nil, "a failed PR stores nothing on the task")

  -- Cleanup ------------------------------------------------------------------
  --
  -- The worktree goes, the temp dir stays: tests/run-lua.sh validates the
  -- journal it holds. The next run removes the dir before rebuilding it.

  local removed, rerr = git.worktree_remove(repo, worktree, { force = true })
  eq(removed, true, "worktree removed: " .. tostring(rerr))
end
