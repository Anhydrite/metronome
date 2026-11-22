-- Git operations for Metronome.
--
-- Every task works in its own worktree, cut from a freshly fetched base, so
-- two tasks never touch the same working tree. This module is the only place
-- that shells out to git, which keeps the command shapes in one file and makes
-- them testable against a throwaway repository.
--
-- All functions return `(value, err)` and never raise: a pipeline that dies on
-- a git error cannot report what went wrong.

local M = {}

-- git's messages are parsed, not just shown: classify() matches English
-- strings ("nothing to commit", "a branch named", "already registered",
-- "non-fast-forward", ...). A child that inherits the user's locale would
-- answer those questions in fr_FR and the classification would silently miss.
-- maki.fn.jobstart has no option to merge extra variables into the inherited
-- environment, so the argv is prefixed with `env LC_ALL=C LANG=C`: the locale
-- is pinned for the child while every inherited variable (HOME, PATH, GIT_*)
-- survives untouched.
local LOCALE_PREFIX = { "env", "LC_ALL=C", "LANG=C" }

local function with_c_locale(args)
  local argv = {}
  for i = 1, #LOCALE_PREFIX do
    argv[i] = LOCALE_PREFIX[i]
  end
  for i = 1, #args do
    argv[#argv + 1] = args[i]
  end
  return argv
end

local function run(args, opts)
  opts = opts or {}
  local argv = with_c_locale(args)
  local job_opts = {
    cwd = opts.cwd,
    tail = opts.tail or 200,
  }
  -- jobstart raises (rather than returning nil) when there is no active task
  -- to own the job, which happens at plugin top level. Retrying with a plugin
  -- scope keeps the same code usable from a tool handler, where the task scope
  -- is right, and from a test or a startup hook.
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
    return nil, "cannot start git: " .. tostring(err)
  end
  local result, werr = maki.fn.jobwait(job, opts.timeout_ms or 60000)
  if not result then
    return nil, "git did not finish: " .. tostring(werr)
  end
  return {
    code = result.exit_code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
    -- The locale prefix is an implementation detail of the child; the command
    -- a diagnostic names stays the git command the caller asked for.
    command = table.concat(args, " "),
    ok = result.exit_code == 0,
  }
end

M.run = run

-- A git failure is reported with the command, the exit code and stderr: the
-- caller needs to know which step failed, not just that something did.

local function first_line(text)
  for line in (text or ""):gmatch("[^\n]+") do
    local trimmed = line:gsub("%s+$", "")
    if trimmed:match("%S") then
      return trimmed
    end
  end
  return nil
end

-- `git push` writes "To <url>" first and the reason after it, so the first
-- line alone hides why the push was refused. For a push, report the first few
-- meaningful lines instead.
local function detail_of(what, stderr)
  if what ~= "push" then
    return first_line(stderr)
  end
  local parts = {}
  for line in (stderr or ""):gmatch("[^\n]+") do
    local trimmed = line:gsub("%s+$", "")
    if trimmed:match("%S") and not trimmed:match("^To ") then
      parts[#parts + 1] = trimmed
    end
    if #parts >= 3 then
      break
    end
  end
  return #parts > 0 and table.concat(parts, " / ") or nil
end

-- Turn a failed command into a cause a caller can branch on. The causes are
-- the four situations a task pipeline actually hits -- a stale worktree, a
-- stale branch, a refused push, an unreachable remote -- plus auth and a
-- catch-all, so a failure is never just "git failed".
function M.classify(what, result)
  result = result or {}
  local stderr = result.stderr or ""
  local stdout = result.stdout or ""
  local haystack = stderr .. "\n" .. stdout
  local function has(needle)
    return haystack:find(needle, 1, true) ~= nil
  end

  local cause, message, hint
  if what == "worktree add" then
    if has("a branch named") then
      cause = "branch_exists"
      message = "the task branch already exists"
      hint = "delete the stale branch or use a fresh task id"
    elseif has("already registered") or has("already exists") then
      cause = "worktree_exists"
      message = "the worktree path is already present"
      hint = "remove it with `git worktree remove --force <path>`"
    end
  elseif what == "push" or what == "fetch" then
    -- A missing remote also makes git complain that it cannot read from it, so
    -- this check must come before the push-rejection one.
    if has("does not appear to be a git repository")
      or has("Could not read from remote repository")
      or has("No such remote") then
      cause = "remote_missing"
      message = "the remote is not reachable"
      hint = "check the remote name/URL with `git remote -v`"
    elseif what == "push" and (has("non-fast-forward") or has("[rejected]")
      or has("failed to push some refs") or has("fetch first")) then
      cause = "push_rejected"
      message = "the remote rejected the push"
      hint = "fetch and rebase the task branch, then push again"
    elseif has("Permission denied") or has("Authentication failed") or has("could not read Username") then
      cause = "auth_failed"
      message = "git could not authenticate with the remote"
      hint = "check the credentials or SSH key for this remote"
    end
  elseif what == "gh pr merge" then
    -- `gh pr merge` fails in four ways the pipeline can act on: the PR was
    -- already merged (nothing to do), it cannot be merged (conflicts or a
    -- protected branch), its required checks are not green, or `gh` is not
    -- authenticated. Anything else falls through to the catch-all.
    if has("already merged") then
      cause = "already_merged"
      message = "the pull request is already merged"
      hint = "nothing to do"
    elseif has("not mergeable") or has("conflicts") or has("cannot be merged") then
      cause = "not_mergeable"
      message = "the pull request cannot be merged"
      hint = "rebase the branch and resolve conflicts"
    elseif has("required status check") or has("checks") then
      cause = "checks_failed"
      message = "required checks are not green"
      hint = "wait for or fix the required checks"
    elseif has("not logged in") or has("authentication") or has("gh auth login") or has("HTTP 401") then
      cause = "auth_failed"
      message = "gh is not authenticated"
      hint = "run `gh auth login`"
    end
  elseif what == "gh pr create" or what == "gh pr view" then
    -- `gh` speaks its own dialect: a duplicate PR, a missing token and an
    -- unreachable repository are the three the pipeline can actually act on.
    if has("already exists") then
      cause = "pr_exists"
      message = "a pull request already exists for this branch"
      hint = "reuse the existing PR or push to a new branch"
    elseif has("not logged in") or has("authentication") or has("gh auth login") or has("HTTP 401") then
      cause = "auth_failed"
      message = "gh is not authenticated"
      hint = "run `gh auth login`"
    elseif has("Could not resolve to a Repository")
      or has("not a git repository")
      or has("no git remotes") then
      cause = "remote_missing"
      message = "the GitHub repository is not reachable"
      hint = "check the git remote and that the repository exists"
    end
  end

  if not cause then
    cause = "git_error"
    message = tostring(what) .. " failed"
    hint = "inspect the command output and retry"
  end

  return {
    cause = cause,
    what = what,
    code = result.code,
    command = result.command,
    message = message,
    hint = hint,
    detail = detail_of(what, stderr) or first_line(stdout) or "no output",
  }
end

-- One line a human can read in a log or a panel: what failed, why, and what to
-- do about it.
function M.describe(diag)
  diag = diag or {}
  return string.format("%s failed [%s]: %s — %s (exit %s: %s)",
    tostring(diag.what), tostring(diag.cause), tostring(diag.message),
    tostring(diag.hint), tostring(diag.code), tostring(diag.detail))
end

local function fail(what, result)
  local diag = M.classify(what, result)
  return nil, M.describe(diag), diag
end

-- Record a git failure on a task: the note first, so the reason survives even
-- if the transition itself is refused, then the move to failed.
function M.fail_task(state, root, task_id, diag, opts)
  opts = opts or {}
  diag = diag or {}
  local text = string.format("git failure [%s]: %s — %s (%s)",
    tostring(diag.cause), tostring(diag.message), tostring(diag.hint),
    tostring(diag.detail))
  local note_ok, note_err = state.append(root, {
    kind = "note",
    task_id = task_id,
    text = text,
  })
  local task, terr = state.transition(root, task_id, "failed", { phase = opts.phase })
  if task then
    return task
  end
  if not note_ok then
    return nil, string.format("note append failed: %s; transition failed: %s",
      tostring(note_err), tostring(terr))
  end
  return nil, terr
end

-- Branch and message shapes -------------------------------------------------

function M.branch_name(prefix, task_id)
  return (prefix or "metronome/") .. tostring(task_id)
end

-- Conventional commits keep the history readable and let tooling group
-- changes. The subject is trimmed to one line; the body keeps the rest.
function M.conventional(kind, scope, subject, body)
  local head = tostring(subject or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if head == "" then
    return nil, "commit subject is empty"
  end
  local line
  if scope and scope ~= "" then
    line = string.format("%s(%s): %s", kind, scope, head)
  else
    line = string.format("%s: %s", kind, head)
  end
  if body and body ~= "" then
    return line .. "\n\n" .. body
  end
  return line
end

-- Repository checks ---------------------------------------------------------

function M.is_repo(path)
  local result, err = run({ "git", "-C", path, "rev-parse", "--is-inside-work-tree" })
  if not result then
    return false, err
  end
  if not result.ok then
    return false, "not a git repository: " .. tostring(path)
  end
  return true
end

function M.current_branch(path)
  local result, err = run({ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("rev-parse HEAD", result)
  end
  return (result.stdout:gsub("%s+$", ""))
end

-- Fetch the base so a new task starts from what the remote has now, not from
-- whatever this checkout happened to hold.
function M.fetch(repo, remote)
  local result, err = run({ "git", "-C", repo, "fetch", remote or "origin", "--prune" })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("fetch", result)
  end
  return true
end

-- Create an isolated worktree on a new branch, cut from the freshest base.
--
-- `opts.existing = true` checks out a branch that already exists instead of
-- creating it. That is how a task re-attaches its worktree after one was
-- removed: the branch survived the worktree, so there is no `-b` and no
-- remote prefix.
function M.worktree_add(repo, worktree, branch, base_ref, opts)
  opts = opts or {}
  local args
  local base = base_ref or "HEAD"
  if opts.remote and opts.remote ~= "" then
    base = opts.remote .. "/" .. base
  end
  if opts.detach then
    -- No branch and no `-b`: the post-merge checks run on a throwaway checkout
    -- of the fresh base, which must never claim a branch name.
    args = { "git", "-C", repo, "worktree", "add", "--detach", worktree, base }
  elseif opts.existing then
    args = { "git", "-C", repo, "worktree", "add", worktree, branch }
  else
    args = { "git", "-C", repo, "worktree", "add", "-b", branch, worktree, base }
  end
  local result, err = run(args)
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("worktree add", result)
  end
  return worktree
end

-- Drop registrations whose directory no longer exists. A reset state root or a
-- crashed run leaves `.git/worktrees/<id>` behind without the checkout, and
-- `git worktree add` then refuses the path as "already registered" while
-- `rev-parse` fails on the missing directory. Pruning is what lets a task
-- re-attach after its worktree was removed.
function M.worktree_prune(repo, opts)
  opts = opts or {}
  local args = { "git", "-C", repo, "worktree", "prune" }
  if opts.dry_run then
    args[#args + 1] = "--dry-run"
  end
  local result, err = run(args)
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("worktree prune", result)
  end
  return true
end

function M.worktree_remove(repo, worktree, opts)
  opts = opts or {}
  local args = { "git", "-C", repo, "worktree", "remove" }
  if opts.force then
    args[#args + 1] = "--force"
  end
  args[#args + 1] = worktree
  local result, err = run(args)
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("worktree remove", result)
  end
  return true
end

-- Delete a merged task branch locally and on the remote.
--
-- A branch that is already gone is not an error: the merge is the fact, the
-- cleanup is housekeeping. The result reports each side separately so the
-- caller can surface a real failure (auth, protected branch) without turning a
-- successful merge into a failed task.
function M.delete_branch(repo, branch, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "delete_branch needs a repo"
  end
  if type(branch) ~= "string" or branch == "" then
    return nil, "delete_branch needs a branch"
  end
  local remote = type(opts.remote) == "string" and opts.remote ~= "" and opts.remote or "origin"
  local out = { ok = true, branch = branch, remote = remote }

  local rres, rerr = run({ "git", "-C", repo, "push", remote, "--delete", branch },
    { timeout_ms = opts.timeout_ms })
  if not rres then
    out.remote_error = rerr
  elseif rres.ok then
    out.remote_deleted = true
  else
    local text = tostring(rres.stdout or "") .. tostring(rres.stderr or "")
    if text:find("remote ref does not exist", 1, true) then
      out.remote_missing = true
    else
      out.remote_error = first_line(rres.stderr) or first_line(rres.stdout) or "cannot delete remote branch"
    end
  end

  local lres, lerr = run({ "git", "-C", repo, "branch", "-D", branch },
    { timeout_ms = opts.timeout_ms })
  if not lres then
    out.local_error = lerr
  elseif lres.ok then
    out.local_deleted = true
  else
    local text = tostring(lres.stdout or "") .. tostring(lres.stderr or "")
    if text:find("not found", 1, true) then
      out.local_missing = true
    else
      out.local_error = first_line(lres.stderr) or first_line(lres.stdout) or "cannot delete local branch"
    end
  end

  return out
end

function M.worktree_list(repo)
  local result, err = run({ "git", "-C", repo, "worktree", "list", "--porcelain" })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("worktree list", result)
  end
  local paths = {}
  for line in result.stdout:gmatch("[^\n]+") do
    local path = line:match("^worktree%s+(.+)$")
    if path then
      paths[#paths + 1] = path
    end
  end
  return paths
end

-- Commit everything staged in the worktree.
function M.commit(worktree, message)
  if type(message) ~= "string" or message:match("^%s*$") then
    return nil, "commit message is empty"
  end
  local added, aerr = run({ "git", "-C", worktree, "add", "-A" })
  if not added then
    return nil, aerr
  end
  if not added.ok then
    return fail("git add", added)
  end
  local committed, cerr = run({ "git", "-C", worktree, "commit", "-m", message })
  if not committed then
    return nil, cerr
  end
  if not committed.ok then
    -- An empty commit is a normal outcome for a no-op task, not a crash.
    if committed.stdout:find("nothing to commit", 1, true) or committed.stderr:find("nothing to commit", 1, true) then
      return nil, "nothing to commit"
    end
    return fail("git commit", committed)
  end
  return M.head_sha(worktree)
end

-- How many commits the local `base` has that `remote/base` does not. A
-- positive count means the local base diverged from what the pipeline treats
-- as the truth (the remote base every worktree is cut from and every PR merges
-- into). Running on a diverged base makes the qualifier describe files the
-- worktree will not contain, so the caller must refuse rather than guess.
function M.ahead_count(repo, base, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" or type(base) ~= "string" or base == "" then
    return nil, "ahead_count needs a repo and a base"
  end
  local remote = (type(opts.remote) == "string" and opts.remote ~= "") and opts.remote or "origin"
  local result, err = run(
    { "git", "-C", repo, "rev-list", "--count", remote .. "/" .. base .. ".." .. base },
    { timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    local _, err = fail("git rev-list", result)
    return nil, err
  end
  local n = tonumber(tostring(result.stdout or ""):match("%d+"))
  if not n then
    return nil, "git rev-list returned no count"
  end
  return n
end

-- Resolve a ref (`origin/main`, a tag, a branch) to the commit it names.
-- `reset_hard` only accepts a sha on purpose, so a caller that holds a ref
-- resolves it here first instead of passing a name the reset would refuse.
function M.rev_parse(worktree, ref)
  if type(worktree) ~= "string" or worktree == "" then
    return nil, "rev_parse needs a worktree"
  end
  if type(ref) ~= "string" or ref == "" or ref:match("^%-") then
    return nil, "rev_parse needs a ref"
  end
  local result, err = run({ "git", "-C", worktree, "rev-parse", "--verify", ref .. "^{commit}" })
  if not result then
    return nil, err
  end
  if not result.ok then
    local _, ferr = fail("rev-parse " .. ref, result)
    return nil, ferr
  end
  local sha = (result.stdout:gsub("%s+$", ""))
  if not sha:match("^[0-9a-f]+$") then
    return nil, "rev-parse " .. ref .. " returned no commit"
  end
  return sha
end

-- True when `ref` is an ancestor of (or equal to) `of`. A branch may only be
-- fast-forwarded to another ref when this holds: resetting past a commit that
-- is not in the target would silently drop work.
function M.is_ancestor(worktree, ref, of)
  if type(worktree) ~= "string" or worktree == "" then
    return nil, "is_ancestor needs a worktree"
  end
  if type(ref) ~= "string" or ref == "" or type(of) ~= "string" or of == "" then
    return nil, "is_ancestor needs two refs"
  end
  local result, err = run({ "git", "-C", worktree, "merge-base", "--is-ancestor", ref, of })
  if not result then
    return nil, err
  end
  if result.ok then
    return true
  end
  -- exit 1 is the "not an ancestor" answer; anything else is a real failure.
  if result.code == 1 then
    return false
  end
  return nil, tostring(result.stderr or result.stdout or "merge-base failed")
end

function M.head_sha(worktree)
  local result, err = run({ "git", "-C", worktree, "rev-parse", "HEAD" })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("rev-parse HEAD", result)
  end
  return (result.stdout:gsub("%s+$", ""))
end

-- Send the worktree back to a recorded commit. A red check must restore both
-- the commit and the files: moving HEAD alone would leave the failed turn's
-- edits in place, which is exactly what the next turn must not inherit.
function M.reset_hard(worktree, sha)
  if type(sha) ~= "string" or not sha:match("^[0-9a-f]+$") or #sha < 7 or #sha > 40 then
    return nil, "reset needs a commit sha"
  end
  local result, err = run({ "git", "-C", worktree, "reset", "--hard", sha })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("reset --hard", result)
  end
  return M.head_sha(worktree)
end

-- Rebase the task branch onto the freshest base. A conflict is not a crash:
-- the unmerged files are named, the rebase is aborted so the worktree is left
-- clean, and the caller gets a message it can act on. The branch head is
-- untouched by a failed rebase, so a retry starts from the same commit.
function M.rebase(worktree, upstream)
  if type(worktree) ~= "string" or worktree == "" then
    return nil, "rebase needs a worktree"
  end
  if type(upstream) ~= "string" or upstream == "" then
    return nil, "rebase needs an upstream"
  end
  local result, err = run({ "git", "-C", worktree, "rebase", upstream })
  if not result then
    return nil, err
  end
  if not result.ok then
    local conflicts = {}
    local unmerged = run({ "git", "-C", worktree, "diff", "--name-only", "--diff-filter=U" })
    if unmerged and unmerged.ok then
      for line in unmerged.stdout:gmatch("[^\n]+") do
        if line ~= "" then
          conflicts[#conflicts + 1] = line
        end
      end
    end
    run({ "git", "-C", worktree, "rebase", "--abort" })
    local files = #conflicts > 0 and table.concat(conflicts, ", ") or "unknown"
    return nil, string.format("rebase failed (conflicts: %s): %s",
      files, first_line(result.stderr) or "no output"),
      { conflict = #conflicts > 0 and conflicts or nil }
  end
  return M.head_sha(worktree)
end

-- Create a branch from `from_ref`, idempotently.
--
-- The epic branch outlives one run: a retry or a resumed submit must reuse it,
-- never reset it, or the subtasks already merged into it would be lost. So an
-- existing local branch is returned untouched, and a branch that only exists
-- on the remote is re-created as a tracking branch from that remote ref.
function M.branch_create(repo, name, from_ref, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "branch_create needs a repo"
  end
  if type(name) ~= "string" or name == "" then
    return nil, "branch_create needs a branch name"
  end
  local local_ref = "refs/heads/" .. name
  local existing = run({ "git", "-C", repo, "rev-parse", "--verify", "--quiet", local_ref })
  if existing and existing.ok then
    return { ok = true, branch = name, created = false, ref = local_ref }
  end
  local remote = opts.remote or "origin"
  local remote_ref = "refs/remotes/" .. remote .. "/" .. name
  local on_remote = run({ "git", "-C", repo, "rev-parse", "--verify", "--quiet", remote_ref })
  local start = (on_remote and on_remote.ok) and remote_ref or from_ref
  if type(start) ~= "string" or start == "" then
    return nil, "branch_create needs a start ref"
  end
  local result, err = run({ "git", "-C", repo, "branch", name, start })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("branch create", result)
  end
  return { ok = true, branch = name, created = true, ref = local_ref, from = start }
end

-- Push a branch by name, from the repository itself rather than a worktree.
--
-- The epic branch has no worktree of its own (nothing is implemented on it),
-- so it is pushed from the repo. `--force-with-lease` is not used here: the
-- branch is only ever advanced by merges, so a plain push is correct and a
-- non-fast-forward means someone else moved it.
function M.push_branch(repo, name, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "push_branch needs a repo"
  end
  if type(name) ~= "string" or name == "" then
    return nil, "push_branch needs a branch name"
  end
  local result, err = run({ "git", "-C", repo, "push", "-u", opts.remote or "origin", name },
    { timeout_ms = opts.timeout_ms })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("push", result)
  end
  return true
end

-- Move a local branch to a ref without checking it out. The epic branch lives
-- on the remote and every subtask merge lands there through GitHub, so the
-- local ref is behind after a squash merge; the merge worktree must start from
-- the tip GitHub actually holds, not from a stale local branch.
function M.branch_reset(repo, name, ref)
  if type(repo) ~= "string" or repo == "" then
    return nil, "branch_reset needs a repo"
  end
  if type(name) ~= "string" or name == "" then
    return nil, "branch_reset needs a branch name"
  end
  if type(ref) ~= "string" or ref == "" then
    return nil, "branch_reset needs a ref"
  end
  local result, err = run({ "git", "-C", repo, "branch", "-f", name, ref })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("branch reset", result)
  end
  return true
end

-- Push a task branch. The pipeline owns `metronome/*` branches and rewrites
-- them on purpose (a rebase onto the fresh base, a rollback to the last
-- checkpoint), so a plain push is refused as non-fast-forward the moment the
-- branch was rebased. `--force-with-lease` is the right tool: it replaces the
-- remote branch only when the remote still holds what we last fetched, so a
-- concurrent push by someone else is still refused instead of overwritten.
function M.push(worktree, branch, opts)
  opts = opts or {}
  local args = { "git", "-C", worktree, "push", "-u" }
  if opts.force then
    args[#args + 1] = "--force-with-lease"
  end
  args[#args + 1] = opts.remote or "origin"
  args[#args + 1] = branch
  local result, err = run(args)
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("push", result)
  end
  return true
end

-- Files a branch would change against its base, so the scheduler can refuse
-- overlapping work before it starts.
--
-- `opts.three_dot = true` asks for `<base>...HEAD`: the merge base compared to
-- the branch head. That is the range convergence needs, because it ignores
-- commits made on the base after the branch was cut.
function M.changed_files(worktree, base_ref, opts)
  opts = type(opts) == "table" and opts or {}
  local range = base_ref or "HEAD"
  if opts.three_dot then
    range = range .. "...HEAD"
  end
  local result, err = run({
    "git", "-C", worktree, "diff", "--name-only", range,
  })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("diff --name-only", result)
  end
  local files = {}
  for line in result.stdout:gmatch("[^\n]+") do
    if line ~= "" then
      files[#files + 1] = line
    end
  end
  return files
end

-- The files a ref contains, read from git rather than from the working tree.
--
-- The qualifier must describe the tree the worktree will be cut from
-- (`origin/<base>`), not whatever the local checkout happens to hold: a local
-- branch that diverged would make it name files the implementer never sees.
-- `git ls-tree -r --name-only` answers exactly that, and reads nothing that is
-- not committed.
function M.ls_tree(repo, ref, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "ls_tree needs a repo"
  end
  if type(ref) ~= "string" or ref == "" then
    return nil, "ls_tree needs a ref"
  end
  local result, err = run(
    { "git", "-C", repo, "ls-tree", "-r", "--name-only", ref },
    { timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    local _, err = fail("ls-tree " .. ref, result)
    return nil, err
  end
  local files = {}
  for line in result.stdout:gmatch("[^\n]+") do
    if line ~= "" then
      files[#files + 1] = line
    end
  end
  return files
end

-- The contents of one file at one ref. Used to excerpt the qualifier's key
-- files from the same tree `ls_tree` listed, so a listing and its excerpts can
-- never describe two different commits.
function M.show_file(repo, ref, path, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "show_file needs a repo"
  end
  if type(ref) ~= "string" or ref == "" then
    return nil, "show_file needs a ref"
  end
  if type(path) ~= "string" or path == "" then
    return nil, "show_file needs a path"
  end
  local result, err = run(
    { "git", "-C", repo, "show", ref .. ":" .. path },
    { timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    local _, err = fail("show " .. ref .. ":" .. path, result)
    return nil, err
  end
  return result.stdout
end

-- Pull requests -------------------------------------------------------------
--
-- The PR is opened with `gh`, in the task worktree, and only the three fields
-- the schema knows about are kept: a task stores `{ number, url, state }`, not
-- the whole `gh` payload.

local PR_STATES = { open = true, closed = true, merged = true }

-- `gh` answers in its own vocabulary (OPEN/CLOSED/MERGED, sometimes a numeric
-- string), so every PR goes through here before it reaches the state store:
-- what lands on a task always satisfies schemas/task.schema.json.
function M.normalize_pr(raw)
  if type(raw) ~= "table" then
    return nil, "pull request must be a table, got " .. type(raw)
  end
  local number = tonumber(raw.number)
  if not number or number < 1 or math.floor(number) ~= number then
    return nil, "pull request number must be an integer >= 1, got " .. tostring(raw.number)
  end
  local url = raw.url
  if type(url) ~= "string" or not url:match("^https?://") then
    return nil, "pull request url must start with http:// or https://, got " .. tostring(url)
  end
  local state = tostring(raw.state or "open"):lower()
  if not PR_STATES[state] then
    return nil, "pull request state must be open, closed or merged, got " .. tostring(raw.state)
  end
  return { number = number, url = url, state = state }
end

-- Read a PR back from GitHub. `ref` is a number, a branch or a URL -- `gh`
-- accepts all three, and pr_create uses the URL it just printed.
function M.pr_view(ref, opts)
  opts = opts or {}
  local result, err = run(
    { opts.gh or "gh", "pr", "view", tostring(ref), "--json", "number,url,state" },
    { cwd = opts.worktree, timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("gh pr view", result)
  end
  local decoded_ok, decoded = pcall(maki.json.decode, result.stdout)
  if not decoded_ok or type(decoded) ~= "table" then
    return nil, "gh pr view returned invalid JSON: " .. result.stdout:sub(1, 200)
  end
  return M.normalize_pr(decoded)
end

-- Every open pull request, with the branch it comes from. The reconciler
-- needs the branch name, not only the number: that is what ties a PR to a task.
function M.list_open_prs(opts)
  opts = type(opts) == "table" and opts or {}
  local result, err = run(
    { opts.gh or "gh", "pr", "list", "--state", "open", "--limit", "200",
      "--json", "number,headRefName,url,title" },
    { cwd = opts.repo, timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("gh pr list", result)
  end
  local ok, decoded = pcall(maki.json.decode, result.stdout)
  if not ok or type(decoded) ~= "table" then
    return nil, "gh pr list returned invalid JSON: " .. tostring(result.stdout):sub(1, 200)
  end
  local prs = {}
  for _, pr in ipairs(decoded) do
    prs[#prs + 1] = {
      number = pr.number,
      head = pr.headRefName,
      url = pr.url,
      title = pr.title,
    }
  end
  return prs
end

-- Remote branch names, optionally filtered by a prefix. `ls-remote` reads the
-- remote, so a branch deleted by a merge is not reported as still there.
function M.list_branches(repo, remote, opts)
  opts = type(opts) == "table" and opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "list_branches needs a repo"
  end
  local args = { "git", "-C", repo, "ls-remote", "--heads", remote or "origin" }
  if type(opts.pattern) == "string" and opts.pattern ~= "" then
    args[#args + 1] = opts.pattern
  end
  local result, err = run(args, { timeout_ms = opts.timeout_ms })
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("git ls-remote", result)
  end
  local names = {}
  for line in tostring(result.stdout or ""):gmatch("[^\n]+") do
    local name = line:match("refs/heads/(.+)$")
    if name then
      names[#names + 1] = name
    end
  end
  return names
end

-- Close a pull request without merging it. A failed, stopped or abandoned task
-- must not leave an open PR nobody will ever merge, nor a branch nobody will
-- look at.
function M.pr_close(ref, opts)
  opts = type(opts) == "table" and opts or {}
  if ref == nil or tostring(ref) == "" then
    return nil, "pr_close needs a pull request"
  end
  local result, err = run(
    { opts.gh or "gh", "pr", "close", tostring(ref) },
    { cwd = opts.worktree, timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    -- Already closed or merged is not a failure: the goal is a closed PR.
    local text = tostring(result.stdout or "") .. tostring(result.stderr or "")
    if text:find("already closed", 1, true) or text:find("already merged", 1, true) then
      return { closed = true, already = true }
    end
    return fail("gh pr close", result)
  end
  return { closed = true }
end

-- Post one comment on a pull request. The reviewer's findings are mirrored
-- onto the PR so a human reads them on GitHub, not only in the panel. The
-- default binary is the `gh-axi` wrapper; `opts.gh` overrides it for tests.
function M.pr_comment(ref, body, opts)
  opts = type(opts) == "table" and opts or {}
  if ref == nil or tostring(ref) == "" then
    return nil, "pr_comment needs a pull request"
  end
  if type(body) ~= "string" or body:gsub("%s", "") == "" then
    return nil, "pr_comment needs a non-empty body"
  end
  local result, err = run(
    { opts.gh or "gh-axi", "pr", "comment", tostring(ref), "--body", body },
    { cwd = opts.worktree, timeout_ms = opts.timeout_ms }
  )
  if not result then
    return nil, err
  end
  if not result.ok then
    return fail("gh pr comment", result)
  end
  return { commented = true, ref = tostring(ref) }
end

-- Open a PR for the task branch, then read it back so the caller gets
-- number/url/state rather than the URL `gh` happens to print.
function M.pr_create(opts)
  opts = opts or {}
  local title = tostring(opts.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- Nothing is run for an empty title: `gh` would open a PR with a blank name,
  -- which is worse than a refusal.
  if title == "" then
    return nil, "PR title is empty"
  end

  local args = { opts.gh or "gh", "pr", "create" }
  local base = opts.base or ""
  local head = opts.head or ""
  if base ~= "" then
    args[#args + 1] = "--base"
    args[#args + 1] = base
  end
  if head ~= "" then
    args[#args + 1] = "--head"
    args[#args + 1] = head
  end
  args[#args + 1] = "--title"
  args[#args + 1] = title
  args[#args + 1] = "--body"
  args[#args + 1] = opts.body or ""
  if opts.draft then
    args[#args + 1] = "--draft"
  end

  local result, err = run(args, { cwd = opts.worktree, timeout_ms = opts.timeout_ms })
  if not result then
    return nil, err
  end
  if not result.ok then
    local diag = M.classify("gh pr create", result)
    -- A PR that already exists for the head branch is not a failure: opening
    -- the PR is idempotent, so look the existing one up and return it through
    -- the normal pr_view/normalize path. Only a lookup that itself fails (no
    -- PR actually exists) is reported as an error.
    if diag.cause == "pr_exists" and head ~= "" then
      local existing, verr, vdiag = M.pr_view(head, opts)
      if existing then
        return existing
      end
      return nil, verr, vdiag
    end
    return nil, M.describe(diag), diag
  end

  local url = result.stdout:match("https?://[%w%._%-/~:%?#%[%]@!$&'()*+,;=]+")
  if not url then
    return nil, "gh pr create printed no pull request URL: " .. (first_line(result.stdout) or "no output")
  end
  return M.pr_view(url, opts)
end

-- Store the PR on the task. Normalising here too means a caller cannot write a
-- PR that the schema would later reject.
function M.pr_attach(state, root, task_id, pr)
  local normalized, err = M.normalize_pr(pr)
  if not normalized then
    return nil, err
  end
  return state.set_fields(root, task_id, { pr = normalized })
end

-- The whole step: open the PR, record it on the task, then move the task.
--
-- The PR is stored before the move so a refused transition still leaves the
-- work visible: the caller can retry the move without opening a second PR.
function M.pr_open(state, root, task_id, opts)
  opts = opts or {}
  -- A retry must not accumulate pull requests. Close the previous open one
  -- first; a merged or already-closed PR is left alone.
  local loaded = type(state.load) == "function" and state.load(root) or nil
  local existing = loaded and loaded.tasks and loaded.tasks[task_id]
    and loaded.tasks[task_id].pr or nil
  if existing and existing.number
    and existing.state ~= "merged" and existing.state ~= "closed" then
    pcall(M.pr_close, existing.number, {
      gh = opts.gh,
      worktree = opts.worktree,
      timeout_ms = opts.timeout_ms,
    })
  end
  local pr, err = M.pr_create(opts)
  if not pr then
    return nil, err
  end
  local task, aerr = M.pr_attach(state, root, task_id, pr)
  if not task then
    return nil, aerr
  end
  -- `attach_only` opens the PR and records it without moving the task to
  -- `pr_open`: the pipeline opens the PR before review, then reviews the exact
  -- SHA, and only then moves the task on.
  if opts.attach_only then
    return pr
  end
  local moved, terr = state.transition(root, task_id, "pr_open", { phase = opts.phase or "review" })
  if not moved then
    return nil, terr
  end
  return pr
end

return M
