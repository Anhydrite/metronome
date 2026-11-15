-- Implementation turn.
--
-- One implementation turn has four parts: prepare an isolated worktree cut
-- from the freshest base, render the prompt from the task sheet, checkpoint the
-- branch before the model touches it, then run one implementer turn and commit
-- and push what changed. A retry therefore restarts from a recorded commit
-- instead of from nothing.
--
-- Every function returns `(value, err)` and never raises. git, state, runner
-- and the session options are injected, so this module is pure Lua and the
-- whole turn is testable without spending a token.

local M = {}

local fs = maki.fs

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

-- A list of strings joined for display. Anything that is not a string is
-- stringified rather than crashing the prompt: a malformed sheet is still
-- better rendered than lost.
local function join_list(list, sep)
  local parts = {}
  for i, item in ipairs(type(list) == "table" and list or {}) do
    parts[i] = tostring(item)
  end
  return table.concat(parts, sep or ", ")
end

-- Paths and names ------------------------------------------------------------

function M.worktree_path(root, task_id, opts)
  opts = opts or {}
  local base = opts.worktree_root or fs.joinpath(root, "worktrees")
  return fs.joinpath(base, tostring(task_id))
end

-- Accents are folded rather than dropped so a French title keeps its words:
-- "Tarte aux pommes à 4,5 €" becomes "tarte-aux-pommes-a-4-5", not a chain of
-- dashes. The table is applied literally, one key at a time, so the multi-byte
-- UTF-8 sequences are matched as they are written.
local ACCENTS = {
  ["à"] = "a", ["â"] = "a", ["ä"] = "a", ["á"] = "a", ["ã"] = "a", ["å"] = "a",
  ["ç"] = "c",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e",
  ["î"] = "i", ["ï"] = "i", ["í"] = "i",
  ["ô"] = "o", ["ö"] = "o", ["ó"] = "o", ["õ"] = "o",
  ["ù"] = "u", ["û"] = "u", ["ü"] = "u", ["ú"] = "u",
  ["ÿ"] = "y", ["ñ"] = "n", ["œ"] = "oe", ["æ"] = "ae",
}

-- A branch name a human can read: the feature, not the ticket number. Lowercase
-- ASCII words joined by single dashes, cut at `max_len` so the name stays
-- short enough to type.
function M.slug(text, max_len)
  local s = tostring(text or ""):lower()
  for from, to in pairs(ACCENTS) do
    s = s:gsub(from, to)
  end
  s = s:gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  local limit = tonumber(max_len) or 48
  if #s > limit then
    s = s:sub(1, limit):gsub("%-+$", "")
  end
  return s
end

-- The branch is named after the task, with the task's short id kept as a
-- suffix: two tasks with the same title must never share a branch, and the id
-- is what the journal, the worktree and the PR all point at.
function M.branch_for(task_id, opts)
  opts = opts or {}
  local prefix = opts.branch_prefix or "metronome/"
  local slug = M.slug(opts.title)
  if slug == "" then
    return prefix .. tostring(task_id)
  end
  local short = tostring(task_id):match("([0-9a-fA-F]+)$")
  if short then
    slug = slug .. "-" .. short
  end
  return prefix .. slug
end

function M.sheet_path(root, task_id, opts)
  opts = opts or {}
  local base = opts.tasks_dir or fs.joinpath(root, "tasks")
  return fs.joinpath(base, tostring(task_id) .. ".md")
end

-- The sheet is the contract. When it is missing, the turn still needs the four
-- facts that matter -- title, id, files, checks -- so it renders them rather
-- than refusing to start.
local function fallback_sheet(task)
  local out = {}
  out[#out + 1] = "# " .. tostring(task.title or "Untitled task")
  out[#out + 1] = ""
  out[#out + 1] = "- ID: " .. tostring(task.id or "")
  out[#out + 1] = "- Files: " .. join_list(task.files)
  out[#out + 1] = "- Checks: " .. join_list(task.checks)
  return table.concat(out, "\n") .. "\n"
end

function M.read_sheet(root, task, opts)
  opts = opts or {}
  task = type(task) == "table" and task or {}
  local task_id = task.id or opts.task_id
  local path = M.sheet_path(root, task_id, opts)
  local text = fs.read(path)
  if type(text) == "string" and text ~= "" then
    return text
  end
  return fallback_sheet(task)
end

-- Prompt ---------------------------------------------------------------------

-- The prompt is assembled from the sheet, not from the state store: what the
-- implementer reads is exactly what qualification wrote. The worktree block is
-- explicit because the model must know where it is allowed to work.
function M.render_prompt(task, sheet, ctx, opts)
  opts = type(opts) == "table" and opts or {}
  task = type(task) == "table" and task or {}
  ctx = type(ctx) == "table" and ctx or {}

  local id = tostring(task.id or ctx.task_id or "")
  local title = tostring(task.title or "")
  local files = type(task.files) == "table" and task.files or {}
  local checks = type(task.checks) == "table" and task.checks or {}

  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  line("# Implementation task")
  line("")
  line("- Task: " .. id .. (title ~= "" and (" — " .. title) or ""))
  line("- Files: " .. (#files > 0 and join_list(files) or "(none declared — choose the minimal set)"))
  line("- Checks: " .. join_list(checks))
  line("")
  line("## Task sheet")
  line("")
  line(tostring(sheet or ""))
  line("")
  line("## Worktree")
  line("")
  line("- Repository: " .. tostring(ctx.repo or ""))
  line("- Worktree: " .. tostring(ctx.worktree or ""))
  line("- Branch: " .. tostring(ctx.branch or ""))
  line("- Base: " .. tostring(ctx.base_ref or ""))
  line("")
  line("## Checks")
  line("")
  for _, check in ipairs(checks) do
    line("- " .. tostring(check))
  end
  line("")
  line("## Rules")
  line("")
  if #files > 0 then
    line("- Stay inside the declared files: if the change genuinely needs another file, stop and report it.")
  else
    line("- No file is declared: choose the files the change genuinely needs, keep the diff minimal, and list every file you touched in your report.")
  end
  line("- Run the checks once and report their exit codes; do not claim work you did not verify.")
  line("- Commit, then stop: do not explore the repository beyond what the change needs.")
  line("- Commit with a conventional message that says what changed and why.")
  line("- Never edit the checks or the rules.")
  line("- Report blockers plainly: what you tried, what you observed, what you need.")

  return table.concat(out, "\n") .. "\n"
end

-- Prepare --------------------------------------------------------------------

-- Validate the injected modules once, so a missing function fails with a name
-- instead of a nil call halfway through the turn.
local function check_module(name, module, functions)
  if type(module) ~= "table" then
    return nil, name .. " module is required"
  end
  for _, fn in ipairs(functions) do
    if type(module[fn]) ~= "function" then
      return nil, string.format("%s module is missing %s", name, fn)
    end
  end
  return true
end

-- Create or re-attach the task worktree and move the task to running.
--
-- Reuse is the normal path: a second turn finds the worktree already listed.
-- When only the branch survived a removed worktree, the `branch_exists`
-- diagnostic is the signal to check that branch out instead of creating it.
function M.prepare(opts)
  opts = type(opts) == "table" and opts or {}

  local ok, err = check_module("git", opts.git, { "fetch", "worktree_list", "worktree_add" })
  if not ok then
    return nil, err
  end
  ok, err = check_module("state", opts.state, { "load", "can_transition", "transition", "set_fields" })
  if not ok then
    return nil, err
  end

  local task = opts.task
  if type(task) ~= "table" or not is_non_empty(task.id) then
    return nil, "prepare needs a task with an id"
  end
  local task_id = task.id
  if not is_non_empty(opts.repo) then
    return nil, "prepare needs a repo"
  end
  if not is_non_empty(opts.root) then
    return nil, "prepare needs a state root"
  end

  local base = opts.base_ref
  if not is_non_empty(base) then
    base = task.base_ref
  end
  if not is_non_empty(base) then
    base = opts.default_base
  end
  if not is_non_empty(base) then
    base = "main"
  end
  local remote = opts.remote or "origin"

  local fetched, ferr = opts.git.fetch(opts.repo, remote)
  if not fetched then
    return nil, ferr
  end

  local worktree = M.worktree_path(opts.root, task_id, opts)
  -- A task that already has a branch keeps it: a retry must re-attach the
  -- branch its checkpoints and pull request point at, never invent a new one
  -- because the title was edited.
  local branch = is_non_empty(task.branch) and task.branch
    or M.branch_for(task_id, { branch_prefix = opts.branch_prefix, title = task.title })

  local listed, lerr = opts.git.worktree_list(opts.repo)
  if not listed then
    return nil, lerr
  end
  local reuse = false
  for _, path in ipairs(listed) do
    if path == worktree then
      -- A registered path whose directory is gone is a stale registration: a
      -- reset state root or a crashed run left it behind. Reusing it would
      -- make every git call fail with "cannot change to <worktree>".
      if fs.metadata(worktree) then
        reuse = true
      elseif type(opts.git.worktree_prune) == "function" then
        opts.git.worktree_prune(opts.repo)
      end
      break
    end
  end

  if not reuse then
    local made, merr, diag = opts.git.worktree_add(opts.repo, worktree, branch, base, { remote = remote })
    if not made and type(diag) == "table" and diag.cause == "branch_exists" then
      made, merr, diag = opts.git.worktree_add(opts.repo, worktree, branch, base, { existing = true })
    end
    if not made then
      return nil, merr
    end
  end

  local loaded = opts.state.load(opts.root)
  local current = loaded and loaded.tasks and loaded.tasks[task_id]
  if type(current) ~= "table" then
    return nil, "unknown task: " .. task_id
  end
  if not opts.state.can_transition(current.status, "running") then
    return nil, string.format("cannot start %s: %s cannot move to running",
      task_id, tostring(current.status))
  end
  local moved, terr = opts.state.transition(opts.root, task_id, "running", { phase = "implement" })
  if not moved then
    return nil, terr
  end

  local updated, serr = opts.state.set_fields(opts.root, task_id, {
    branch = branch,
    worktree = worktree,
    base_ref = base,
  })
  if not updated then
    return nil, serr
  end

  return {
    task_id = task_id,
    repo = opts.repo,
    worktree = worktree,
    branch = branch,
    base_ref = base,
  }
end

-- Checkpoint -----------------------------------------------------------------

-- Record the commit the next turn starts from. Writing the same SHA twice is a
-- no-op: the list is a history of starting points, not a log of calls.
function M.checkpoint(opts)
  opts = type(opts) == "table" and opts or {}

  local ok, err = check_module("git", opts.git, { "head_sha" })
  if not ok then
    return nil, err
  end
  ok, err = check_module("state", opts.state, { "load", "set_fields" })
  if not ok then
    return nil, err
  end
  if not is_non_empty(opts.root) then
    return nil, "checkpoint needs a state root"
  end
  if not is_non_empty(opts.task_id) then
    return nil, "checkpoint needs a task id"
  end
  if not is_non_empty(opts.worktree) then
    return nil, "checkpoint needs a worktree"
  end

  local sha, herr = opts.git.head_sha(opts.worktree)
  if not sha then
    return nil, herr
  end

  local loaded = opts.state.load(opts.root)
  local task = loaded and loaded.tasks and loaded.tasks[opts.task_id]
  if type(task) ~= "table" then
    return nil, "unknown task: " .. opts.task_id
  end

  local checkpoints = type(task.checkpoints) == "table" and task.checkpoints or {}
  if checkpoints[#checkpoints] == sha then
    return sha
  end

  local list = {}
  for i, value in ipairs(checkpoints) do
    list[i] = value
  end
  list[#list + 1] = sha

  local updated, serr = opts.state.set_fields(opts.root, opts.task_id, { checkpoints = list })
  if not updated then
    return nil, serr
  end
  return sha
end

-- Commit message -------------------------------------------------------------

-- Conventional message scoped to the first path segment of the first declared
-- file: `feat(maki): ...` for `maki/lua/...`, which is what a reader scanning
-- the log expects.
function M.commit_message(task, opts)
  opts = type(opts) == "table" and opts or {}
  task = type(task) == "table" and task or {}

  local kind = opts.commit_kind or "feat"
  local scope = opts.commit_scope
  if scope == nil then
    local first = type(task.files) == "table" and task.files[1]
    if is_non_empty(first) then
      scope = first:match("^([^/]+)") or first
    end
  end

  local git = opts.git
  if type(git) == "table" and type(git.conventional) == "function" then
    local line = git.conventional(kind, scope, task.title)
    if line then
      return line
    end
  end

  -- Fallback for a caller without the git module, or an empty title: the
  -- message must still be a string.
  local subject = trim(task.title)
  if subject == "" then
    subject = tostring(task.id or "task")
  end
  if is_non_empty(scope) then
    return string.format("%s(%s): %s", kind, scope, subject)
  end
  return string.format("%s: %s", kind, subject)
end

-- Run ------------------------------------------------------------------------

-- Every change must reach the base through a pull request. The implementer
-- therefore refuses to commit on the base branch itself, even if a caller
-- hands it a worktree that is checked out on main.
function M.assert_task_branch(branch, base)
  if type(branch) ~= "string" or branch == "" then
    return nil, "task branch is required"
  end
  if branch == base or branch == "main" or branch == "master" then
    return nil, "refusing to commit on the base branch " .. branch
      .. "; every change must go through a pull request"
  end
  return true
end

local function run_impl(opts)
  local ctx, perr = M.prepare(opts)
  if not ctx then
    return { ok = false, error = perr }
  end

  local branch_ok, branch_err = M.assert_task_branch(ctx.branch, opts.base_ref or "main")
  if not branch_ok then
    return { ok = false, error = branch_err, ctx = ctx }
  end

  local checkpoint, cerr = M.checkpoint({
    git = opts.git,
    state = opts.state,
    root = opts.root,
    task_id = ctx.task_id,
    worktree = ctx.worktree,
  })
  if not checkpoint then
    return { ok = false, error = cerr, ctx = ctx }
  end

  local sheet = M.read_sheet(opts.root, opts.task, opts)
  local prompt = M.render_prompt(opts.task, sheet, ctx, opts)
  local session_opts = type(opts.session_opts) == "table" and opts.session_opts or {}

  if type(opts.runner) ~= "function" then
    return { ok = false, error = "run needs a runner function", ctx = ctx, checkpoint = checkpoint }
  end

  local called, run = pcall(opts.runner, {
    role = "implementer",
    task_id = ctx.task_id,
    phase = "implement",
    prompt = prompt,
    system = session_opts.system,
    model_spec = session_opts.model_spec,
    thinking = session_opts.thinking,
    tools = session_opts.tools,
    state_root = opts.state_root,
    ctx = opts.ctx,
    max_attempts = opts.max_attempts,
    deadline_secs = opts.deadline_secs,
  })
  if not called then
    run = { ok = false, error = tostring(run) }
  elseif type(run) ~= "table" then
    run = { ok = false, error = "runner returned no result" }
  end

  if not run.ok then
    return {
      ok = false,
      error = run.error or "runner failed",
      ctx = ctx,
      checkpoint = checkpoint,
      run = run,
    }
  end

  local sha = nil
  local no_changes = false

  if opts.commit ~= false then
    local before, berr = opts.git.head_sha(ctx.worktree)
    if not before then
      return { ok = false, error = berr, ctx = ctx, checkpoint = checkpoint, run = run }
    end

    local csha, ccerr = opts.git.commit(ctx.worktree, M.commit_message(opts.task, opts))
    if not csha then
      if ccerr == "nothing to commit" then
        -- A runner that committed by itself leaves nothing for us to do. The
        -- head is the turn's result, and it only counts as "no change" when it
        -- is still the checkpoint we started from.
        sha = before
        no_changes = (before == checkpoint)
      else
        return { ok = false, error = ccerr, ctx = ctx, checkpoint = checkpoint, run = run }
      end
    else
      sha = csha
      no_changes = false
    end
  end

  if opts.push ~= false then
    local pushed, push_err = opts.git.push(ctx.worktree, ctx.branch, { remote = opts.remote or "origin" })
    if not pushed then
      return {
        ok = false,
        error = push_err,
        ctx = ctx,
        checkpoint = checkpoint,
        run = run,
        sha = sha,
      }
    end
  end

  return {
    ok = true,
    ctx = ctx,
    checkpoint = checkpoint,
    sha = sha,
    no_changes = no_changes or false,
    run = run,
  }
end

-- A turn is a long chain of injected calls; any one of them could raise. The
-- contract is a result table, so the unexpected becomes `{ ok = false }` rather
-- than an exception the pipeline cannot report.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(run_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

return M
