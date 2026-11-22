-- Tests for maki/lua/metronome/preflight.lua (T-20261122-0019).
--
-- Preflight is the boundary between "the project is configured" and "each task
-- fails on its own later". It must run all five mandatory checks in one pass,
-- name the failing command and the remedy, never raise, and always clean up the
-- throwaway worktree it created. Everything here drives a fake exec, so the
-- verdict is proven without touching a real repository, a real PATH or a real
-- python3.

return function()
  local preflight = load_module("preflight")

  local REPO = "/repo/demo"
  local BASE = "epic/demo"

  -- A scripted executor: the first rule whose `match` is a substring of the
  -- argv wins. Every call is recorded, argv included, so the tests can assert
  -- the locale prefix and the order of the cleanup calls.
  local function make_exec(rules)
    local calls = {}
    local function exec(args, opts)
      local joined = table.concat(args, " ")
      calls[#calls + 1] = { args = args, joined = joined, cwd = opts and opts.cwd }
      for _, rule in ipairs(rules or {}) do
        if joined:find(rule.match, 1, true) then
          if rule.fn then
            return rule.fn(args, calls)
          end
          return {
            code = rule.code or 0,
            stdout = rule.stdout or "",
            stderr = rule.stderr or "",
          }
        end
      end
      return { code = 0, stdout = "", stderr = "" }
    end
    return exec, calls
  end

  local function green_rules()
    return {
      { match = "config --get user.name", stdout = "Ada Preflight\n" },
      { match = "config --get user.email", stdout = "ada@example.com\n" },
      { match = "worktree add", code = 0 },
      { match = " add -A", code = 0 },
      { match = " commit -m", code = 0, stdout = "[detached HEAD 1234567] probe" },
      { match = "rev-parse HEAD", stdout = "1234567890abcdef1234567890abcdef12345678\n" },
      { match = "worktree remove", code = 0 },
      { match = "worktree prune", code = 0 },
      { match = "command -v", code = 0, stdout = "/usr/bin/program\n" },
      { match = "ls-remote --heads origin", stdout = "1111111111111111111111111111111111111111\trefs/heads/epic/demo\n" },
      { match = "import jsonschema", code = 0 },
    }
  end

  -- An override goes first so it wins over the green rule for the same command.
  local function rules_with(override)
    local rules = { override }
    for _, rule in ipairs(green_rules()) do
      rules[#rules + 1] = rule
    end
    return rules
  end

  local function run(rules, opts)
    local exec, calls = make_exec(rules)
    local o = opts or {}
    local result = preflight.run({
      repo = o.repo == nil and REPO or o.repo,
      base_ref = o.base_ref == nil and BASE or o.base_ref,
      checks = o.checks == nil and { "npm test" } or o.checks,
      exec = o.exec or exec,
      git = o.git,
      timeout_ms = o.timeout_ms,
    })
    return result, calls
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

  local function count_lines(text)
    local n = 0
    for _ in (text or ""):gmatch("[^\n]+") do
      n = n + 1
    end
    return n
  end

  -- A green environment -----------------------------------------------------

  local green, green_calls = run(green_rules())
  eq(green.ok, true, "green run is ok")
  eq(#green.failures, 0, "green run has no failure")
  eq(green.message, "", "green run renders an empty message")
  eq(preflight.format(green), "", "green format is empty")
  eq(#green.checks, 5, "green run has exactly five checks")
  eq(green.checks[1].id, "git-identity", "first check is git-identity")
  eq(green.checks[2].id, "git-test-commit", "second check is git-test-commit")
  eq(green.checks[3].id, "checks-executable", "third check is checks-executable")
  eq(green.checks[4].id, "origin-base", "fourth check is origin-base")
  eq(green.checks[5].id, "toolchain", "fifth check is toolchain")
  for i = 1, #green.checks do
    local entry = green.checks[i]
    eq(entry.ok, true, "green check " .. entry.id .. " is ok")
    eq(type(entry.command), "string", "green check " .. entry.id .. " names a command")
    eq(type(entry.detail), "string", "green check " .. entry.id .. " has a detail field")
    eq(type(entry.remedy), "string", "green check " .. entry.id .. " has a remedy field")
  end

  -- Every child carries the locale pin, inherited from git.lua/checks.lua.
  eq(#green_calls > 0, true, "green run started at least one child")
  local prefixed = 0
  for _, item in ipairs(green_calls) do
    eq(item.args[1], "env", "child argv starts with env")
    eq(item.args[2], "LC_ALL=C", "child argv pins LC_ALL=C")
    eq(item.args[3], "LANG=C", "child argv pins LANG=C")
    prefixed = prefixed + 1
  end
  eq(prefixed, #green_calls, "every child argv carries the locale prefix")

  -- The probe commit was made and the throwaway worktree was removed.
  local saw_commit, saw_remove, saw_prune = false, false, false
  for _, item in ipairs(green_calls) do
    if item.joined:find(" commit -m", 1, true) then saw_commit = true end
    if item.joined:find("worktree remove", 1, true) then saw_remove = true end
    if item.joined:find("worktree prune", 1, true) then saw_prune = true end
  end
  eq(saw_commit, true, "green run made the probe commit")
  eq(saw_remove, true, "green run removed the throwaway worktree")
  eq(saw_prune, true, "green run pruned the worktree registry")

  -- Each individual failure, with its id, command and remedy -----------------

  local no_email, _ = run(rules_with({ match = "config --get user.email", code = 1 }))
  eq(no_email.ok, false, "missing user.email is not ok")
  local email_failure = failure_with(no_email, "git-identity", "missing user.email")
  has(email_failure.command, "user.email", "identity failure names the user.email command")
  has(email_failure.detail, "user.email", "identity failure says which key is missing")
  has(email_failure.remedy, "git config --global user.email", "identity remedy names the exact command")
  has(email_failure.remedy, "git config --global user.name", "identity remedy names both commands")
  eq(#no_email.failures, 1, "only the identity fail is reported")

  local no_binary, no_binary_calls = run(rules_with({ match = "frobnicate", code = 1 }), {
    checks = { "frobnicate --flag" },
  })
  eq(no_binary.ok, false, "missing binary is not ok")
  local binary_failure = failure_with(no_binary, "checks-executable", "missing binary")
  eq(binary_failure.command, "frobnicate --flag", "binary failure names the whole declared check")
  has(binary_failure.remedy, "frobnicate", "binary remedy names the missing binary")
  has(binary_failure.detail, "PATH", "binary detail says the program is not on PATH")

  -- The head of a check is passed as an argv element, never spliced into the
  -- probe script: a program name cannot inject shell into preflight.
  local head_as_arg = false
  for _, item in ipairs(no_binary_calls) do
    if item.args[#item.args] == "frobnicate" then
      for _, arg in ipairs(item.args) do
        local spliced = arg:find("frobnicate", 1, true) ~= nil and arg ~= "frobnicate"
        eq(spliced, false, "the head is not spliced into the probe script")
      end
      head_as_arg = true
    end
  end
  eq(head_as_arg, true, "the check head is passed as a separate probe argument")

  local no_base, _ = run(rules_with({ match = "ls-remote --heads origin", code = 0, stdout = "" }))
  eq(no_base.ok, false, "missing base ref is not ok")
  local base_failure = failure_with(no_base, "origin-base", "missing base ref")
  has(base_failure.command, "ls-remote", "base failure names the ls-remote command")
  has(base_failure.detail, "origin has no branch", "base detail says the branch is absent")
  has(base_failure.remedy, BASE, "base remedy names the expected branch")
  has(base_failure.remedy, "git remote add origin", "base remedy names the remote fix")

  local no_schema, _ = run(rules_with({
    match = "import jsonschema",
    code = 1,
    stderr = "ModuleNotFoundError: No module named 'jsonschema'",
  }))
  eq(no_schema.ok, false, "missing jsonschema is not ok")
  local schema_failure = failure_with(no_schema, "toolchain", "missing jsonschema")
  has(schema_failure.detail, "ModuleNotFoundError", "toolchain detail carries the interpreter message")
  has(schema_failure.remedy, "pip install jsonschema", "toolchain remedy names the install command")

  -- A blocked probe commit, and the worktree is still removed ---------------

  local commit_fail, commit_calls = run(rules_with({
    match = " commit -m",
    code = 1,
    stderr = "fatal: a pre-commit hook rejected the probe",
  }))
  eq(commit_fail.ok, false, "blocked commit is not ok")
  local commit_failure = failure_with(commit_fail, "git-test-commit", "blocked commit")
  has(commit_failure.detail, "git commit failed", "commit failure says the commit failed")
  has(commit_failure.remedy, "hook", "commit remedy names the blocking hook")

  local commit_idx, remove_idx, prune_idx
  for i, item in ipairs(commit_calls) do
    if item.joined:find(" commit -m", 1, true) then commit_idx = i end
    if item.joined:find("worktree remove", 1, true) then remove_idx = i end
    if item.joined:find("worktree prune", 1, true) then prune_idx = i end
  end
  eq(type(commit_idx), "number", "the probe commit was attempted")
  eq(type(remove_idx), "number", "the worktree removal was attempted after a failed commit")
  eq(type(prune_idx), "number", "the worktree prune was attempted after a failed commit")
  eq(remove_idx > commit_idx, true, "the worktree is removed after the failed commit")
  eq(prune_idx > remove_idx, true, "the prune follows the removal")

  -- No early abort: five broken inputs list five failures --------------------

  local five_rules = {
    { match = "config --get user.name", code = 1 },
    { match = "config --get user.email", code = 1 },
    { match = " commit -m", code = 1, stderr = "fatal: cannot commit" },
    { match = "frobnicate", code = 1 },
    { match = "ls-remote --heads origin", code = 128, stderr = "fatal: 'origin' does not appear to be a git repository" },
    { match = "import jsonschema", code = 1, stderr = "ModuleNotFoundError: No module named 'jsonschema'" },
  }
  for _, rule in ipairs(green_rules()) do
    five_rules[#five_rules + 1] = rule
  end
  local broken = run(five_rules, { checks = { "frobnicate --flag" } })
  eq(broken.ok, false, "five broken inputs are not ok")
  eq(#broken.failures, 5, "five broken inputs list five failures, no early abort")
  local seen = {}
  for _, item in ipairs(broken.failures) do
    seen[item.id] = true
    eq(type(item.command), "string", "failure " .. item.id .. " names a command")
    eq(type(item.detail), "string", "failure " .. item.id .. " has a detail")
    eq(type(item.remedy), "string", "failure " .. item.id .. " has a remedy")
  end
  for _, id in ipairs({ "git-identity", "git-test-commit", "checks-executable", "origin-base", "toolchain" }) do
    eq(seen[id], true, "the five-failure run reports " .. id)
  end

  -- format renders one line per failure, with id, command and remedy ---------

  local formatted = preflight.format(broken)
  eq(preflight.format(broken), broken.message, "run.message is format(result)")
  eq(count_lines(formatted), #broken.failures, "format renders one line per failure")
  local first = broken.failures[1]
  has(formatted, first.id, "format names the failing id")
  has(formatted, first.command, "format names the failing command")
  has(formatted, first.remedy, "format names the remedy")

  -- A broken checks declaration is a failure, not a crash -------------------

  local not_a_list, _ = run(green_rules(), { checks = { name = "npm test" } })
  eq(not_a_list.ok, false, "a non-array checks value is refused")
  local map_failure = failure_with(not_a_list, "checks-executable", "non-array checks")
  has(map_failure.detail, "must be a list", "non-array checks detail explains the shape")
  has(map_failure.remedy, "array of commands", "non-array checks remedy explains the shape")

  local empty_check, _ = run(green_rules(), { checks = { "" } })
  eq(empty_check.ok, false, "an empty declared check is refused")
  local empty_failure = failure_with(empty_check, "checks-executable", "empty check")
  has(empty_failure.detail, "non-empty command", "empty check detail explains the contract")
  has(empty_failure.remedy, "declare each check", "empty check remedy explains the contract")

  local nonstring_check, _ = run(green_rules(), { checks = { 42 } })
  eq(nonstring_check.ok, false, "a non-string declared check is refused")
  failure_with(nonstring_check, "checks-executable", "non-string check")

  -- Never raises, whatever opts are -----------------------------------------

  local no_checks, _ = run(green_rules(), { checks = {} })
  eq(no_checks.ok, true, "an empty checks list has nothing to prove and is green")

  local nil_opts = preflight.run(nil)
  eq(type(nil_opts), "table", "run(nil) returns a table")
  eq(nil_opts.ok, false, "run(nil) is refused")
  eq(type(nil_opts.failures), "table", "run(nil) reports failures")
  eq(#nil_opts.failures >= 4, true, "run(nil) reports a failure per environment check")

  local string_opts = preflight.run("nonsense", {})
  eq(type(string_opts), "table", "run with a bogus opts returns a table")
  eq(string_opts.ok, false, "run with a bogus opts is refused")

  local empty_opts = preflight.run({})
  eq(type(empty_opts), "table", "run({}) returns a table")
  eq(empty_opts.ok, false, "run({}) is refused")
  eq(type(empty_opts.message), "string", "run({}) still renders a message")

  -- The injected git module can answer origin-base too ----------------------

  local branch_calls = 0
  local git_module = {
    list_branches = function(repo, remote, opts)
      branch_calls = branch_calls + 1
      eq(repo, REPO, "list_branches is asked about the project repo")
      eq(remote, "origin", "list_branches is asked about origin")
      eq(opts and opts.pattern, BASE, "list_branches is asked with the base pattern")
      return { BASE }
    end,
  }
  local via_git, via_git_calls = run(green_rules(), { git = git_module })
  eq(via_git.ok, true, "green run through the git module is ok")
  eq(branch_calls, 1, "the git module answered origin-base once")
  local ls_remote_used = false
  for _, item in ipairs(via_git_calls) do
    if item.joined:find("ls-remote", 1, true) then ls_remote_used = true end
  end
  eq(ls_remote_used, false, "the git module path does not shell out to ls-remote")

  local git_module_missing = {
    list_branches = function()
      return nil, "git ls-remote: exit 128"
    end,
  }
  local via_git_bad, _ = run(green_rules(), { git = git_module_missing })
  eq(via_git_bad.ok, false, "a git module that cannot list branches is refused")
  local via_git_failure = failure_with(via_git_bad, "origin-base", "git module refusal")
  has(via_git_failure.remedy, "git remote add origin", "git module refusal still names the remedy")

  -- A missing repo/base_ref is refused without running a child --------------

  local no_repo, no_repo_calls = run(green_rules(), { repo = "" })
  eq(no_repo.ok, false, "a missing repo is refused")
  failure_with(no_repo, "git-identity", "missing repo")
  failure_with(no_repo, "git-test-commit", "missing repo")
  failure_with(no_repo, "origin-base", "missing repo")
  -- No git child runs without a repo: only the check probe and the toolchain.
  for _, item in ipairs(no_repo_calls) do
    eq(item.joined:find("git -C", 1, true), nil, "no git child runs without a repo")
  end

  local no_base_ref, _ = run(green_rules(), { base_ref = "" })
  eq(no_base_ref.ok, false, "a missing base_ref is refused")
  failure_with(no_base_ref, "origin-base", "missing base_ref")
end
