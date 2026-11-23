-- Real-git integration proof for maki/lua/metronome/preflight.lua
-- (T-20261122-001b).
--
-- preflight_test.lua drives a fake exec, so it proves the verdict logic but not
-- that the verdict survives contact with git. This file runs the real preflight
-- against throwaway repositories with a bare remote, the way git_test.lua runs
-- real git: the ordering of the five checks, the lifecycle of the throwaway
-- worktree (add -> commit -> remove -> prune) and the LC_ALL=C pinning are
-- proven against the real binary, not a script.
--
-- The healthy case must be green and leave no worktree registration behind.
-- The three refusal cases must fail on the promised id with an actionable
-- message. Everything lives under the temp tree that is removed at the end.

return function()
  local preflight = load_module("preflight")

  -- test_dir() empties and recreates the per-test workspace, so two runs (or
  -- two tests) never share a journal, a temporary repository or a worktree.
  local base = test_dir("preflight-integration")

  local repo = maki.fs.joinpath(base, "repo")
  local remote = maki.fs.joinpath(base, "remote.git")
  local WANT_IDS = { "git-identity", "git-test-commit", "checks-executable", "origin-base", "toolchain" }

  -- Run one child through maki's own host, the way git_test.lua does. The
  -- preflight default exec retries with `scope = "plugin"` when no task owns the
  -- job; asking for that scope directly is the same thing, deterministically.
  local function job(args, opts)
    opts = opts or {}
    local job_opts = { cwd = opts.cwd, scope = "plugin" }
    local ok_start, started, err = pcall(maki.fn.jobstart, args, job_opts)
    if not ok_start then
      return nil, "cannot start child: " .. tostring(started)
    end
    if not started then
      return nil, "cannot start child: " .. tostring(err)
    end
    local res, werr = maki.fn.jobwait(started, opts.timeout_ms or 30000)
    if type(res) ~= "table" then
      return nil, "child did not finish: " .. tostring(werr)
    end
    return { code = res.exit_code, stdout = res.stdout or "", stderr = res.stderr or "" }
  end

  local function sh(args, cwd)
    local res = job(args, { cwd = cwd })
    res = res or { code = -1, stdout = "", stderr = "no result" }
    return res.code, (res.stdout .. res.stderr)
  end

  -- A real executor that records exactly what preflight asked for, then runs it.
  -- `extra_env` is inserted after `env` so a case can pin git's config source
  -- (for the missing-identity case) without touching the machine's global
  -- config; every other argument is passed through unchanged.
  local function recording_exec(extra_env)
    local calls = {}

    local function exec(args, opts)
      local argv = {}
      for i = 1, #args do
        argv[#argv + 1] = args[i]
        if i == 1 and args[1] == "env" and extra_env then
          for _, kv in ipairs(extra_env) do
            argv[#argv + 1] = kv
          end
        end
      end
      calls[#calls + 1] = { args = argv, joined = table.concat(argv, " "), cwd = opts and opts.cwd }
      return job(argv, opts)
    end

    return exec, calls
  end

  -- The fixture: a real repo with an identity, one commit and a bare remote
  -- pushed as origin with base branch main.
  local code, out = sh({ "git", "init", "--bare", "-b", "main", remote })
  eq(code, 0, "bare remote created: " .. out:sub(1, 80))

  maki.fs.mkdir(repo, { parents = true })
  code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "repo created: " .. out:sub(1, 80))
  code, out = sh({ "git", "config", "user.email", "preflight@example.com" }, repo)
  eq(code, 0, "repo-local user.email set: " .. out:sub(1, 80))
  code, out = sh({ "git", "config", "user.name", "Preflight Test" }, repo)
  eq(code, 0, "repo-local user.name set: " .. out:sub(1, 80))
  code, out = sh({ "git", "remote", "add", "origin", remote }, repo)
  eq(code, 0, "origin added: " .. out:sub(1, 80))
  maki.fs.write(maki.fs.joinpath(repo, "README.md"), "# throwaway\n")
  code, out = sh({ "git", "add", "-A" }, repo)
  eq(code, 0, "initial add: " .. out:sub(1, 80))
  code, out = sh({ "git", "commit", "-m", "chore: init" }, repo)
  eq(code, 0, "initial commit: " .. out:sub(1, 80))
  code, out = sh({ "git", "push", "-u", "origin", "main" }, repo)
  eq(code, 0, "initial push: " .. out:sub(1, 80))

  -- The registered worktrees git knows about, read from the real binary.
  local function worktree_paths()
    local res = job({ "git", "-C", repo, "worktree", "list", "--porcelain" })
    eq(res ~= nil, true, "git worktree list ran")
    local paths = {}
    for line in ((res and res.stdout) or ""):gmatch("[^\n]+") do
      local path = line:match("^worktree%s+(.+)$")
      if path then
        paths[#paths + 1] = path
      end
    end
    return paths
  end

  local function failure_with(result, id, label)
    for _, item in ipairs(result.failures or {}) do
      if item.id == id then
        return item
      end
    end
    fail(label .. ": no failure with id " .. id)
    return {}
  end

  local function check_with(result, id, label)
    for _, item in ipairs(result.checks or {}) do
      if item.id == id then
        return item
      end
    end
    fail(label .. ": no check with id " .. id)
    return {}
  end

  -- (a) A healthy repository is green ---------------------------------------
  --
  -- The probe commit must really happen in a throwaway worktree, and that
  -- worktree must be gone and unregistered when the run returns.

  local before = worktree_paths()
  eq(#before, 1, "the fixture repo has exactly one worktree before preflight")

  local exec, calls = recording_exec()
  local green = preflight.run({
    repo = repo,
    base_ref = "main",
    checks = { "sh -c true" },
    exec = exec,
  })

  eq(green.ok, true, "healthy repo: preflight is green (" .. tostring(green.message) .. ")")
  eq(#green.failures, 0, "healthy repo: preflight has no failure")
  eq(#green.checks, #WANT_IDS, "healthy repo: preflight ran exactly five checks")
  for i, id in ipairs(WANT_IDS) do
    eq(green.checks[i].id, id, "healthy repo: check " .. i .. " is " .. id)
    eq(green.checks[i].ok, true, "healthy repo: " .. id .. " is ok")
  end

  local commit_check = check_with(green, "git-test-commit", "healthy repo")
  has(commit_check.command, "worktree add", "healthy repo: the probe commit ran in a throwaway worktree")

  -- Every child carries the locale prefix, so a diagnostic is the same string
  -- on every machine. This is added by preflight, and recorded before the real
  -- process started.
  eq(#calls > 0, true, "healthy repo: preflight started at least one child")
  for _, item in ipairs(calls) do
    eq(item.args[1], "env", "healthy repo: every child starts with env")
    eq(item.args[2], "LC_ALL=C", "healthy repo: every child pins LC_ALL=C")
    eq(item.args[3], "LANG=C", "healthy repo: every child pins LANG=C")
  end

  local after = worktree_paths()
  eq(#after, 1, "healthy repo: exactly one worktree remains after preflight")
  eq(after[1], repo, "healthy repo: the only remaining worktree is the main one")
  for _, path in ipairs(after) do
    eq(path:find("metronome-preflight", 1, true), nil, "healthy repo: no probe worktree is registered")
  end

  -- (b) A repository with no git identity is refused ------------------------
  --
  -- The repo-local email is removed and the child is pinned to empty global and
  -- system config, so the refusal does not depend on the machine's own setup.

  code, out = sh({ "git", "config", "--local", "--unset", "user.email" }, repo)
  eq(code, 0, "repo-local user.email removed: " .. out:sub(1, 80))

  local no_id_exec = recording_exec({ "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1" })
  local no_identity = preflight.run({
    repo = repo,
    base_ref = "main",
    checks = { "sh -c true" },
    exec = no_id_exec,
  })
  eq(no_identity.ok, false, "missing identity: preflight is refused")
  local identity_failure = failure_with(no_identity, "git-identity", "missing identity")
  has(identity_failure.detail, "user.email", "missing identity: detail names user.email")
  has(identity_failure.remedy, "git config", "missing identity: remedy names the git config command")
  has(identity_failure.remedy, "user.email", "missing identity: remedy names user.email")
  has(no_identity.message, "git-identity", "missing identity: message names the failing id")

  -- Restore the identity for the remaining cases.
  code, out = sh({ "git", "config", "user.email", "preflight@example.com" }, repo)
  eq(code, 0, "repo-local user.email restored: " .. out:sub(1, 80))
  eq(#worktree_paths(), 1, "missing identity: no probe worktree is left behind")

  -- (c) A base branch that is not on origin is refused ----------------------

  local missing_base = "epic/not-on-origin"
  local base_exec = recording_exec()
  local no_base = preflight.run({
    repo = repo,
    base_ref = missing_base,
    checks = { "sh -c true" },
    exec = base_exec,
  })
  eq(no_base.ok, false, "unknown base ref: preflight is refused")
  local base_failure = failure_with(no_base, "origin-base", "unknown base ref")
  has(base_failure.detail, missing_base, "unknown base ref: detail names the asked-for branch")
  has(no_base.message, missing_base, "unknown base ref: message names the asked-for branch")
  has(base_failure.remedy, "git ls-remote", "unknown base ref: remedy explains how to check the name")
  eq(#worktree_paths(), 1, "unknown base ref: no probe worktree is left behind")

  -- (d) A check whose program is not on PATH is refused ---------------------

  local missing_binary = "metronome-preflight-absent-binary"
  local declared = missing_binary .. " --version"
  local bin_exec = recording_exec()
  local no_binary = preflight.run({
    repo = repo,
    base_ref = "main",
    checks = { declared },
    exec = bin_exec,
  })
  eq(no_binary.ok, false, "missing binary: preflight is refused")
  local binary_failure = failure_with(no_binary, "checks-executable", "missing binary")
  eq(binary_failure.command, declared, "missing binary: failure quotes the whole declared command")
  has(binary_failure.detail, "PATH", "missing binary: detail says the program is not on PATH")
  has(binary_failure.remedy, missing_binary, "missing binary: remedy names the missing binary")
  has(binary_failure.remedy, declared, "missing binary: remedy quotes the declared check")
  eq(#worktree_paths(), 1, "missing binary: no probe worktree is left behind")

  -- Cleanup -----------------------------------------------------------------

  maki.fs.rm(base, { recursive = true })
end
