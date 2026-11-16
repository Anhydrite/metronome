-- Merge: rebase onto the fresh base, squash-merge the PR, re-run the checks.
--
-- This is the last step that can still fail. The branch is first rebased onto
-- what the remote has now, so the merge is against the current base and not the
-- one the task was cut from. The PR is then merged through `gh`, and the
-- declared checks are re-run on a throwaway checkout of the merged base: a
-- merge that lands a red base is worse than a merge that never happened.
--
-- A successful merge stops at `merged`. The base it produced is written to the
-- persistent deploy-pending flag for a deployer to drain; merge never triggers
-- or waits for a deployment.
--
-- Every function returns `(value, err)` and never raises. git, state, checks
-- and the session options are injected, so the module is pure Lua and the whole
-- step is testable against a throwaway repository and a fake `gh`.

local M = {}

local fs = maki.fs

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

-- The three flags `gh pr merge` accepts, and nothing else: a typo must be
-- refused before a command is sent, not merged with the wrong strategy.
local METHOD_FLAGS = {
  squash = "--squash",
  merge = "--merge",
  rebase = "--rebase",
}

-- jobstart raises (rather than returning nil) when there is no active task to
-- own the job, which happens at plugin top level. Retrying with a plugin scope
-- keeps the same code usable from a tool handler and from a test. This mirrors
-- git.lua's runner, but for `gh`, whose result shape git.classify understands.
local function exec(args, cwd, timeout_ms)
  local job_opts = {
    cwd = cwd,
    tail = 200,
  }
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
    return nil, "cannot start gh: " .. tostring(err)
  end
  local result, werr = maki.fn.jobwait(job, timeout_ms or 60000)
  if not result then
    return nil, "gh did not finish: " .. tostring(werr)
  end
  return {
    code = result.exit_code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
    command = table.concat(args, " "),
    ok = result.exit_code == 0,
  }
end

-- Rebase ---------------------------------------------------------------------

-- Rebase the task branch onto the freshest base before merging.
--
-- `auto_rebase = false` is a deliberate skip, not a failure: the caller gets
-- `{ ok = true, skipped = true }` and the merge proceeds on the branch as-is.
function M.rebase(opts)
  opts = type(opts) == "table" and opts or {}

  if opts.auto_rebase == false then
    return { ok = true, skipped = true }
  end

  local git = opts.git
  if type(git) ~= "table" or type(git.fetch) ~= "function" or type(git.rebase) ~= "function" then
    return nil, "rebase needs a git module with fetch and rebase"
  end
  if not is_non_empty(opts.repo) then
    return nil, "rebase needs a repo"
  end
  if not is_non_empty(opts.worktree) then
    return nil, "rebase needs a worktree"
  end
  if not fs.metadata(opts.worktree) then
    return nil, "worktree is gone: " .. tostring(opts.worktree)
      .. " (re-implement the task before merging)"
  end

  local remote = is_non_empty(opts.remote) and opts.remote or "origin"
  local base = is_non_empty(opts.base) and opts.base or "main"
  local upstream = remote .. "/" .. base

  local fetched, ferr = git.fetch(opts.repo, remote)
  if not fetched then
    return nil, ferr
  end

  local sha, rerr, info = git.rebase(opts.worktree, upstream)
  if not sha then
    -- A conflict is not a generic failure: the caller can repair it by moving
    -- the branch back to the fresh base and redoing the work there.
    return nil, rerr, { conflict = info and info.conflict or nil }
  end

  return { ok = true, base = upstream, sha = sha }
end

-- Merge the PR ---------------------------------------------------------------

-- Squash-merge (by default) the PR through `gh`, then read it back.
--
-- The read-back is the verdict, not the exit code: `gh` can exit 0 while the PR
-- is still open (a queued auto-merge, for instance), and a task that claims
-- merged before GitHub agrees is a lie the next step would inherit. An
-- "already merged" failure is the one failure that is really a success.
function M.merge_pr(opts)
  opts = type(opts) == "table" and opts or {}

  local git = opts.git
  if type(git) ~= "table"
    or type(git.classify) ~= "function"
    or type(git.describe) ~= "function"
    or type(git.pr_view) ~= "function" then
    return nil, "merge_pr needs a git module with classify, describe and pr_view"
  end

  local pr = opts.pr
  if pr == nil or (type(pr) == "string" and trim(pr) == "") then
    return nil, "merge_pr needs a pull request"
  end
  if not is_non_empty(opts.worktree) then
    return nil, "merge_pr needs a worktree"
  end
  if not fs.metadata(opts.worktree) then
    return nil, "worktree is gone: " .. tostring(opts.worktree)
      .. " (re-implement the task before merging)"
  end

  local method = is_non_empty(opts.method) and opts.method or "squash"
  local flag = METHOD_FLAGS[method]
  if not flag then
    return nil, "unknown merge method: " .. tostring(method)
  end

  local gh = is_non_empty(opts.gh) and opts.gh or "gh"
  local args = { gh, "pr", "merge", tostring(pr), flag }

  local result, rerr = exec(args, opts.worktree, opts.timeout_ms)
  if not result then
    return nil, rerr
  end

  if not result.ok then
    local diag = git.classify("gh pr merge", result)
    if diag.cause == "already_merged" then
      return { ok = true, state = "merged", already_merged = true }
    end
    return nil, git.describe(diag), diag
  end

  local info, ierr = git.pr_view(pr, { gh = gh, worktree = opts.worktree })
  if not info then
    return nil, ierr
  end
  if info.state ~= "merged" then
    return nil, string.format("merge command succeeded but PR state is %s", tostring(info.state))
  end

  return { ok = true, state = "merged" }
end

-- Verify after merge ---------------------------------------------------------

-- Re-run the declared checks on the merged base, in a detached worktree.
--
-- The checkout is detached on purpose: it must never claim a branch, and it is
-- a throwaway that is always removed, even when the checks are red. A removal
-- that fails is reported on the result as `cleanup_error` rather than hidden.
function M.verify_after_merge(opts)
  opts = type(opts) == "table" and opts or {}

  local git = opts.git
  if type(git) ~= "table"
    or type(git.fetch) ~= "function"
    or type(git.worktree_list) ~= "function"
    or type(git.worktree_add) ~= "function"
    or type(git.worktree_remove) ~= "function" then
    return nil, "verify_after_merge needs a git module with fetch, worktree_list, worktree_add and worktree_remove"
  end

  local checks = opts.checks
  if type(checks) ~= "table" or type(checks.run) ~= "function" then
    return nil, "verify_after_merge needs a checks module with run"
  end

  if not is_non_empty(opts.repo) then
    return nil, "verify_after_merge needs a repo"
  end
  if not is_non_empty(opts.root) then
    return nil, "verify_after_merge needs a root"
  end
  if not is_non_empty(opts.task_id) then
    return nil, "verify_after_merge needs a task_id"
  end

  local remote = is_non_empty(opts.remote) and opts.remote or "origin"
  local base = is_non_empty(opts.base) and opts.base or "main"

  local fetched, ferr = git.fetch(opts.repo, remote)
  if not fetched then
    return nil, ferr
  end

  local dir = fs.joinpath(opts.root, "merge-check")
  local made, mkerr = fs.mkdir(dir, { parents = true })
  if not made then
    return nil, "cannot create merge-check directory: " .. tostring(mkerr)
  end
  local temp = fs.joinpath(dir, tostring(opts.task_id))

  -- A previous run may have died before its cleanup: remove the stale worktree
  -- before adding a new one, or `worktree add` refuses the path.
  local listed, lerr = git.worktree_list(opts.repo)
  if not listed then
    return nil, lerr
  end
  for _, path in ipairs(listed) do
    if path == temp then
      local removed, rm_err = git.worktree_remove(opts.repo, temp, { force = true })
      if not removed then
        return nil, rm_err
      end
    end
  end

  local added, aerr = git.worktree_add(opts.repo, temp, nil, remote .. "/" .. base, { detach = true })
  if not added then
    return nil, aerr
  end

  local result, cerr = checks.run(opts.commands or {}, {
    worktree = temp,
    timeout_ms = opts.timeout_ms,
  })

  -- The temp worktree is removed whatever the verdict: a red base must not
  -- leave a checkout behind for the next run to trip over.
  local removed, rm_err = git.worktree_remove(opts.repo, temp, { force = true })
  if not result then
    if not removed then
      return nil, string.format("%s; cleanup failed: %s", tostring(cerr), tostring(rm_err))
    end
    return nil, cerr
  end
  if not removed then
    result.cleanup_error = rm_err or "cannot remove the temp worktree"
  end

  return result
end

-- Run ------------------------------------------------------------------------

-- Move the task to failed, recording why first. The note is appended before the
-- transition so the reason survives even if the move itself is refused.
local function fail_task(state, root, id, err)
  if type(state) == "table" and type(state.append) == "function" then
    pcall(state.append, root, {
      kind = "note",
      task_id = id,
      text = "merge failed: " .. tostring(err),
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
      return state.transition(root, id, "failed", { phase = "merge" })
    end
  end

  return nil
end

local function run_impl(opts)
  local git = opts.git
  local state = opts.state
  if type(git) ~= "table" then
    return { ok = false, error = "git module is required" }
  end
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return { ok = false, error = "state module is required" }
  end
  if not is_non_empty(opts.root) then
    return { ok = false, error = "run needs a state root" }
  end
  local root = opts.root

  -- Resolve the task: a table, an id, or `task_id`. A task that state knows is
  -- always re-read, so the status the transition sees is the current one.
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

  local loaded = state.load(root)
  local stored = type(loaded) == "table" and type(loaded.tasks) == "table"
    and loaded.tasks[id] or nil
  if type(stored) == "table" then
    task = stored
  elseif type(task) ~= "table" then
    return { ok = false, error = "unknown task: " .. tostring(id) }
  end
  task.id = id

  local worktree = is_non_empty(opts.worktree) and opts.worktree or task.worktree
  if not is_non_empty(worktree) then
    return { ok = false, error = "run needs a worktree" }
  end

  -- The PR may be passed explicitly, or come from the task it was stored on.
  local pr = opts.pr
  if pr == nil or (type(pr) == "string" and trim(pr) == "") then
    if type(task.pr) == "table" then
      pr = task.pr.number or task.pr.url
    else
      pr = task.pr
    end
  end
  if pr == nil or (type(pr) == "string" and trim(pr) == "") then
    return { ok = false, error = "run needs a pull request" }
  end

  -- pr_open -> merging. Any other status is refused by name: a task that is
  -- already merged (or never reached the PR) must not be merged twice.
  local status = task.status
  if status == "pr_open" then
    local moved, merr = state.transition(root, id, "merging", { phase = "merge" })
    if not moved then
      return { ok = false, error = merr }
    end
    status = moved.status
  end
  if status ~= "merging" then
    return { ok = false, error = "cannot merge from " .. tostring(status) }
  end

  local base = is_non_empty(opts.base) and opts.base
    or (is_non_empty(task.base_ref) and task.base_ref or "main")
  local remote = is_non_empty(opts.remote) and opts.remote or "origin"

  -- Rebase onto the fresh base.
  local rebase, rerr, rinfo = M.rebase({
    git = git,
    repo = opts.repo,
    worktree = worktree,
    base = base,
    remote = remote,
    auto_rebase = opts.auto_rebase,
  })
  if not rebase then
    local conflict = rinfo and rinfo.conflict or nil
    fail_task(state, root, id, rerr)
    return {
      ok = false,
      error = rerr,
      rebase = rebase,
      conflict = conflict,
      conflict_files = conflict and table.concat(conflict, ", ") or nil,
    }
  end

  -- Merge the PR.
  local merged, mg_err = M.merge_pr({
    git = git,
    gh = opts.gh,
    pr = pr,
    worktree = worktree,
    method = opts.method,
    timeout_ms = opts.timeout_ms,
  })
  if not merged then
    fail_task(state, root, id, mg_err)
    return { ok = false, error = mg_err, rebase = rebase, merge = merged }
  end

  -- Record the merged PR on the task, keeping the fields it already had.
  local existing = type(task.pr) == "table" and task.pr or {}
  local pr_number = existing.number
  local pr_url = existing.url
  if pr_number == nil and tonumber(pr) then
    pr_number = math.floor(tonumber(pr))
  end
  if pr_url == nil and type(pr) == "string" and pr:match("^https?://") then
    pr_url = pr
  end
  if pr_number == nil or pr_url == nil then
    local perr = "task has no PR number/url to record"
    fail_task(state, root, id, perr)
    return { ok = false, error = perr, rebase = rebase, merge = merged }
  end

  local stored_task, serr = state.set_fields(root, id, {
    pr = { number = pr_number, url = pr_url, state = "merged" },
  })
  if not stored_task then
    fail_task(state, root, id, serr)
    return { ok = false, error = serr, rebase = rebase, merge = merged }
  end

  -- The PR is merged: the task branch has no reason to survive. Remove the
  -- worktree first (the branch is checked out there, and git refuses to delete
  -- a checked-out branch), then delete the branch on the remote and locally.
  -- A cleanup failure is reported on the result, never turned into a failed
  -- task: the merge already happened, and a merged task must stay merged.
  local branch_cleanup = nil
  if opts.delete_branch ~= false then
    local branch = is_non_empty(task.branch) and task.branch or nil
    if branch then
      if is_non_empty(worktree) and type(git.worktree_remove) == "function" then
        pcall(git.worktree_remove, opts.repo, worktree, { force = true })
      end
      if type(git.delete_branch) == "function" then
        branch_cleanup = git.delete_branch(opts.repo, branch, {
          remote = remote,
          timeout_ms = opts.timeout_ms,
        })
      end
    end
  end

  -- Re-run the checks on the merged base, unless the caller opted out.
  local checks_result = nil
  if opts.verify ~= false then
    local commands = opts.commands
    if commands == nil then
      commands = type(task.checks) == "table" and task.checks or {}
    end
    local cres, cverr = M.verify_after_merge({
      git = git,
      checks = opts.checks,
      repo = opts.repo,
      root = root,
      task_id = id,
      base = base,
      remote = remote,
      commands = commands,
      timeout_ms = opts.timeout_ms,
    })
    if not cres then
      fail_task(state, root, id, cverr)
      return { ok = false, error = cverr, rebase = rebase, merge = merged, checks = cres, branch_cleanup = branch_cleanup }
    end
    checks_result = cres
    if cres.ok == false then
      fail_task(state, root, id, "post-merge checks failed")
      return {
        ok = false,
        error = "post-merge checks failed",
        rebase = rebase,
        merge = merged,
        checks = cres,
        branch_cleanup = branch_cleanup,
      }
    end
  end

  -- Record the base this merge produced as the thing a deployer must drain.
  -- Merge owns the merge and nothing else: it never triggers or waits for a
  -- deploy, it hands the base off through the persistent deploy-pending flag
  -- and returns at `merged`. Recording it before the transition means a task
  -- that cannot be marked merged is retried rather than silently undeployed.
  --
  -- A subtask merging into an epic branch opts out (`deploy_pending = false`):
  -- the epic branch is not a deployable base, and marking it pending would
  -- have the deployer ship work that never reached the project base.
  local pending = nil
  if opts.deploy_pending == false then
    local final, ferr = state.transition(root, id, "merged", { phase = "merge" })
    if not final then
      return {
        ok = false,
        error = ferr,
        rebase = rebase,
        merge = merged,
        checks = checks_result,
        branch_cleanup = branch_cleanup,
      }
    end
    return {
      ok = true,
      rebase = rebase,
      merge = merged,
      checks = checks_result,
      branch_cleanup = branch_cleanup,
    }
  end
  if type(state.set_deploy_pending) ~= "function" then
    return {
      ok = false,
      error = "state module cannot record a deploy-pending base",
      rebase = rebase,
      merge = merged,
      checks = checks_result,
      branch_cleanup = branch_cleanup,
    }
  end
  local perr
  pending, perr = state.set_deploy_pending(root, base)
  if not pending then
    return {
      ok = false,
      error = perr,
      rebase = rebase,
      merge = merged,
      checks = checks_result,
      branch_cleanup = branch_cleanup,
    }
  end

  local final, ferr = state.transition(root, id, "merged", { phase = "merge" })
  if not final then
    return {
      ok = false,
      error = ferr,
      rebase = rebase,
      merge = merged,
      checks = checks_result,
      branch_cleanup = branch_cleanup,
      deploy_pending = pending,
    }
  end

  return {
    ok = true,
    rebase = rebase,
    merge = merged,
    checks = checks_result,
    branch_cleanup = branch_cleanup,
    deploy_pending = pending,
  }
end

-- A merge is a chain of injected calls; any one of them could raise. The
-- contract is a result table, so the unexpected becomes `{ ok = false }`.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(run_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

return M
