-- Preflight: prove the environment before a project is bound.
--
-- `/metronome init` used to declare a project ready and then watch every task
-- fail later, one at a time: a missing `user.email` surfaced on the first
-- commit, a missing `node` on the first `npm test`, a mistyped base branch on
-- the first push. This module moves all of that forward: it runs the five
-- mandatory checks in one pass and returns structured failures, each with the
-- id of the check, the command that failed, what went wrong and the exact
-- remedy. Every check runs, even after one failed, so a single refusal lists
-- every problem instead of dribbling them out one restart at a time.
--
-- The module is dependency-injected (`git`, `exec`) and never raises: git and
-- the process table are the outside world, and a preflight that throws is a
-- preflight that hides its verdict. Every fallible call returns `(value, err)`.
--
-- Children are pinned to the C locale (`env LC_ALL=C LANG=C`), the same idiom
-- git.lua and checks.lua use, so a diagnostic is the same string on every
-- machine and the user's locale never changes the answer.

local M = {}

M.TIMEOUT_DEFAULT = 60000
M.PROBE_MESSAGE = "metronome preflight probe (safe to discard)"
M.PROBE_FILE = ".metronome-preflight-probe"

-- The five mandatory checks, in the order a refusal is reported in.
M.IDS = {
  "git-identity",
  "git-test-commit",
  "checks-executable",
  "origin-base",
  "toolchain",
}

local fs = maki.fs

-- The locale pin is an implementation detail of the child, but it must hold for
-- every child: a real preflight and a fake one both see the same argv prefix.
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

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function first_line(text)
  for line in (text or ""):gmatch("[^\n]+") do
    local trimmed = trim(line)
    if trimmed ~= "" then
      return trimmed
    end
  end
  return nil
end

-- The default executor. It is only used when the caller did not inject one:
-- the argv arrives already carrying the locale prefix, so it runs verbatim.
-- jobstart raises when no task owns the job (plugin top level), hence the
-- retry with a plugin scope, exactly like checks.lua and git.lua.
local function default_exec(args, opts)
  opts = type(opts) == "table" and opts or {}
  local job_opts = { cwd = opts.cwd }
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
    return nil, "cannot start child: " .. tostring(err)
  end
  local result, werr = maki.fn.jobwait(job, opts.timeout_ms or M.TIMEOUT_DEFAULT)
  if type(result) ~= "table" then
    return nil, "child did not finish: " .. tostring(werr)
  end
  return {
    code = result.exit_code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

-- One child, always through the injected executor, always with the locale pin.
-- The result is normalised so a broken executor is a red check, not a crash:
-- code -1 and the executor's own error in stderr.
local function call(ctx, args, cwd)
  local ok, res, err = pcall(ctx.exec, with_c_locale(args), {
    cwd = cwd,
    timeout_ms = ctx.timeout_ms,
  })
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  if type(res) ~= "table" then
    return { code = -1, stdout = "", stderr = tostring(err or "executor returned no result") }
  end
  return {
    code = tonumber(res.code) or tonumber(res.exit_code) or -1,
    stdout = tostring(res.stdout or ""),
    stderr = tostring(res.stderr or ""),
  }
end

-- A path for the throwaway worktree, outside the repository so a failed
-- preflight never leaves a dirty tree: git creates the directory itself.
local function new_worktree_path()
  local base = "/tmp"
  local ok_dir, state_dir = pcall(function()
    return maki.env.state_dir()
  end)
  if ok_dir and is_non_empty(state_dir) then
    base = state_dir
  end
  local stamp = tostring(os.time())
  local ok_time, hrtime = pcall(function()
    return maki.uv.hrtime()
  end)
  if ok_time and hrtime ~= nil then
    stamp = tostring(hrtime)
  end
  return fs.joinpath(base, "metronome-preflight", "worktree-" .. stamp)
end

local function entry_of(id, command)
  return { id = id, ok = true, command = command or "", detail = "", remedy = "" }
end

local function mark_failed(entry, detail, remedy)
  entry.ok = false
  entry.detail = detail
  entry.remedy = remedy
  return entry
end

local function failure(id, command, detail, remedy)
  return { id = id, ok = false, command = command or "", detail = detail, remedy = remedy }
end

local IDENTITY_REMEDY = "set it once per machine: `git config --global user.name \"Your Name\"` "
  .. "and `git config --global user.email \"you@example.com\"`, then rerun /metronome init"

-- (1) git-identity ----------------------------------------------------------
--
-- A commit without an author is refused by git, so the identity must exist
-- before the first task: both keys, non-empty, in the project repository.
local function check_identity(ctx)
  local repo = ctx.repo
  local command = string.format(
    "git -C %s config --get user.name; git -C %s config --get user.email",
    tostring(repo),
    tostring(repo)
  )
  local entry = entry_of("git-identity", command)
  if not is_non_empty(repo) then
    return mark_failed(
      entry,
      "opts.repo is missing, there is no repository to read the identity from",
      "pass the project repository path to preflight.run({ repo = ... })"
    )
  end

  local missing = {}
  for _, key in ipairs({ "user.name", "user.email" }) do
    local res = call(ctx, { "git", "-C", repo, "config", "--get", key }, repo)
    local value = trim(res.stdout)
    if res.code ~= 0 then
      missing[#missing + 1] = key .. " is not set"
    elseif value == "" then
      missing[#missing + 1] = key .. " is empty"
    end
  end

  if #missing > 0 then
    return mark_failed(
      entry,
      "git identity is incomplete: " .. table.concat(missing, ", "),
      IDENTITY_REMEDY
    )
  end
  return entry
end

-- (2) git-test-commit -------------------------------------------------------
--
-- Proof that a commit actually passes: a throwaway worktree is cut from the
-- base ref, a probe file is committed there, and the resulting HEAD is read
-- back. A blocked commit (identity, a pre-commit hook, a read-only repo) is
-- caught here, once, instead of by the first real task.
--
-- The worktree is removed on both paths, always: a leftover worktree is a
-- `.git/worktrees` entry that the next `git worktree add` refuses.
local function check_test_commit(ctx)
  local repo = ctx.repo
  local base_ref = ctx.base_ref
  local worktree = ctx.worktree
  local entry = entry_of(
    "git-test-commit",
    string.format("git -C %s worktree add --detach %s %s", tostring(repo), tostring(worktree), tostring(base_ref))
  )
  if not is_non_empty(repo) then
    return mark_failed(
      entry,
      "opts.repo is missing, there is no repository to test a commit against",
      "pass the project repository path to preflight.run({ repo = ... })"
    )
  end
  if not is_non_empty(base_ref) then
    return mark_failed(
      entry,
      "opts.base_ref is missing, there is no ref to cut the throwaway worktree from",
      "pass the base branch to preflight.run({ base_ref = \"main\" })"
    )
  end

  local problems = {}

  -- The body is protected so the cleanup below runs even if a filesystem call
  -- raises: the worktree must never survive a failed preflight.
  local ok_body, body_err = pcall(function()
    -- `git worktree add` creates only the final path component: its parent (the
    -- preflight scratch directory under the state dir) must exist first, exactly
    -- as merge.lua creates the worktree root before git touches it. Without this
    -- the add fails with "could not create directory of ..." on every machine.
    local parent = worktree:match("^(.*)/[^/]+$")
    if parent then
      local made, mkerr = fs.mkdir(parent, { parents = true })
      if not made then
        problems[#problems + 1] = "cannot create the worktree parent directory: " .. tostring(mkerr)
        return
      end
    end

    local added = call(ctx, { "git", "-C", repo, "worktree", "add", "--detach", worktree, base_ref }, repo)
    if added.code ~= 0 then
      problems[#problems + 1] = "git worktree add failed (exit " .. tostring(added.code) .. "): "
        .. tostring(first_line(added.stderr) or first_line(added.stdout) or "no diagnostic")
      return
    end

    local probe = fs.joinpath(worktree, M.PROBE_FILE)
    -- A real `git worktree add` creates the final directory itself; this only
    -- makes the injected-exec tests (which never touch git) able to write the
    -- probe, and is a no-op on a path git already created.
    fs.mkdir(worktree, { parents = true })
    local wrote, werr = fs.write(probe, "metronome preflight probe\n")
    if not wrote then
      problems[#problems + 1] = "cannot write the probe file: " .. tostring(werr)
      return
    end

    local staged = call(ctx, { "git", "-C", worktree, "add", "-A" }, worktree)
    if staged.code ~= 0 then
      problems[#problems + 1] = "git add failed (exit " .. tostring(staged.code) .. "): "
        .. tostring(first_line(staged.stderr) or "no diagnostic")
      return
    end

    local committed = call(ctx, { "git", "-C", worktree, "commit", "-m", M.PROBE_MESSAGE }, worktree)
    if committed.code ~= 0 then
      problems[#problems + 1] = "git commit failed (exit " .. tostring(committed.code) .. "): "
        .. tostring(first_line(committed.stderr) or first_line(committed.stdout) or "no diagnostic")
      return
    end

    local head = call(ctx, { "git", "-C", worktree, "rev-parse", "HEAD" }, worktree)
    if head.code ~= 0 or trim(head.stdout) == "" then
      problems[#problems + 1] = "the probe commit has no readable HEAD: "
        .. tostring(first_line(head.stderr) or "git rev-parse HEAD returned nothing")
    end
  end)
  if not ok_body then
    problems[#problems + 1] = "the probe commit raised: " .. tostring(body_err)
  end

  -- Always, on both paths: remove then prune, so `.git/worktrees` is clean even
  -- when `worktree add` never got far enough to register the path.
  call(ctx, { "git", "-C", repo, "worktree", "remove", "--force", worktree }, repo)
  call(ctx, { "git", "-C", repo, "worktree", "prune" }, repo)

  if #problems > 0 then
    return mark_failed(
      entry,
      table.concat(problems, "; "),
      "fix what blocked the probe commit: the identity "
        .. "(`git config --global user.name`/`git config --global user.email`), "
        .. "any pre-commit hook under `.git/hooks` or `core.hooksPath` that rejects it, "
        .. "and the permissions of the repository"
    )
  end
  return entry
end

-- The first shell word of a declared check, skipping leading VAR=value
-- assignments, is the program that has to exist on PATH.
local function first_word(check)
  for word in check:gmatch("%S+") do
    if not word:match("^%a[%w_]*=") then
      return (word:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
    end
  end
  return nil
end

-- (3) checks-executable -----------------------------------------------------
--
-- Every declared check must name a program that PATH can resolve, otherwise the
-- task fails at exit 127 after it was declared ready. An empty or non-string
-- declaration is itself a failure: it is a broken contract, not a check.
local function check_checks_executable(ctx)
  local declared = ctx.checks
  local entry = entry_of("checks-executable", "sh -c 'command -v <declared check>'")
  local failures = {}

  if declared == nil then
    mark_failed(
      entry,
      "opts.checks is missing, there is nothing to prove executable",
      "pass the task's declared checks to preflight.run({ checks = { \"npm test\" } })"
    )
    failures[#failures + 1] = entry
    return entry, failures
  end

  if type(declared) ~= "table" or (#declared == 0 and next(declared) ~= nil) then
    mark_failed(
      entry,
      string.format("opts.checks must be a list of command strings, got %s", type(declared)),
      "declare checks as an array of commands, e.g. { \"bash tests/run-lua.sh\", \"bash tests/docs.sh\" }"
    )
    failures[#failures + 1] = entry
    return entry, failures
  end

  local commands = {}
  for i = 1, #declared do
    local check = declared[i]
    local shown = type(check) == "string" and check or tostring(check)
    if type(check) ~= "string" or trim(check) == "" then
      local problem = failure(
        "checks-executable",
        shown,
        string.format("check %d is not a non-empty command string", i),
        "declare each check as a non-empty command, e.g. \"npm test\" or \"bash tests/run-lua.sh\""
      )
      mark_failed(entry, problem.detail, problem.remedy)
      failures[#failures + 1] = problem
    else
      commands[#commands + 1] = check
      local head = first_word(check)
      if not head then
        local problem = failure(
          "checks-executable",
          check,
          string.format("check %d declares no program to run", i),
          "declare a real command, e.g. \"npm test\" instead of bare environment assignments"
        )
        mark_failed(entry, problem.detail, problem.remedy)
        failures[#failures + 1] = problem
      else
        -- The head is passed as `$1`, never spliced into the script: a check
        -- whose program name contains shell metacharacters cannot inject into
        -- the probe, it is only ever looked up on PATH.
        local probe = call(ctx, { "sh", "-c", 'command -v "$1"', "sh", head }, ctx.repo)
        if probe.code ~= 0 then
          local problem = failure(
            "checks-executable",
            check,
            string.format("the program '%s' of check %d is not on PATH", head, i),
            string.format(
              "install '%s' or put it on PATH (and in the environment maki runs in), "
                .. "or replace the check '%s' if the tool is not needed",
              head,
              check
            )
          )
          mark_failed(entry, problem.detail, problem.remedy)
          failures[#failures + 1] = problem
        end
      end
    end
  end

  if #commands > 0 then
    entry.command = table.concat(commands, "; ")
  end
  return entry, failures
end

-- (4) origin-base -----------------------------------------------------------
--
-- A task worktree is cut from the base ref of `origin`, so the repository must
-- have an origin and that origin must have the branch. Without this check, a
-- mistyped base branch fails on the first fetch, inside a task, with a message
-- about a ref nobody remembers declaring.
local function check_origin_base(ctx)
  local repo = ctx.repo
  local base_ref = ctx.base_ref
  local entry = entry_of(
    "origin-base",
    string.format("git -C %s ls-remote --heads origin %s", tostring(repo), tostring(base_ref))
  )
  if not is_non_empty(repo) then
    return mark_failed(
      entry,
      "opts.repo is missing, there is no repository to read origin from",
      "pass the project repository path to preflight.run({ repo = ... })"
    )
  end
  if not is_non_empty(base_ref) then
    return mark_failed(
      entry,
      "opts.base_ref is missing, there is no base branch to look for on origin",
      "pass the base branch to preflight.run({ base_ref = \"main\" })"
    )
  end

  local found = false
  local detail

  if ctx.git and type(ctx.git.list_branches) == "function" then
    local ok, names, err = pcall(ctx.git.list_branches, repo, "origin", { pattern = base_ref })
    if not ok then
      detail = "cannot list the branches of origin: " .. tostring(names)
    elseif type(names) ~= "table" then
      detail = "cannot list the branches of origin: " .. tostring(err or "no result")
    else
      for _, name in ipairs(names) do
        if name == base_ref then
          found = true
          break
        end
      end
      if not found then
        detail = string.format("origin has no branch '%s'", base_ref)
      end
    end
  else
    local res = call(ctx, { "git", "-C", repo, "ls-remote", "--heads", "origin", base_ref }, repo)
    if res.code ~= 0 then
      detail = "cannot read origin: "
        .. tostring(first_line(res.stderr) or first_line(res.stdout) or "git ls-remote failed")
    else
      for line in res.stdout:gmatch("[^\n]+") do
        local name = line:match("refs/heads/(%S+)%s*$")
        if name == base_ref then
          found = true
          break
        end
      end
      if not found then
        detail = string.format("origin has no branch '%s'", base_ref)
      end
    end
  end

  if not found then
    return mark_failed(
      entry,
      detail,
      string.format(
        "add the remote with `git remote add origin <url>` (or `git remote set-url origin <url>`), "
          .. "push the base branch '%s', and check its exact name with `git ls-remote --heads origin`",
        base_ref
      )
    )
  end
  return entry
end

-- (5) toolchain -------------------------------------------------------------
--
-- scripts/validate.sh and tools/validate-*.py import jsonschema to validate the
-- journals and the schemas, so a green pipeline without it is impossible. The
-- locale pin is asserted by the caller: every child here carries it too.
local function check_toolchain(ctx)
  local entry = entry_of("toolchain", "python3 -c 'import jsonschema'")
  local res = call(ctx, { "python3", "-c", "import jsonschema" }, ctx.repo)
  if res.code ~= 0 then
    local why = first_line(res.stderr)
    return mark_failed(
      entry,
      "python3 cannot import jsonschema"
        .. (why and (": " .. why) or (" (exit " .. tostring(res.code) .. ")")),
      "install it for the interpreter scripts/validate.sh uses: "
        .. "`python3 -m pip install jsonschema` (or `pip install jsonschema`)"
    )
  end
  return entry
end

local CHECK_FNS = {
  ["git-identity"] = check_identity,
  ["git-test-commit"] = check_test_commit,
  ["checks-executable"] = check_checks_executable,
  ["origin-base"] = check_origin_base,
  ["toolchain"] = check_toolchain,
}

-- CHECKS is derived from M.IDS, the single source of truth for the five
-- mandatory ids and their order: one list to change, no drift between them.
local CHECKS = {}
for _, id in ipairs(M.IDS) do
  CHECKS[#CHECKS + 1] = { id, CHECK_FNS[id] }
end

-- Run a check in isolation: a check that raises is a red check with its id, so
-- the other four still run and the refusal still lists everything.
local function run_one(id, fn, ctx)
  local ok, entry, more = pcall(fn, ctx)
  if not ok then
    local broken = failure(
      id,
      id,
      "the check itself raised: " .. tostring(entry),
      "this is a bug in preflight, not in the environment; report it with the detail above"
    )
    return broken, { broken }
  end
  entry = type(entry) == "table" and entry or entry_of(id, id)
  entry.id = entry.id or id
  local failures = {}
  for _, item in ipairs(type(more) == "table" and more or {}) do
    failures[#failures + 1] = item
  end
  if entry.ok == false and #failures == 0 then
    failures[#failures + 1] = failure(id, entry.command, entry.detail, entry.remedy)
  end
  return entry, failures
end

local function build_context(opts)
  local ctx = {
    repo = type(opts.repo) == "string" and opts.repo or nil,
    base_ref = type(opts.base_ref) == "string" and opts.base_ref or nil,
    checks = opts.checks,
    git = type(opts.git) == "table" and opts.git or nil,
    exec = type(opts.exec) == "function" and opts.exec or default_exec,
    timeout_ms = tonumber(opts.timeout_ms) or M.TIMEOUT_DEFAULT,
  }
  local ok_path, path = pcall(new_worktree_path)
  ctx.worktree = ok_path and path or "/tmp/metronome-preflight/worktree"
  return ctx
end

local function run_checks(opts)
  if type(opts) ~= "table" then
    opts = {}
  end
  local ctx = build_context(opts)

  local checks = {}
  local failures = {}
  for _, pair in ipairs(CHECKS) do
    local entry, failed = run_one(pair[1], pair[2], ctx)
    checks[#checks + 1] = entry
    for _, item in ipairs(failed) do
      failures[#failures + 1] = item
    end
  end

  return { ok = #failures == 0, checks = checks, failures = failures }
end

-- Verify the environment. Never raises: a bogus opts value is a refusal with a
-- failure entry, not a Lua error escaping into maki.
function M.run(opts)
  local ok, result = pcall(run_checks, opts)
  if not ok then
    local broken = failure(
      "preflight",
      "preflight.run",
      "preflight could not run: " .. tostring(result),
      "fix the options passed to preflight.run (repo, base_ref, checks) and rerun /metronome init"
    )
    result = { ok = false, checks = {}, failures = { broken } }
  end
  result.checks = type(result.checks) == "table" and result.checks or {}
  result.failures = type(result.failures) == "table" and result.failures or {}
  result.ok = (result.ok == true and #result.failures == 0)
  result.message = M.format(result)
  return result
end

-- The human half of the verdict: one line per failure, with the id, the
-- command and the remedy, so init/config never build prose themselves. A green
-- result renders as the empty string (the caller has nothing to say).
function M.format(result)
  if type(result) ~= "table" then
    return ""
  end
  local failures = type(result.failures) == "table" and result.failures or {}
  if #failures == 0 then
    return ""
  end
  local lines = {}
  for _, item in ipairs(failures) do
    lines[#lines + 1] = string.format(
      "[%s] %s -- %s (remedy: %s)",
      tostring(item.id or "preflight"),
      tostring(item.command or ""),
      tostring(item.detail or "no detail"),
      tostring(item.remedy or "no remedy")
    )
  end
  return table.concat(lines, "\n")
end

return M
