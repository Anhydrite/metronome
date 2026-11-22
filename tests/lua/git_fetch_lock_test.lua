-- Tests for serialized fetches and ref-lock classification (T-20261122-0034).
--
-- Concurrent git.fetch calls on the same clone raced on refs and died with
-- "cannot lock ref 'refs/remotes/origin/...'", failing tasks that had nothing
-- wrong with them. This file pins the halves of the fix:
--
--   (a) a fetch is single-flight per (repository, remote): one call starts one
--       `git fetch` child, the in-flight fetch is registered under a key that
--       names its remote, and the registry is empty again afterwards;
--   (b) four fetches started from four real processes on one clone never
--       overlap inside git and all succeed -- the pre-fix race, observed
--       without depending on an async primitive the test host may not have;
--   (c) the advisory lock is released when the fetch raises, and an abandoned
--       lock is taken over instead of wedging the clone;
--   (d) ref contention stderr classifies as git_lock/transient/retryable for
--       fetch, while unrelated failures and push rejections keep their cause.
--
-- Everything runs real git against a throwaway bare remote, seeded with many
-- refs: that is the shape the pipeline hits (an epic branch per task) and the
-- one that made the production collision visible.

return function()
  local git = load_module("git")
  local root = maki.uv.cwd()
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
  -- the shape the pipeline hits and the one that made the race visible.
  code, out = sh({
    "sh", "-c",
    'head=$(git rev-parse HEAD) || exit 1; i=0; '
      .. 'while [ "$i" -lt 60 ]; do '
      .. 'git update-ref "refs/heads/base-$i" "$head" || exit 1; i=$((i+1)); '
      .. "done",
  }, remote)
  eq(code, 0, "remote seeded with many branches: " .. out:sub(1, 80))

  -- (a) Single-flight, keyed by the remote ---------------------------------

  local lock, lock_err = git.fetch_lock_path(repo)
  eq(type(lock), "string", "the lock path is derived from the common git dir: " .. tostring(lock_err))
  eq(git.fetch_key(lock, "origin") ~= git.fetch_key(lock, "no-mistakes"), true,
    "the in-process key names the remote: origin and no-mistakes differ")
  eq(git.fetch_key(lock, "origin"), git.fetch_key(lock, "origin"),
    "the in-process key is stable for the same remote")

  -- The fetch goes through M.run, so counting `git fetch` children there is an
  -- honest seam, and the registry can be inspected while the child would run.
  local real_run = git.run
  local children, registered, other_registered = 0, nil, nil
  git.run = function(args, opts)
    if type(args) == "table" then
      for _, arg in ipairs(args) do
        if arg == "fetch" then
          children = children + 1
          registered = git.fetch_registered(git.fetch_key(lock, "origin"))
          other_registered = git.fetch_registered(git.fetch_key(lock, "no-mistakes"))
          break
        end
      end
    end
    return real_run(args, opts)
  end
  local fetched, ferr = git.fetch(repo, "origin")
  git.run = real_run

  eq(fetched, true, "the fetch succeeds: " .. tostring(ferr))
  eq(children, 1, "one fetch call starts exactly one git fetch child")
  eq(type(registered), "table", "the in-flight fetch is registered under (lock, remote)")
  eq(other_registered, nil,
    "a caller for another remote does not see the origin fetch as its own")
  eq(git.fetch_registered(git.fetch_key(lock, "origin")), nil,
    "the registry is empty once the fetch returns")
  eq(maki.fs.metadata(lock), nil, "the lock is released after a successful fetch")

  -- (a2) A second caller for the same (repo, remote) while a fetch is in
  -- flight waits for it and reuses its result -- it must not start a second
  -- `git fetch` child. Coroutines stand in for the two callers: maki's jobwait
  -- and the pause primitive yield, so the test can interleave them in-process.
  local saved_async = maki.async
  local fetched_children, in_fetch, pauses = 0, false, 0
  git.run = function(args, opts)
    if type(args) == "table" then
      for _, arg in ipairs(args) do
        if arg == "fetch" then
          fetched_children = fetched_children + 1
          if not in_fetch then
            in_fetch = true
            coroutine.yield("in-fetch")
          end
          break
        end
      end
    end
    return real_run(args, opts)
  end
  maki.async = { sleep = function()
    pauses = pauses + 1
    coroutine.yield("pause")
  end }
  -- The real sleep is what drives maki's job loop: a coroutine parked in a
  -- jobwait only advances when the host gets a turn.
  local real_sleep = saved_async and saved_async.sleep
  local function tick()
    if type(real_sleep) == "function" then
      real_sleep(1)
    end
  end

  local function resume_until(co, cond, label, limit)
    for _ = 1, limit or 400 do
      if coroutine.status(co) == "dead" then
        return
      end
      local ok, err = coroutine.resume(co)
      eq(ok, true, label .. " did not raise: " .. tostring(err))
      if cond and cond() then
        return
      end
      tick()
    end
  end

  local first = coroutine.create(function() return git.fetch(repo, "origin") end)
  resume_until(first, function() return in_fetch end, "the first fetch")
  eq(in_fetch, true, "the first fetch is in flight")
  eq(coroutine.status(first), "suspended", "the first fetch is parked inside git fetch")
  eq(fetched_children, 1, "the first caller started one git fetch child")

  local second = coroutine.create(function() return git.fetch(repo, "origin") end)
  resume_until(second, function() return pauses > 0 end, "the second fetch")
  eq(pauses > 0, true, "the second caller waits for the in-flight fetch")
  eq(coroutine.status(second), "suspended", "the second caller is still waiting")
  eq(fetched_children, 1, "the waiting caller starts no second git fetch child")

  local first_value, first_err
  for _ = 1, 400 do
    local ok, value, err = coroutine.resume(first)
    eq(ok, true, "the first fetch did not raise: " .. tostring(value))
    if coroutine.status(first) == "dead" then
      first_value, first_err = value, err
      break
    end
    tick()
  end
  eq(first_value, true, "the first fetch succeeds: " .. tostring(first_err))

  local second_value, second_err
  for _ = 1, 400 do
    local ok, value, err = coroutine.resume(second)
    eq(ok, true, "the second fetch did not raise: " .. tostring(value))
    if coroutine.status(second) == "dead" then
      second_value, second_err = value, err
      break
    end
    tick()
  end
  eq(second_value, true, "the second caller reuses the first result: " .. tostring(second_err))
  eq(fetched_children, 1, "the reused result cost no extra git fetch child")
  eq(git.fetch_registered(git.fetch_key(lock, "origin")), nil,
    "the shared fetch is unregistered once every caller has its result")

  -- (a3) The in-process wait is bounded too: a waiter behind a fetch that never
  -- finishes gives up with git_lock instead of hanging, and starts no child.
  in_fetch, fetched_children, pauses = false, 0, 0
  local slow_first = coroutine.create(function() return git.fetch(repo, "origin") end)
  resume_until(slow_first, function() return in_fetch end, "the slow fetch")
  eq(in_fetch, true, "the slow fetch is in flight")
  eq(coroutine.status(slow_first), "suspended", "the slow fetch is parked inside git fetch")

  local timed = coroutine.create(function()
    return git.fetch(repo, "origin", { lock_timeout_ms = 120 })
  end)
  local timed_result
  for _ = 1, 400 do
    local ok, a, b, c = coroutine.resume(timed)
    eq(ok, true, "the waiting fetch did not raise: " .. tostring(a))
    if coroutine.status(timed) == "dead" then
      timed_result = { a, b, c }
      break
    end
    tick()
  end
  eq(type(timed_result), "table", "the waiter gave up instead of hanging")
  eq(timed_result[1], nil, "the timed-out waiter does not succeed")
  eq(timed_result[3] and timed_result[3].cause, "git_lock", "the timed-out waiter names git_lock")
  eq(timed_result[3] and timed_result[3].retryable, true, "the timed-out waiter is retryable")
  eq(fetched_children, 1, "the timed-out waiter never started a second git fetch child")

  local slow_value, slow_err
  for _ = 1, 400 do
    local ok, value, err = coroutine.resume(slow_first)
    eq(ok, true, "the in-flight fetch did not raise: " .. tostring(value))
    if coroutine.status(slow_first) == "dead" then
      slow_value, slow_err = value, err
      break
    end
    tick()
  end
  eq(slow_value, true, "the in-flight fetch succeeds: " .. tostring(slow_err))
  eq(fetched_children, 1, "the in-flight fetch was the only child")

  maki.async = saved_async
  git.run = real_run

  -- (b) Four concurrent fetches from four real processes --------------------
  --
  -- The host has no async primitive the test can rely on, so the concurrency
  -- comes from the clone itself: its remote runs a wrapper around
  -- git-upload-pack that sleeps and records whether another fetch was already
  -- inside it. Two holds of that marker are the ref race, observed from the
  -- filesystem. Pre-fix (no serialization) the four fetches overlap; after the
  -- fix the repository lock serializes them, and all four still succeed.

  local events = maki.fs.joinpath(base, "events.log")
  local marker = maki.fs.joinpath(base, "in-fetch.d")
  local slow = maki.fs.joinpath(base, "slow-upload-pack.sh")
  local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
  end
  maki.fs.write(slow, table.concat({
    "#!/bin/sh",
    "# One fetch at a time per clone is the contract under test: a second",
    "# caller inside this block is a ref race in the making.",
    "if ! mkdir " .. q(marker) .. " 2>/dev/null; then",
    "  printf 'overlap\\n' >> " .. q(events),
    "fi",
    "sleep 1",
    "rmdir " .. q(marker) .. " 2>/dev/null",
    "printf 'run\\n' >> " .. q(events),
    'exec "$(git --exec-path)/git-upload-pack" "$@"',
    "",
  }, "\n"))
  code, out = sh({ "chmod", "+x", slow })
  eq(code, 0, "slow upload-pack is executable: " .. out:sub(1, 80))
  code, out = sh({ "git", "config", "remote.origin.uploadpack", slow }, repo)
  eq(code, 0, "the clone's origin uses the slow upload-pack: " .. out:sub(1, 80))

  local jobs = {}
  for i = 1, 4 do
    local child_out = maki.fs.joinpath(base, "child-" .. i .. ".txt")
    local driver = maki.fs.joinpath(base, "driver-" .. i .. ".lua")
    maki.fs.write(driver, table.concat({
      "-- Fetch once and leave the outcome for the parent to read.",
      'local child_git = load_module("git")',
      string.format("local value, err = child_git.fetch(%q, %q)", repo, "origin"),
      string.format('maki.fs.write(%q, tostring(value) .. "\\t" .. tostring(err))', child_out),
      "",
    }, "\n"))
    local job = maki.fn.jobstart({
      "env", "METRONOME_E2E_DRIVER=" .. driver, "maki", "--trust", "index", "README.md",
    }, { cwd = root, scope = "plugin" })
    eq(type(job), "number", "fetch child " .. i .. " started")
    jobs[#jobs + 1] = job
  end
  for _, job in ipairs(jobs) do
    maki.fn.jobwait(job, 120000)
  end

  local succeeded, first_err = 0, nil
  for i = 1, 4 do
    local text = maki.fs.read(maki.fs.joinpath(base, "child-" .. i .. ".txt")) or ""
    local value, err = text:match("^(.-)\t(.*)$")
    if value == "true" then
      succeeded = succeeded + 1
    elseif err and err ~= "nil" then
      first_err = first_err or err
    end
  end
  eq(succeeded, 4,
    "four concurrent fetches on one clone all succeed"
      .. (first_err and (": " .. first_err) or ""))

  local log = maki.fs.read(events) or ""
  local runs, overlaps = 0, 0
  for line in log:gmatch("[^\n]+") do
    if line == "run" then
      runs = runs + 1
    elseif line == "overlap" then
      overlaps = overlaps + 1
    end
  end
  eq(runs, 4, "each of the four callers ran its own fetch (ran " .. tostring(runs) .. ")")
  eq(overlaps, 0,
    "the four fetches never overlapped inside git (saw " .. tostring(overlaps)
      .. " overlap(s): that is the ref race)")

  -- The slow upload-pack is a test detail; the rest of the file talks to the
  -- plain local remote again.
  sh({ "git", "config", "--unset", "remote.origin.uploadpack" }, repo)

  -- (c) The lock survives neither an error nor an abandoned owner -----------

  -- A path that is not a checkout must fail immediately with the honest
  -- diagnosis, not spin the wait bound and blame git_lock.
  local not_a_repo = maki.fs.joinpath(base, "not-a-repo")
  maki.fs.mkdir(not_a_repo, { parents = true })
  local nr_value, nr_err = git.fetch(not_a_repo, "origin", { lock_timeout_ms = 5000 })
  eq(nr_value, nil, "a fetch outside a repository fails")
  has(nr_err or "", "not a git repository", "a non-repository names its real cause")

  -- An error raised *inside* the fetch must still give the lock back. The
  -- raise happens below M.fetch's own pcall in run_fetch, which is the path a
  -- cancelled or broken child takes.
  local raising = 0
  git.run = function(args, opts)
    if type(args) == "table" then
      for _, arg in ipairs(args) do
        if arg == "fetch" then
          raising = raising + 1
          error("injected: fetch died", 0)
        end
      end
    end
    return real_run(args, opts)
  end
  local raised, raised_err, raised_diag = git.fetch(repo, "origin")
  git.run = real_run
  eq(raising, 1, "the injected run seam was reached once")
  eq(raised, nil, "a fetch that raises does not succeed")
  eq(type(raised_err), "string", "a fetch that raises explains itself")
  eq(raised_diag and raised_diag.what, "fetch", "the raise is reported as a fetch failure")
  eq(maki.fs.metadata(lock), nil, "the lock is removed when the fetch raises")

  local after_raise, after_raise_err = git.fetch(repo, "origin")
  eq(after_raise, true, "a fetch after the raise succeeds: " .. tostring(after_raise_err))

  -- A local remote that does not exist makes git fail after the lock is taken;
  -- the lock still has to come back off.
  local bad, bad_err = git.fetch(repo, "nope")
  eq(bad, nil, "a fetch from a missing remote fails: " .. tostring(bad_err))
  eq(maki.fs.metadata(lock), nil, "the lock is removed after a failed fetch")

  -- A fresh lock belongs to a live fetch: the wait is bounded, and the error
  -- names the cause so the caller can retry instead of failing the task.
  maki.fs.write(lock, "held by the test\n")
  local blocked, blocked_err, blocked_diag = git.fetch(repo, "origin", { lock_timeout_ms = 150 })
  eq(blocked, nil, "a fetch blocked by a held lock does not succeed")
  eq(type(blocked_err), "string", "a blocked fetch explains itself")
  has(blocked_err or "", "git_lock", "the timeout error names git_lock")
  eq(blocked_diag and blocked_diag.cause, "git_lock", "the timeout diag carries cause git_lock")
  eq(blocked_diag and blocked_diag.transient, true, "the timeout diag is transient")
  eq(blocked_diag and blocked_diag.retryable, true, "the timeout diag is retryable")
  maki.fs.rm(lock, { force = true })

  -- A lock whose owner is gone -- a cancelled task, a crashed maki -- must be
  -- taken over, not polled until the pipeline gives up. A child that has
  -- already exited plays the crashed owner: its pid is real and dead.
  local dead_code, dead_out = sh({ "sh", "-c", "echo $$" })
  local dead_pid = tonumber((dead_out or ""):match("%d+"))
  eq(dead_code, 0, "a throwaway process ran: " .. (dead_out or ""):sub(1, 40))
  eq(type(dead_pid), "number", "its pid is readable")
  maki.fs.write(lock, string.format("pid=%d time=%d\n", dead_pid, os.time() * 1000 - 30000))
  local recovered, recovered_err = git.fetch(repo, "origin", { lock_timeout_ms = 10000 })
  eq(recovered, true, "a lock left by a dead owner is taken over: " .. tostring(recovered_err))
  eq(maki.fs.metadata(lock), nil, "the recovered lock is released after the fetch")

  -- A lock nobody released and nobody owns any more is taken over on age too:
  -- that is the crash with no pid recorded at all.
  maki.fs.write(lock, string.format("pid=0 time=%d\n", os.time() * 1000 - 600000))
  local reclaimed, reclaimed_err = git.fetch(repo, "origin", { lock_timeout_ms = 5000 })
  eq(reclaimed, true, "an abandoned lock is taken over: " .. tostring(reclaimed_err))
  eq(maki.fs.metadata(lock), nil, "the taken-over lock is released after the fetch")

  -- A crash between the shell's O_EXCL create and the `printf` leaves an empty
  -- or truncated lock with no `time=` to compare. It must be reclaimed by age,
  -- not polled forever: that was a permanent wedge after one SIGKILL.
  for _, content in ipairs({ "", "pid=12" }) do
    maki.fs.write(lock, content)
    local touched = sh({ "touch", "-d", "10 minutes ago", lock })
    eq(touched, 0, "the ownerless lock is backdated: " .. content)
    local aged, aged_err = git.fetch(repo, "origin", { lock_timeout_ms = 5000 })
    eq(aged, true, "an ownerless old lock is reclaimed (" .. content .. "): " .. tostring(aged_err))
    eq(maki.fs.metadata(lock), nil, "the reclaimed ownerless lock is released (" .. content .. ")")
  end

  -- (d) Ref contention classifies as git_lock -------------------------------

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

  -- Ref contention on another ref-writing command is the same transient
  -- contention, so it gets the same cause; only a push keeps its rejection.
  local rebase_diag = git.classify("rebase", {
    code = 1,
    stderr = "error: cannot lock ref 'refs/heads/task': is at a but expected b",
    command = "git rebase origin/main",
  })
  eq(rebase_diag.cause, "git_lock", "ref contention on rebase is git_lock")
  eq(rebase_diag.transient, true, "ref contention on rebase is transient")
  eq(rebase_diag.retryable, true, "ref contention on rebase is retryable")

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

  -- A push that mentions a ref update is a rejection, not transient ref
  -- contention: the caller has to rebase, so the hint must not say "retry".
  local push = git.classify("push", {
    code = 1,
    stderr = "error: failed to update ref 'refs/heads/x'\n"
      .. " ! [rejected]        x -> x (non-fast-forward)\n"
      .. "error: failed to push some refs to 'origin'",
    command = "git push origin x",
  })
  eq(push.cause, "push_rejected", "a push refusal keeps its specific cause")
  eq(push.transient, nil, "a push refusal is not transient")
end
