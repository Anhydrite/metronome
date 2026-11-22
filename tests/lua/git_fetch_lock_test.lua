-- Tests for serialized fetches and ref-lock classification (T-20261122-0034).
--
-- Concurrent git.fetch calls on the same clone raced on refs and died with
-- "cannot lock ref 'refs/remotes/origin/...'", failing tasks that had nothing
-- wrong with them. This file pins the three halves of the fix:
--
--   (a) four concurrent fetches on one clone all succeed, and only one
--       `git fetch` child is started for them (the others reuse its result);
--   (b) the advisory lock file is gone after a failing fetch, and a later
--       fetch still works -- a fetch that fails must not wedge the clone;
--   (c) ref contention stderr classifies as git_lock/transient/retryable,
--       while unrelated failures stay the generic git_error.
--
-- Everything runs real git against a throwaway bare remote. The remote carries
-- many refs, the shape that made the production race visible. The ref-lock
-- collision itself is timing-dependent, so the pre-fix failure is pinned by a
-- deterministic signal instead: how many `git fetch` children the four
-- callers start. Before the fix each caller starts its own (four); after it,
-- one fetch runs and the other three reuse its result.

return function()
  local git = load_module("git")
  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "git-fetch-lock")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local repo = maki.fs.joinpath(base, "repo")
  local remote = maki.fs.joinpath(base, "remote.git")

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  -- Setup: a bare remote plus a clone that tracks it -----------------------

  local code, out = sh({ "git", "init", "--bare", "-b", "main", remote })
  eq(code, 0, "bare remote created: " .. out:sub(1, 80))

  maki.fs.mkdir(repo, { parents = true })
  code, out = sh({ "git", "init", "-b", "main" }, repo)
  eq(code, 0, "repo created: " .. out:sub(1, 80))
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

  -- Many refs on the remote: a fetch then writes many remote-tracking files,
  -- the shape the pipeline hits (an epic branch per task) and the one that made
  -- the production collision visible.
  code, out = sh({
    "sh", "-c",
    'head=$(git rev-parse HEAD) || exit 1; i=0; '
      .. 'while [ "$i" -lt 60 ]; do '
      .. 'git update-ref "refs/heads/base-$i" "$head" || exit 1; i=$((i+1)); '
      .. "done",
  }, remote)
  eq(code, 0, "remote seeded with many branches: " .. out:sub(1, 80))

  -- (a) Four concurrent fetches on one clone --------------------------------

  -- Count the `git fetch` children the module really starts. The serialized
  -- path goes through M.run for that command, so overriding it is an honest
  -- seam: four callers, one fetch.
  local real_run = git.run
  local fetch_children = 0
  git.run = function(args, opts)
    if type(args) == "table" then
      for _, arg in ipairs(args) do
        if arg == "fetch" then
          fetch_children = fetch_children + 1
          break
        end
      end
    end
    return real_run(args, opts)
  end

  -- A child that fails raises, so gather reports git.fetch's error text rather
  -- than a bare nil first return.
  local function fetch_once()
    local value, err = git.fetch(repo, "origin")
    if value == true then
      return true
    end
    error("fetch failed: " .. tostring(err), 0)
  end

  local results
  if maki.async and type(maki.async.gather) == "function" then
    results = maki.async.gather({ fetch_once, fetch_once, fetch_once, fetch_once })
  else
    -- No concurrency primitive: the four calls still have to succeed, they
    -- just cannot overlap. Only the success count is meaningful here.
    results = {}
    for i = 1, 4 do
      local value, err = git.fetch(repo, "origin")
      results[i] = { ok = true, value = value, err = err }
    end
  end

  local succeeded, first_err = 0, nil
  for _, entry in ipairs(results) do
    if entry.ok and entry.value == true then
      succeeded = succeeded + 1
    elseif entry.err then
      first_err = first_err or tostring(entry.err)
    end
  end
  eq(succeeded, 4,
    "four concurrent fetches on one clone all succeed"
      .. (first_err and (": " .. first_err) or ""))

  if maki.async and type(maki.async.gather) == "function" then
    eq(fetch_children, 1,
      "the concurrent fetches share a single git fetch child (started "
        .. tostring(fetch_children) .. ")")
  end

  git.run = real_run

  -- (b) The lock is released on the error path ------------------------------

  local lock = maki.fs.joinpath(repo, ".git", "metronome-fetch.lock")

  -- A held lock must not hang the caller: the wait is bounded, and the error
  -- names the cause so the caller can retry instead of failing the task.
  maki.fs.write(lock, "held by the test\n")
  local blocked, blocked_err, blocked_diag = git.fetch(repo, "origin", { lock_timeout_ms = 150 })
  eq(blocked, nil, "a fetch blocked by a held lock does not succeed")
  eq(type(blocked_err), "string", "a blocked fetch explains itself")
  has(blocked_err or "", "git_lock", "the timeout error names git_lock")
  eq(blocked_diag and blocked_diag.cause, "git_lock", "the timeout diag carries cause git_lock")
  eq(blocked_diag and blocked_diag.transient, true, "the timeout diag is transient")
  maki.fs.rm(lock, { force = true })

  -- A failing git command inside the fetch must still drop the lock. A missing
  -- remote is the cheapest real failure: the lock is taken, git fails, the
  -- lock has to come back off.
  local bad, bad_err = git.fetch(repo, "nope")
  eq(bad, nil, "a fetch from a missing remote fails: " .. tostring(bad_err))
  local leftover = maki.fs.metadata(lock)
  eq(leftover, nil, "the fetch lock is removed after a failed fetch")

  local again, again_err = git.fetch(repo, "origin")
  eq(again, true, "a fetch after the failure succeeds: " .. tostring(again_err))
  eq(maki.fs.metadata(lock), nil, "the fetch lock is removed after a successful fetch")

  -- (c) Ref contention classifies as git_lock -------------------------------

  local lock_strings = {
    "error: cannot lock ref 'refs/remotes/origin/metronome/epic/x': is at a but expected b",
    "error: cannot lock ref 'refs/remotes/origin/main'",
    "error: unable to update local ref",
    "error: failed to update ref",
  }
  for _, stderr in ipairs(lock_strings) do
    local diag = git.classify("fetch", { code = 1, stderr = stderr, command = "git fetch origin --prune" })
    eq(diag.cause, "git_lock", "ref contention is git_lock: " .. stderr)
    eq(diag.transient, true, "ref contention is transient: " .. stderr)
    eq(diag.retryable, true, "ref contention is retryable: " .. stderr)
    eq(diag.hint ~= nil and diag.hint ~= "", true, "ref contention names a remedy: " .. stderr)
    has(diag.message or "", "ref", "the git_lock message names the contention: " .. stderr)
    eq(diag.message:find("inspect the command output", 1, true), nil,
      "the git_lock message is not the generic one: " .. stderr)
  end

  -- Unrelated failures keep the catch-all, and are not announced as retryable
  -- ref contention.
  local other = git.classify("fetch", {
    code = 128,
    stderr = "fatal: could not resolve host: example.invalid",
    command = "git fetch origin --prune",
  })
  eq(other.cause, "git_error", "an unrelated fetch failure stays git_error")
  eq(other.transient, nil, "an unrelated failure is not transient")
  eq(other.retryable, nil, "an unrelated failure is not retryable")
end
