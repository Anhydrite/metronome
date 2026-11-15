-- Convergence: compare the diff to the task sheet before the PR.
--
-- The implementer works from a sheet that declares the files in scope. This
-- module is the last check before a pull request: the diff on the task branch
-- must match that declaration. A declared file that did not change is a missing
-- change; a changed file nobody declared is scope creep. Both block.
--
-- The repair turn is a loop, not a guess: the prompt names the missing and the
-- unexpected files, an injected runner makes the change, and the diff is
-- compared again. The comparison uses `base...HEAD`, so a commit made on the
-- base after the branch was cut is not mistaken for a branch change.
--
-- Nothing here moves the task status: the pipeline owns the state machine.
--
-- Every function returns `(value, err)` and never raises. git, state, runner
-- and the session options are injected, so the module is pure Lua and the whole
-- turn is testable against a throwaway repository.

local M = {}

local fs = maki.fs
local json = maki.json

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Paths ----------------------------------------------------------------------

-- Diff output and sheets disagree about spelling: git says `src/a.lua`, a sheet
-- may say `./src/a.lua` or use backslashes. Normalising both sides is what
-- makes the comparison about files, not about typing.
function M.normalize_path(path)
  local text = trim(path)
  text = text:gsub("\\", "/")
  text = text:gsub("^%./", "")
  return text
end

-- A list of paths, normalised, deduplicated and sorted. Blank entries are
-- dropped: an empty line in a sheet is not a declared file.
local function normalize_list(list)
  local seen, out = {}, {}
  for _, item in ipairs(type(list) == "table" and list or {}) do
    local path = M.normalize_path(item)
    if path ~= "" and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  table.sort(out)
  return out
end

-- Comparison -----------------------------------------------------------------

function M.compare(declared, changed)
  local want = normalize_list(declared)
  local got = normalize_list(changed)

  local in_declared, in_changed = {}, {}
  for _, path in ipairs(want) do
    in_declared[path] = true
  end
  for _, path in ipairs(got) do
    in_changed[path] = true
  end

  local missing, unexpected, touched = {}, {}, {}
  for _, path in ipairs(want) do
    if in_changed[path] then
      touched[#touched + 1] = path
    else
      missing[#missing + 1] = path
    end
  end
  for _, path in ipairs(got) do
    if not in_declared[path] then
      unexpected[#unexpected + 1] = path
    end
  end

  return {
    missing = missing,
    unexpected = unexpected,
    touched = touched,
    declared = want,
    changed = got,
  }
end

local function empty_comparison()
  return { missing = {}, unexpected = {}, touched = {}, declared = {}, changed = {} }
end

-- Diff -----------------------------------------------------------------------

-- Validate the injected module once, so a missing function fails with a name
-- instead of a nil call halfway through the turn. Only the function the caller
-- is about to use is required: diff_files does not need `run`, and diff_stat
-- does not need `changed_files`.
local function check_git(git, fn)
  if type(git) ~= "table" then
    return nil, "git module is required"
  end
  if type(git[fn]) ~= "function" then
    return nil, "git module is missing " .. fn
  end
  return true
end

-- Files the task branch changes against its base. The three-dot range is what
-- makes the answer about this branch: it compares the merge base to HEAD, not
-- the base tree to the working tree.
function M.diff_files(worktree, base, opts)
  opts = type(opts) == "table" and opts or {}
  local ok, err = check_git(opts.git, "changed_files")
  if not ok then
    return nil, err
  end
  if not is_non_empty(worktree) then
    return nil, "diff_files needs a worktree"
  end

  local called, files, derr = pcall(opts.git.changed_files, worktree, base, { three_dot = true })
  if not called then
    return nil, tostring(files)
  end
  if not files then
    return nil, derr or "cannot list changed files"
  end
  return files
end

-- The human-readable diff summary that goes into the prompt and the report.
function M.diff_stat(worktree, base, opts)
  opts = type(opts) == "table" and opts or {}
  local ok, err = check_git(opts.git, "run")
  if not ok then
    return nil, err
  end
  if not is_non_empty(worktree) then
    return nil, "diff_stat needs a worktree"
  end

  local range = tostring(base or "HEAD") .. "...HEAD"
  local called, result, rerr = pcall(opts.git.run, {
    "git", "-C", worktree, "diff", "--stat", range,
  })
  if not called then
    return nil, tostring(result)
  end
  if not result then
    return nil, rerr or "cannot run git diff --stat"
  end
  if not result.ok then
    local detail = trim(result.stderr or "")
    if detail == "" then
      detail = trim(result.stdout or "")
    end
    return nil, string.format("git diff --stat %s failed (exit %s): %s",
      range, tostring(result.code), detail)
  end
  return trim(result.stdout or "")
end

-- Analysis -------------------------------------------------------------------

-- Compare the sheet's declared files to the branch diff.
--
-- A task that declares nothing has nothing to compare: a sheet without files is
-- a qualification problem, not a convergence one, so it passes here.
function M.analyze(task, worktree, base, opts)
  opts = type(opts) == "table" and opts or {}
  task = type(task) == "table" and task or {}

  local declared = type(task.files) == "table" and task.files or {}
  if #normalize_list(declared) == 0 then
    return { ok = true, findings = {}, comparison = empty_comparison(), stat = "" }
  end

  local changed, derr = M.diff_files(worktree, base, opts)
  if not changed then
    return nil, derr
  end

  local stat, serr = M.diff_stat(worktree, base, opts)
  if not stat then
    return nil, serr
  end

  local comparison = M.compare(declared, changed)
  local findings = {}
  for _, path in ipairs(comparison.missing) do
    findings[#findings + 1] = {
      severity = "blocking",
      rule = "missing_file",
      message = "declared file " .. path .. " was not changed",
      file = path,
    }
  end
  for _, path in ipairs(comparison.unexpected) do
    findings[#findings + 1] = {
      severity = "blocking",
      rule = "unexpected_file",
      message = "file " .. path .. " was changed but is not declared",
      file = path,
    }
  end

  return {
    ok = #findings == 0,
    findings = findings,
    comparison = comparison,
    stat = stat,
  }
end

-- Prompt ---------------------------------------------------------------------

local function bullets(out, list, format, fallback)
  if #list == 0 then
    out[#out + 1] = fallback
    return
  end
  for _, item in ipairs(list) do
    out[#out + 1] = "- " .. format(item)
  end
end

-- The repair prompt is built from the comparison, not from the sheet alone:
-- the model must see exactly which files it owes and which it must undo.
function M.prompt(task, sheet, analysis, opts)
  opts = type(opts) == "table" and opts or {}
  task = type(task) == "table" and task or {}
  analysis = type(analysis) == "table" and analysis or {}
  local comparison = type(analysis.comparison) == "table" and analysis.comparison or empty_comparison()
  local fence = type(opts.fence) == "table" and opts.fence or nil

  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  line("# Convergence")
  line("")
  line("- Task: " .. tostring(task.id or "") ..
    (is_non_empty(task.title) and (" — " .. task.title) or ""))
  line("")
  line("## Task sheet")
  line("")
  line(tostring(sheet or ""))
  line("")
  line("## Declared files")
  line("")
  bullets(out, comparison.declared or {}, function(path) return path end, "- (none declared)")
  line("")
  line("## Missing (declared but unchanged)")
  line("")
  bullets(out, comparison.missing or {}, function(path)
    return "declared file " .. path .. " was not changed"
  end, "- (none)")
  line("")
  line("## Unexpected (changed but not declared)")
  line("")
  bullets(out, comparison.unexpected or {}, function(path)
    return "file " .. path .. " was changed but is not declared"
  end, "- (none)")
  line("")
  line("## Diff stat")
  line("")
  local stat = is_non_empty(analysis.stat) and analysis.stat or "(no diff)"
  if fence then
    line(fence.wrap_output(stat, { label = tostring(task.id or "") }))
  else
    line(stat)
  end
  line("")
  line("## What to do")
  line("")
  line("- Add the missing changes, or explain in your report why the file needs none.")
  line("- Revert the unexpected changes, or stop and report why they are necessary.")
  line("- Stay inside the declared files: do not widen the scope on your own.")
  line("- Commit with a conventional message that says what changed and why.")
  line("- Do not edit the checks or the rules.")
  return table.concat(out, "\n") .. "\n"
end

-- Sheet ----------------------------------------------------------------------

-- The sheet is what qualification wrote. A caller may pass it directly; when it
-- does not, it is read from tasks_dir (or root/tasks), and a missing sheet
-- degrades to an empty section rather than a crash.
local function read_sheet(task, opts)
  if type(opts.sheet) == "string" then
    return opts.sheet
  end
  local dir = opts.tasks_dir
  if not is_non_empty(dir) and is_non_empty(opts.root) then
    dir = fs.joinpath(opts.root, "tasks")
  end
  if not is_non_empty(dir) then
    return ""
  end
  local id = tostring(task.id or "")
  if id == "" then
    return ""
  end
  local text = fs.read(fs.joinpath(dir, id .. ".md"))
  return type(text) == "string" and text or ""
end

-- Commit message -------------------------------------------------------------

-- Conventional message scoped to the first path segment of the first declared
-- file, the same shape the implementation turn uses.
local function commit_message(task, opts)
  local kind = opts.commit_kind or "feat"
  local scope = opts.commit_scope
  if scope == nil then
    local files = type(task.files) == "table" and task.files or {}
    local first = files[1]
    if is_non_empty(first) then
      scope = M.normalize_path(first):match("^([^/]+)")
    end
  end

  local subject = trim(task.title)
  if subject == "" then
    subject = tostring(task.id or "task")
  end

  local git = opts.git
  if type(git) == "table" and type(git.conventional) == "function" then
    local line = git.conventional(kind, scope, subject)
    if line then
      return line
    end
  end

  if is_non_empty(scope) then
    return string.format("%s(%s): %s", kind, scope, subject)
  end
  return string.format("%s: %s", kind, subject)
end

-- Run ------------------------------------------------------------------------

local function run_impl(opts)
  local task = type(opts.task) == "table" and opts.task or {}
  local worktree = opts.worktree
  local base = opts.base
  local git = opts.git

  local analysis, aerr = M.analyze(task, worktree, base, opts)
  if not analysis then
    return { ok = false, error = aerr }
  end

  if analysis.ok then
    return { ok = true, findings = {}, comparison = analysis.comparison, stat = analysis.stat }
  end

  -- Without a runner this is the dry run: report the findings and stop.
  if type(opts.runner) ~= "function" then
    return {
      ok = false,
      findings = analysis.findings,
      comparison = analysis.comparison,
      stat = analysis.stat,
    }
  end

  local sheet = read_sheet(task, opts)
  local prompt = M.prompt(task, sheet, analysis, opts)
  local session_opts = type(opts.session_opts) == "table" and opts.session_opts or {}

  local called, run = pcall(opts.runner, {
    role = "implementer",
    task_id = task.id,
    phase = "converge",
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

  if not run.ok then
    return {
      ok = false,
      error = run.error or "runner failed",
      findings = analysis.findings,
      comparison = analysis.comparison,
      stat = analysis.stat,
      run = run,
    }
  end

  local sha = nil
  if opts.commit ~= false then
    local before, berr = git.head_sha(worktree)
    if not before then
      return {
        ok = false,
        error = berr,
        findings = analysis.findings,
        comparison = analysis.comparison,
        stat = analysis.stat,
        run = run,
      }
    end

    local csha, cerr = git.commit(worktree, commit_message(task, opts))
    if not csha then
      if cerr == "nothing to commit" then
        -- A runner that committed by itself leaves nothing for us to do: the
        -- head it produced is the turn's result.
        sha = before
      else
        return {
          ok = false,
          error = cerr,
          findings = analysis.findings,
          comparison = analysis.comparison,
          stat = analysis.stat,
          run = run,
        }
      end
    else
      sha = csha
    end
  end

  -- The verdict is the diff after the turn, never the model's word.
  local after, after_err = M.analyze(task, worktree, base, opts)
  if not after then
    return {
      ok = false,
      error = after_err,
      findings = analysis.findings,
      comparison = analysis.comparison,
      stat = analysis.stat,
      run = run,
      sha = sha,
    }
  end

  -- A failed convergence must carry a reason. Without it the caller falls
  -- back to "task failed" and the user never learns which file was missing or
  -- out of scope.
  local err = nil
  if not after.ok then
    local first = type(after.findings) == "table" and after.findings[1] or nil
    local detail = first and (first.message or first.kind) or "diff does not match the sheet"
    err = "convergence failed: " .. tostring(detail)
  end
  return {
    ok = after.ok,
    error = err,
    findings = after.findings,
    comparison = after.comparison,
    stat = after.stat,
    run = run,
    sha = sha,
  }
end

-- A turn is a chain of injected calls; any one of them could raise. The
-- contract is a result table, so the unexpected becomes `{ ok = false }`.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(run_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

-- Gate -----------------------------------------------------------------------

-- Run convergence for one task and write the evidence next to the state root.
-- The task status is deliberately untouched: the pipeline owns that move.
function M.gate(state, root, opts)
  opts = type(opts) == "table" and opts or {}
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return nil, "state module is required"
  end
  if not is_non_empty(root) then
    return nil, "state root is required"
  end

  local task = opts.task
  local task_id = type(task) == "table" and task.id or opts.task_id
  if not is_non_empty(task_id) then
    return nil, "gate needs a task or a task_id"
  end

  if type(task) ~= "table" then
    local loaded_ok, loaded = pcall(state.load, root)
    if not loaded_ok or type(loaded) ~= "table" then
      return nil, "cannot load state"
    end
    local tasks = type(loaded.tasks) == "table" and loaded.tasks or {}
    task = tasks[task_id]
    if type(task) ~= "table" then
      return nil, "unknown task: " .. tostring(task_id)
    end
  end

  local run_opts = {}
  for key, value in pairs(opts) do
    run_opts[key] = value
  end
  run_opts.task = task

  local result = M.run(run_opts)

  local dir = fs.joinpath(root, "converge")
  local made, mkdir_err = fs.mkdir(dir, { parents = true })
  if not made then
    return nil, "cannot create converge directory: " .. tostring(mkdir_err)
  end

  local payload = {
    at = opts.now or now_iso(),
    task_id = task_id,
    ok = result.ok,
    findings = result.findings or {},
    comparison = result.comparison or empty_comparison(),
    stat = result.stat or "",
  }

  local encoded_ok, encoded = pcall(json.encode, payload)
  if not encoded_ok or type(encoded) ~= "string" then
    return nil, "cannot encode converge report: " .. tostring(encoded)
  end

  local path = fs.joinpath(dir, tostring(task_id) .. ".json")
  local wrote, write_err = fs.write(path, encoded)
  if not wrote then
    return nil, "cannot write converge report: " .. tostring(write_err)
  end

  return result
end

return M
