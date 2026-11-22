-- Deploy: run the deployment plan, with the user in the loop.
--
-- Deploy is the one step that touches the real world, so it is deliberately
-- conservative: it only starts from `merged` (or resumes a `deploying` task),
-- it refuses unless the pull request is really merged (stored and live), it
-- refuses unless the checks report is green, it requires `deploy.md` to
-- exist, and it asks for confirmation before it moves anything. The agent is
-- guided by the plan verbatim; the module never invents a step.
--
-- Every function returns `(value, err)` and never raises. state, the runner and
-- the session options are injected, so the whole step is testable without
-- spending a token.

local M = {}

local fs = maki.fs

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Plan -----------------------------------------------------------------------

-- Read the deployment plan. The plan is required: without it the agent would
-- have to invent the steps, which is exactly what deploy.md exists to prevent.
function M.plan(opts)
  opts = type(opts) == "table" and opts or {}

  local plan_file = is_non_empty(opts.plan_file) and opts.plan_file or "deploy.md"
  local path = opts.plan_path
  if not is_non_empty(path) then
    if is_non_empty(opts.repo) then
      path = fs.joinpath(opts.repo, plan_file)
    else
      path = plan_file
    end
  end

  local text = fs.read(path)
  if type(text) ~= "string" or trim(text) == "" then
    return nil, "missing deploy plan: " .. tostring(path)
  end
  return text, nil
end

-- Checks ---------------------------------------------------------------------

-- Is the checks report green? `<root>/checks/<task>.json` is written by
-- checks.lua; a missing or unreadable report is a refusal, never a pass.
function M.checks_green(root, task_id, opts)
  opts = type(opts) == "table" and opts or {}

  if opts.checks_ok ~= nil then
    return opts.checks_ok, nil
  end

  if not is_non_empty(root) or not is_non_empty(task_id) then
    return nil, "no checks report for " .. tostring(task_id)
  end

  local path = fs.joinpath(root, "checks", tostring(task_id) .. ".json")
  local text = fs.read(path)
  if type(text) ~= "string" then
    return nil, "no checks report for " .. tostring(task_id)
  end

  local ok, report = pcall(maki.json.decode, text)
  if not ok or type(report) ~= "table" then
    return nil, "invalid checks report"
  end

  return report.ok == true, nil
end

-- PR guard -------------------------------------------------------------------

-- A task marked `merged` is not enough: the pull request itself must be merged.
-- The stored state is a cache, so unless `verify_pr = false` the live
-- `gh pr view` is consulted too. A refused or unverifiable PR never deploys.
function M.pr_merged(task, opts)
  opts = type(opts) == "table" and opts or {}

  -- Test/override seam: the caller can decide without a PR or a live call.
  if opts.pr_merged ~= nil then
    return opts.pr_merged and true or false, nil
  end

  local pr = type(task) == "table" and task.pr or nil
  if type(pr) ~= "table" then
    return nil, "task has no pull request"
  end

  local stored_state = pr.state
  if stored_state ~= "merged" then
    return nil, "pull request is not merged (state: "
      .. tostring(stored_state or "unknown") .. ")"
  end

  if opts.verify_pr ~= false
    and type(opts.git) == "table"
    and type(opts.git.pr_view) == "function" then
    local live, err = opts.git.pr_view(pr.number or pr.url, {
      gh = opts.gh,
      worktree = opts.worktree,
    })
    if not live then
      return nil, "cannot verify pull request: " .. tostring(err)
    end
    if live.state ~= "merged" then
      return nil, "pull request is not merged: live state is "
        .. tostring(live.state or "unknown")
    end
  end

  return true, nil
end

-- Guard ----------------------------------------------------------------------

-- The gate before anything moves. A task is deployable only from `merged` (a
-- fresh deploy) or `deploying` (a resume), only with green checks, and only
-- with a plan on disk.
function M.guard(task, root, opts)
  opts = type(opts) == "table" and opts or {}

  if type(task) ~= "table" or not is_non_empty(task.id) then
    return nil, "task needs an id"
  end

  local status = task.status
  if status == "deployed" then
    return nil, "already deployed"
  end
  if status ~= "merged" and status ~= "deploying" then
    return nil, "cannot deploy from " .. tostring(status)
  end

  local pr_ok, pr_err = M.pr_merged(task, opts)
  if pr_ok ~= true then
    return nil, pr_err
  end

  if opts.require_checks ~= false then
    local green, err = M.checks_green(root, task.id, opts)
    if green ~= true then
      return nil, "checks are not green: " .. tostring(err or "checks report is red")
    end
  end

  local plan, perr = M.plan(opts)
  if not plan then
    return nil, perr
  end

  return true, nil
end

-- Prompt ---------------------------------------------------------------------

-- The agent's brief. The plan is carried verbatim: the model follows it, it
-- does not reinterpret it. The rules repeat the protected paths because a
-- deployment is exactly where a stray "fix" would be most expensive.
function M.prompt(task, plan, checks, sheet, opts)
  opts = type(opts) == "table" and opts or {}
  task = type(task) == "table" and task or {}

  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  local id = tostring(task.id or "")
  local title = trim(task.title)
  local fence = type(opts.fence) == "table" and opts.fence or nil

  line("# Deploy")
  line("")
  line("## Task")
  line("")
  line("- id: " .. id)
  line("- title: " .. (title ~= "" and title or "(no title)"))
  line("")
  line("## Deploy plan")
  line("")
  line(tostring(plan or ""))
  line("")
  line("## Checks")
  line("")
  local checks_text = tostring(checks or "no checks report")
  if fence then
    line(fence.wrap_checks(checks_text, { label = id }))
  else
    line(checks_text)
  end
  line("")
  line("## Task sheet")
  line("")
  line(tostring(sheet or "(no sheet)"))
  line("")
  line("## Rules")
  line("")
  line("- follow the plan exactly, step by step; never invent a step")
  line("- never touch protected paths: review-rules.md, AGENTS.md, .metronome/, deploy.md, or the Metronome config")
  line("- do not deploy if a step fails: stop and report exactly where")
  line("- report what you did, what you verified, and what you could not do")
  line("- a blocker is a useful result: say what stopped you")

  return table.concat(out, "\n") .. "\n"
end

-- Log ------------------------------------------------------------------------

-- The durable half of a deploy: the runner text for a human, and a small JSON
-- record for the panel. Both land under `<root>/deploy/`, next to the state.
function M.write_log(root, task_id, result, opts)
  opts = type(opts) == "table" and opts or {}
  result = type(result) == "table" and result or {}

  if not is_non_empty(root) then
    return nil, "write_log needs a root"
  end

  local id = tostring(task_id)
  local at = is_non_empty(opts.now) and opts.now or now_iso()
  local ok = result.ok == true
  local err = result.error

  local text = result.text
  if type(text) ~= "string" or trim(text) == "" then
    text = "(no output)"
  end

  local dir = fs.joinpath(root, "deploy")
  local made, mkerr = fs.mkdir(dir, { parents = true })
  if not made then
    return nil, "cannot create deploy directory: " .. tostring(mkerr)
  end

  local header = table.concat({
    "# Deploy " .. id,
    "at: " .. at,
    "ok: " .. tostring(ok),
    "error: " .. (err ~= nil and tostring(err) or "-"),
  }, "\n")

  local body = header .. "\n\n" .. text
  if body:sub(-1) ~= "\n" then
    body = body .. "\n"
  end

  local log_path = fs.joinpath(dir, id .. ".log")
  local wrote, werr = fs.write(log_path, body)
  if not wrote then
    return nil, "cannot write deploy log: " .. tostring(werr)
  end

  local payload = {
    at = at,
    task_id = task_id,
    ok = ok,
    error = err,
    text = text,
    attempts = result.attempts,
    cost = result.cost,
  }
  local encoded_ok, encoded = pcall(maki.json.encode, payload)
  if not encoded_ok or type(encoded) ~= "string" then
    return nil, "cannot encode deploy log: " .. tostring(encoded)
  end

  local json_path = fs.joinpath(dir, id .. ".json")
  local jwrote, jerr = fs.write(json_path, encoded)
  if not jwrote then
    return nil, "cannot write deploy json: " .. tostring(jerr)
  end

  return log_path, nil
end

-- Run ------------------------------------------------------------------------

-- The sheet is what qualification wrote. A caller may pass it directly; when it
-- does not, it is read from tasks_dir (or root/tasks), and a missing sheet
-- degrades to a placeholder rather than a crash.
local function read_sheet(task, root, opts)
  if type(opts.sheet) == "string" then
    return opts.sheet
  end

  local dir = opts.tasks_dir
  if not is_non_empty(dir) then
    dir = fs.joinpath(root, "tasks")
  end
  local id = tostring(task.id or "")
  if is_non_empty(dir) and id ~= "" then
    local text = fs.read(fs.joinpath(dir, id .. ".md"))
    if type(text) == "string" then
      return text
    end
  end
  return nil
end

local function read_checks_text(root, task_id)
  local text = fs.read(fs.joinpath(root, "checks", tostring(task_id) .. ".json"))
  if type(text) ~= "string" or trim(text) == "" then
    return "no checks report"
  end
  return text
end

-- Move the task to failed, recording why first. The note is appended before the
-- transition so the reason survives even if the move itself is refused.
local function fail_task(state, root, id, err)
  if type(state) == "table" and type(state.append) == "function" then
    pcall(state.append, root, {
      kind = "note",
      task_id = id,
      text = "deploy failed: " .. tostring(err),
    })
  end

  if type(state) == "table"
    and type(state.transition) == "function"
    and type(state.can_transition) == "function" then
    local loaded = type(state.load) == "function" and state.load(root) or nil
    local current = type(loaded) == "table" and type(loaded.tasks) == "table"
      and loaded.tasks[id] or nil
    local status = type(current) == "table" and current.status or nil
    if status and state.can_transition(status, "failed") then
      return state.transition(root, id, "failed", { phase = "deploy" })
    end
  end

  return nil
end

-- Deterministic plan execution ------------------------------------------------

-- A plan whose steps are fenced ```sh blocks does not need a model to run it:
-- the blocks are the exact commands, in order. Extracting them makes the
-- common deploy a few seconds instead of a full agent turn. A plan with no sh
-- block falls back to the agent, which is the only way to follow prose.
function M.plan_script(text)
  if type(text) ~= "string" then
    return nil, "no plan text"
  end
  local blocks = {}
  for body in text:gmatch("```[sS][hH]%s*\n(.-)\n%s*```") do
    if trim(body) ~= "" then
      blocks[#blocks + 1] = body
    end
  end
  if #blocks == 0 then
    return nil, "plan has no sh block"
  end
  return table.concat(blocks, "\n"), nil
end

-- Run the extracted commands with bash, in the repository, and stop on the
-- first non-zero exit. `set -e` makes a failed step stop the rest; the output
-- is kept for the deploy log.
function M.run_script(script, opts)
  opts = type(opts) == "table" and opts or {}
  local body = "set -e\n" .. tostring(script)
  local args = { "bash", "-lc", body }
  local job_opts = { cwd = opts.cwd, tail = 400 }
  local ok_start, job, err = pcall(maki.fn.jobstart, args, job_opts)
  if not ok_start then
    err = job
    job = nil
  end
  if not job and tostring(err):find("no active task", 1, true) then
    job_opts.scope = "plugin"
    local ok_retry, retry_job, retry_err = pcall(maki.fn.jobstart, args, job_opts)
    if ok_retry then
      job, err = retry_job, retry_err
    else
      job, err = nil, retry_job
    end
  end
  if not job then
    return { ok = false, error = "cannot start deploy script: " .. tostring(err) }
  end
  local result, werr = maki.fn.jobwait(job, opts.timeout_ms or 120000)
  if not result then
    return { ok = false, error = "deploy script did not finish: " .. tostring(werr) }
  end
  local code = type(result) == "table" and result.exit_code or result
  local text = type(result) == "table"
    and ((result.stdout or "") .. (result.stderr or "")) or ""
  if code ~= 0 then
    return { ok = false, error = "deploy script exited " .. tostring(code), text = text }
  end
  return { ok = true, text = text, attempts = 1, cost = 0 }
end

local function run_impl(opts)
  local state = opts.state
  local root = opts.root

  -- Resolve the task: a table, an id, or `task_id`. A task that state knows is
  -- always re-read, so the status the guard and the transition see is current.
  local task = opts.task
  local id
  if type(task) == "table" then
    id = task.id
  elseif is_non_empty(task) then
    id = task
  elseif is_non_empty(opts.task_id) then
    id = opts.task_id
  end
  if not is_non_empty(id) then
    return { ok = false, error = "run needs a task or a task id" }
  end
  if not is_non_empty(root) then
    return { ok = false, error = "run needs a state root", task_id = id }
  end
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return { ok = false, error = "run needs a state module", task_id = id }
  end

  local loaded = state.load(root)
  local stored = type(loaded) == "table" and type(loaded.tasks) == "table"
    and loaded.tasks[id] or nil
  if type(stored) == "table" then
    task = stored
  elseif type(task) ~= "table" then
    return { ok = false, error = "unknown task: " .. tostring(id), task_id = id }
  end
  task.id = id

  local allowed, gerr = M.guard(task, root, opts)
  if not allowed then
    return { ok = false, error = gerr, task_id = id }
  end

  local plan, perr = M.plan(opts)
  if not plan then
    return { ok = false, error = perr, task_id = id }
  end

  -- Confirmation comes before any state move and before the runner: an
  -- unconfirmed deploy must leave the journal exactly as it found it.
  if opts.confirm ~= false and opts.confirmed ~= true then
    return { ok = false, needs_confirmation = true, task_id = id, plan = plan }
  end

  if opts.script ~= true and type(opts.runner) ~= "function" then
    return { ok = false, error = "run needs a runner function", task_id = id }
  end

  -- merged -> deploying. A task already deploying is a resume and continues.
  if task.status == "merged" then
    local moved, merr = state.transition(root, id, "deploying", { phase = "deploy" })
    if not moved then
      return { ok = false, error = merr, task_id = id }
    end
  end

  local checks_text = read_checks_text(root, id)
  local sheet = read_sheet(task, root, opts)
  local prompt = M.prompt(task, plan, checks_text, sheet, opts)

  -- Capture the pending base before the runner runs. A merge can land during
  -- the deploy and move the flag forward; only the base we ship here may be
  -- cleared afterwards.
  local pending_before
  if type(state.deploy_pending) == "function" then
    pending_before = state.deploy_pending(root)
  end
  local pending_base = type(pending_before) == "table" and is_non_empty(pending_before.base)
    and pending_before.base or nil

  local run
  local script = opts.script == true and M.plan_script(plan) or nil
  if script then
    run = M.run_script(script, { cwd = opts.repo, timeout_ms = opts.timeout_ms })
  else
    local session_opts = type(opts.session_opts) == "table" and opts.session_opts or {}
    local called
    called, run = pcall(opts.runner, {
      role = "deployer",
      task_id = id,
      phase = "deploy",
      prompt = prompt,
      system = session_opts.system,
      model_spec = session_opts.model_spec,
      thinking = session_opts.thinking,
      tools = session_opts.tools,
      state_root = opts.state_root,
      ctx = opts.ctx,
    })
    if not called then
      run = { ok = false, error = tostring(run) }
    elseif type(run) ~= "table" then
      run = { ok = false, error = "runner returned no result" }
    end
  end

  if not run.ok then
    local reason = run.error or "runner failed"
    fail_task(state, root, id, reason)
    local log = M.write_log(root, id, {
      ok = false,
      error = reason,
      text = run.text,
      attempts = run.attempts,
      cost = run.cost,
    }, opts)
    return { ok = false, error = reason, log = log, run = run, task_id = id }
  end

  local final, ferr = state.transition(root, id, "deployed", { phase = "deploy" })
  if not final then
    local log = M.write_log(root, id, {
      ok = false,
      error = ferr,
      text = run.text,
      attempts = run.attempts,
      cost = run.cost,
    }, opts)
    return { ok = false, error = ferr, log = log, run = run, task_id = id }
  end

  if type(state.append) == "function" then
    pcall(state.append, root, { kind = "note", task_id = id, text = "deployed" })
  end

  -- A successful deploy drains the base it shipped — but only if the flag
  -- still holds that same base. A merge that landed during the run already
  -- moved the flag to a newer base; clearing it here would lose the follow-up.
  if pending_base and type(state.clear_deploy_pending) == "function" then
    local current = type(state.deploy_pending) == "function"
      and state.deploy_pending(root) or nil
    local current_base = type(current) == "table" and current.base or nil
    if current_base == pending_base then
      pcall(state.clear_deploy_pending, root)
    end
  end

  local log = M.write_log(root, id, {
    ok = true,
    error = nil,
    text = run.text,
    attempts = run.attempts,
    cost = run.cost,
  }, opts)

  return { ok = true, deployed = true, log = log, run = run, task_id = id }
end

-- A deploy is a chain of injected calls; any one of them could raise. The
-- contract is a result table, so the unexpected becomes `{ ok = false }`.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(run_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

-- Drain ----------------------------------------------------------------------

-- Merges arrive faster than deploys run, so a merge does not start a deployer:
-- it records the base it produced in the pending flag (state.lua) and a single
-- drainer drains it. Three rules make that safe:
--
--   * single-flight — the drainer takes the deploy lock first; a second drainer
--     that finds the lock held does not queue and does not touch the flag. The
--     holder will see the newer base and do the follow-up itself.
--   * coalescing — the flag holds one base, and a merge overwrites it. Merges
--     that land while a deploy runs only move the flag forward, so the drainer
--     sees one newer base and runs exactly one follow-up, never one per merge.
--   * draining — a base is cleared only after a runner actually ran for it, and
--     only if the flag still holds that same base.
--
-- The flag records only a commit, so the drainer must be told which task that
-- base belongs to. An injected `resolve` (the pipeline knows which merge
-- produced the base) wins; then an explicit task/task_id. There is no guess:
-- a base that maps to no task is a refusal, and the flag is left alone.
local function resolve_pending_task(pending, opts)
  local base = type(pending) == "table" and pending.base or nil

  if type(opts.resolve) == "function" then
    local called, value = pcall(opts.resolve, pending)
    if not called then
      return nil, "cannot resolve the pending base: " .. tostring(value)
    end
    if type(value) == "table" and is_non_empty(value.id) then
      return value.id, nil
    end
    if is_non_empty(value) then
      return value, nil
    end
    return nil, "no task for the pending base " .. tostring(base)
  end

  if type(opts.task) == "table" and is_non_empty(opts.task.id) then
    return opts.task.id, nil
  end
  if is_non_empty(opts.task) then
    return opts.task, nil
  end
  if is_non_empty(opts.task_id) then
    return opts.task_id, nil
  end

  return nil, "no task for the pending base " .. tostring(base)
end

-- The work while the lock is held. Never releases the lock; the caller does.
local function drain_locked(state, root, pending, opts)
  local base = pending.base
  local out = { base = base }

  local id, rerr = resolve_pending_task(pending, opts)
  if not id then
    out.ok = false
    out.error = rerr
    out.deferred = true
    return out
  end
  out.task_id = id

  local run_opts = {}
  for key, value in pairs(opts) do
    run_opts[key] = value
  end
  run_opts.task = nil
  run_opts.task_id = id
  run_opts.resolve = nil

  local result = M.run(run_opts)
  out.ok = result.ok == true
  out.error = result.error
  out.deployed = result.deployed
  out.needs_confirmation = result.needs_confirmation
  out.log = result.log
  out.run = result.run
  out.deploy = result

  -- A runner only runs after the guard and the plan: no `run` means the base
  -- was never attempted (refused, unconfirmed, or blocked early), so the flag
  -- must survive for the next drainer.
  if result.run == nil then
    out.deferred = true
    return out
  end

  -- Coalescing: a merge during the run only moved the flag forward. Clear the
  -- base we drained; if a newer one replaced it, leave it for the one follow-up.
  local latest = state.deploy_pending(root)
  if type(latest) ~= "table" or not is_non_empty(latest.base) then
    out.drained = true
    return out
  end
  if latest.base ~= base then
    out.follow_up = true
    out.follow_up_base = latest.base
    return out
  end

  local cleared, cerr = state.clear_deploy_pending(root)
  if cleared then
    out.drained = true
  else
    out.clear_error = cerr
  end
  return out
end

local function drain_impl(opts)
  local state = opts.state
  local root = opts.root

  if type(state) ~= "table" or type(state.load) ~= "function" then
    return { ok = false, error = "drain needs a state module" }
  end
  if not is_non_empty(root) then
    return { ok = false, error = "drain needs a state root" }
  end
  if type(state.acquire_deploy) ~= "function"
    or type(state.release_deploy) ~= "function"
    or type(state.deploy_pending) ~= "function"
    or type(state.clear_deploy_pending) ~= "function" then
    return { ok = false, error = "drain needs the deploy lock in state" }
  end

  local owner = is_non_empty(opts.owner) and opts.owner or "deployer"

  -- Single-flight: the lock is taken before the flag is even read. A deployer
  -- that loses the race reports the holder and leaves everything untouched.
  local lock, lerr = state.acquire_deploy(root, owner, { force = opts.force })
  if not lock then
    return { ok = false, locked = true, single_flight = true, owner = owner, error = lerr }
  end

  local pending = state.deploy_pending(root)
  local result
  if type(pending) ~= "table" or not is_non_empty(pending.base) then
    result = { ok = false, no_pending = true, error = "no deploy pending" }
  else
    local ran, value = pcall(drain_locked, state, root, pending, opts)
    if ran and type(value) == "table" then
      result = value
    elseif ran then
      result = { ok = false, error = "drain returned no result" }
    else
      result = { ok = false, error = tostring(value) }
    end
  end

  local released, rerr = state.release_deploy(root, owner, { force = opts.force })
  result.owner = owner
  result.lock_released = released and true or false
  if not released then
    result.release_error = rerr
  end
  return result
end

-- Drain at most one base. The contract mirrors M.run: a result table, never a
-- raise. `locked` means another deployer holds the lock, `no_pending` means
-- there was nothing to do, `deferred` means the flag was left for a later
-- drain, `drained` means the flag was cleared, and `follow_up` means a newer
-- base arrived during the run and exactly one more drain is owed.
function M.drain(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(drain_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

return M
