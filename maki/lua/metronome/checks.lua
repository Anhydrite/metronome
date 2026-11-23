-- Declared checks.
--
-- A task is done when its declared checks exit 0, not when the model says so.
-- This module runs them in the task worktree, keeps a bounded report, and when
-- a check is red it sends the branch back to the last checkpoint so the next
-- turn starts from a known-good commit instead of from a broken tree.
--
-- Every function returns `(value, err)` and never raises. git and state are
-- injected, so the module is pure Lua and the whole verdict is testable without
-- spending a token.

local M = {}

M.MAX_OUTPUT_DEFAULT = 8000
M.TIMEOUT_DEFAULT = 300000

local fs = maki.fs

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

-- A noisy check must not flood the report: both streams are cut to the same
-- bound, so the shape of a result is the same whatever the command printed.
local function truncate(text, limit)
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  limit = tonumber(limit) or M.MAX_OUTPUT_DEFAULT
  if limit < 0 then
    limit = 0
  end
  if #text > limit then
    return text:sub(1, limit)
  end
  return text
end

-- A declared check must answer the same way whatever the user's locale is: a
-- check that greps a tool's message would otherwise go green on one machine
-- and red on another. maki.fn.jobstart has no option to merge extra variables
-- into the inherited environment, so the argv is prefixed with
-- `env LC_ALL=C LANG=C`: the locale is pinned for the child while every
-- inherited variable (HOME, PATH, GIT_*) survives untouched.
local LOCALE_PREFIX = { "env", "LC_ALL=C", "LANG=C" }

-- Two tasks running at once must not share the state their checks write to
-- (journals, caches, scratch files under XDG_STATE_HOME). The prefix gains a
-- per-task directory, derived from the state root and the task id, so the same
-- task always gets the same home and two tasks never do.
--
-- The decision is read from the command TEXT, never from the inherited
-- environment: a check that already sets XDG_STATE_HOME= itself (either as a
-- `VAR=... cmd` assignment or through `env VAR=... cmd`) is left alone, while
-- a merely inherited value changes nothing -- otherwise the shell's value
-- would silently disable the isolation.
local STATE_HOME_VAR = "XDG_STATE_HOME="
local STATE_HOME_DIR = "checks-state"

-- The directory a check sees as XDG_STATE_HOME: <root>/checks-state/<task_id>.
-- Without a root the state dir is the base; without a task id there is no way
-- to keep tasks apart, so nothing is injected (callers that want isolation,
-- runtime.lua and merge.lua, always pass both).
function M.state_home(root, task_id)
  if not is_non_empty(task_id) then
    return nil
  end

  local base = is_non_empty(root) and root or nil
  if not base then
    local ok_dir, dir = pcall(function()
      return maki.env.state_dir()
    end)
    if not ok_dir or not is_non_empty(dir) then
      return nil
    end
    base = dir
  end

  local slug = tostring(task_id):gsub("[^%w._-]", "_")
  return fs.joinpath(base, STATE_HOME_DIR, slug)
end

-- The command already pins XDG_STATE_HOME: rewriting it would fight the author.
local function fixes_state_home(check)
  return type(check) == "string" and check:find(STATE_HOME_VAR, 1, true) ~= nil
end

local function env_prefix(check, state_home)
  local prefix = {}
  for i = 1, #LOCALE_PREFIX do
    prefix[i] = LOCALE_PREFIX[i]
  end
  if state_home and not fixes_state_home(check) then
    prefix[#prefix + 1] = STATE_HOME_VAR .. state_home
  end
  return prefix
end

-- jobstart raises (rather than returning nil) when there is no active task to
-- own the job, which happens at plugin top level. Retrying with a plugin scope
-- keeps the same code usable from a tool handler and from a test.
local function start(check, cwd, state_home)
  local prefix = env_prefix(check, state_home)
  local argv = {}
  for i = 1, #prefix do
    argv[i] = prefix[i]
  end
  argv[#argv + 1] = "sh"
  argv[#argv + 1] = "-c"
  argv[#argv + 1] = check
  local job_opts = { cwd = cwd }
  local ok_start, job, err = pcall(maki.fn.jobstart, argv, job_opts)
  if not ok_start then
    err = job
    job = nil
  end
  if not job and tostring(err):find("no active task", 1, true) then
    job_opts.scope = "plugin"
    local ok_retry, retry_job, retry_err = pcall(maki.fn.jobstart, argv, job_opts)
    if ok_retry then
      job, err = retry_job, retry_err
    else
      job, err = nil, retry_job
    end
  end
  if not job then
    return nil, "cannot start check: " .. tostring(err)
  end
  return job
end

-- Run every declared check, in order, and stop early when asked.
--
-- `opts.root` and `opts.task_id` scope the checks' XDG_STATE_HOME: passed both,
-- each check runs with a state home private to the task (created first), so two
-- tasks can run their checks at the same time without colliding.
--
-- A check that never returns is a failure, not a hang: jobwait is bounded by
-- timeout_ms and the job is stopped so it cannot outlive the verdict.
function M.run(checks, opts)
  opts = type(opts) == "table" and opts or {}
  if not is_non_empty(opts.worktree) then
    return nil, "run needs a worktree"
  end
  if type(checks) ~= "table" then
    return nil, "checks must be a list"
  end

  local timeout_ms = tonumber(opts.timeout_ms) or M.TIMEOUT_DEFAULT
  local max_output = tonumber(opts.max_output) or M.MAX_OUTPUT_DEFAULT
  local fail_fast = opts.fail_fast == true

  local results = {}
  local failed = {}

  local state_home = M.state_home(opts.root, opts.task_id)
  if state_home then
    local made, mkerr = fs.mkdir(state_home, { parents = true })
    if not made then
      return nil, "cannot create the check state home: " .. tostring(mkerr)
    end
  end

  for i = 1, #checks do
    local check = checks[i]
    if not is_non_empty(check) then
      return nil, string.format("check %d is not a non-empty string", i)
    end

    local started = os.time()
    local job, jerr = start(check, opts.worktree, state_home)
    if not job then
      return nil, jerr
    end

    local result = maki.fn.jobwait(job, timeout_ms)
    local timed_out = type(result) ~= "table" or result.exit_code == nil
    if timed_out then
      pcall(maki.fn.jobstop, job)
    end

    local code = type(result) == "table" and result.exit_code or nil
    local stdout = type(result) == "table" and (result.stdout or "") or ""
    local stderr = type(result) == "table" and (result.stderr or "") or ""

    local entry = {
      command = check,
      code = code,
      ok = (not timed_out and code == 0),
      stdout = truncate(stdout, max_output),
      stderr = truncate(stderr, max_output),
      timed_out = timed_out,
      duration_ms = (os.time() - started) * 1000,
    }
    results[#results + 1] = entry
    if not entry.ok then
      failed[#failed + 1] = entry
      if fail_fast then
        break
      end
    end
  end

  return {
    ok = (#failed == 0),
    results = results,
    failed = failed,
    ran = #results,
  }
end

-- The commit a red check returns to. An explicit checkpoint wins; otherwise the
-- task's history is the authority, and its last element is the newest starting
-- point.
function M.last_checkpoint(opts)
  opts = type(opts) == "table" and opts or {}

  if is_non_empty(opts.checkpoint) then
    return opts.checkpoint
  end
  if type(opts.state) ~= "table" or type(opts.state.load) ~= "function" then
    return nil, "last_checkpoint needs a state module"
  end
  if not is_non_empty(opts.root) then
    return nil, "last_checkpoint needs a state root"
  end
  if not is_non_empty(opts.task_id) then
    return nil, "last_checkpoint needs a task id"
  end

  local loaded = opts.state.load(opts.root)
  local task = loaded and loaded.tasks and loaded.tasks[opts.task_id]
  if type(task) ~= "table" then
    return nil, "unknown task: " .. tostring(opts.task_id)
  end

  local checkpoints = type(task.checkpoints) == "table" and task.checkpoints or {}
  local last = checkpoints[#checkpoints]
  if not is_non_empty(last) then
    return nil, "no checkpoint to return to"
  end
  return last
end

-- Roll the worktree back to the last checkpoint, hard: the commit and the files
-- both go back, so the next turn cannot inherit a failed edit.
function M.rollback(opts)
  opts = type(opts) == "table" and opts or {}
  if type(opts.git) ~= "table" or type(opts.git.reset_hard) ~= "function" then
    return nil, "rollback needs a git module with reset_hard"
  end
  if not is_non_empty(opts.worktree) then
    return nil, "rollback needs a worktree"
  end

  local sha, serr = M.last_checkpoint(opts)
  if not sha then
    return nil, serr
  end

  local head, herr = opts.git.reset_hard(opts.worktree, sha)
  if not head then
    return nil, herr
  end

  return { ok = true, checkpoint = sha, sha = head }
end

-- The verdict: run the checks, and when they are red, go back to the last
-- checkpoint unless the caller asked to keep the tree for inspection.
function M.verify(opts)
  opts = type(opts) == "table" and opts or {}
  if type(opts.checks) ~= "table" then
    return nil, "verify needs checks"
  end

  local run, rerr = M.run(opts.checks, opts)
  if not run then
    return nil, rerr
  end

  if run.ok then
    return {
      ok = true,
      results = run.results,
      failed = {},
      rolled_back = false,
      ran = run.ran,
    }
  end

  if opts.rollback == false then
    return {
      ok = false,
      results = run.results,
      failed = run.failed,
      rolled_back = false,
      ran = run.ran,
    }
  end

  local rb, berr = M.rollback(opts)
  if not rb then
    return nil, berr
  end

  return {
    ok = false,
    results = run.results,
    failed = run.failed,
    rolled_back = true,
    checkpoint = rb.checkpoint,
    sha = rb.sha,
    ran = run.ran,
  }
end

-- The report is the durable half of the verdict: a red check that nobody can
-- read afterwards is just a log line. It lands next to the state root, under
-- checks/<task>.json, so a human or a later turn can find it by task id.
function M.write_report(root, task_id, result, opts)
  opts = type(opts) == "table" and opts or {}
  result = type(result) == "table" and result or {}
  if not is_non_empty(root) then
    return nil, "write_report needs a root"
  end

  local dir = fs.joinpath(root, "checks")
  local made, mkerr = fs.mkdir(dir, { parents = true })
  if not made then
    return nil, "cannot create checks directory: " .. tostring(mkerr)
  end

  local path = fs.joinpath(dir, tostring(task_id) .. ".json")
  local payload = {
    at = opts.now or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    task_id = task_id,
    ok = result.ok,
    rolled_back = result.rolled_back,
    checkpoint = result.checkpoint,
    ran = result.ran,
    results = result.results,
  }

  local ok_enc, encoded = pcall(maki.json.encode, payload)
  if not ok_enc or type(encoded) ~= "string" then
    return nil, "cannot encode checks report: " .. tostring(encoded)
  end

  local wrote, werr = fs.write(path, encoded)
  if not wrote then
    return nil, "cannot write checks report: " .. tostring(werr)
  end

  return path
end

return M
