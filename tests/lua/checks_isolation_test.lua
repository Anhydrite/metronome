-- Tests for the per-task XDG_STATE_HOME of maki/lua/metronome/checks.lua
-- (T-20261123-0004).
--
-- Two tasks must be able to run their checks at the same time: the checks of a
-- task may only write under its own XDG_STATE_HOME, never under the one the
-- shell happens to export. A command that pins the variable itself stays the
-- author's business and is never rewritten.
--
-- Everything here runs real `sh` commands, so the proofs are observed from the
-- child's environment rather than assumed from the argv.

return function()
  local checks = load_module("checks")

  -- test_dir() empties and recreates the workspace, so a rerun never inherits a
  -- state root from a previous one.
  local base = test_dir("checks-isolation")

  local root = maki.fs.joinpath(base, "state-root")
  maki.fs.mkdir(root, { parents = true })
  local work = maki.fs.joinpath(base, "work")
  maki.fs.mkdir(work, { parents = true })

  local PROBE = [[printf '%s|%s|%s|%s|%s' "${XDG_STATE_HOME:-}" "$LC_ALL" "$LANG" "${HOME:-}" "$PATH"]]

  -- Run one check as `task_id` sees it and return the five probed values.
  local function probe(task_id, opts)
    opts = opts or {}
    local run_root = opts.root
    if run_root == nil then
      run_root = root
    elseif run_root == false then
      run_root = nil
    end
    local result, err = checks.run({ opts.command or PROBE }, {
      worktree = work,
      root = run_root,
      task_id = task_id,
    })
    eq(err, nil, "probe of " .. tostring(task_id) .. " has no error: " .. tostring(err))
    eq(result and result.ok, true, "probe of " .. tostring(task_id) .. " is ok: "
      .. tostring(result and result.results[1].stderr))
    local out = (result and result.results[1].stdout) or ""
    local state_home, lc_all, lang, home, path = out:match("^(.-)|(.-)|(.-)|(.-)|(.*)$")
    return {
      state_home = state_home,
      lc_all = lc_all,
      lang = lang,
      home = home,
      path = path,
    }
  end

  -- Proof 1: two task ids get two different state homes ----------------------

  local first = probe("T-20261123-0004")
  local second = probe("T-20261123-0005")

  eq(type(first.state_home), "string", "first task has a state home")
  eq(first.state_home ~= "", true,
    "first task's XDG_STATE_HOME is set, got " .. tostring(first.state_home))
  eq(type(second.state_home), "string", "second task has a state home")
  eq(second.state_home ~= "", true,
    "second task's XDG_STATE_HOME is set, got " .. tostring(second.state_home))
  eq(first.state_home ~= second.state_home, true,
    "two task ids get different XDG_STATE_HOME (" .. tostring(first.state_home)
      .. " vs " .. tostring(second.state_home) .. ")")
  eq(first.state_home:sub(1, #root + 1), root .. "/",
    "the task state home lives under the state root: " .. tostring(first.state_home))
  eq(second.state_home:sub(1, #root + 1), root .. "/",
    "the second task state home lives under the state root: " .. tostring(second.state_home))

  local meta = maki.fs.metadata(first.state_home)
  eq(meta ~= nil, true, "the state home directory exists: " .. tostring(first.state_home))

  -- The same task keeps its own directory: a rerun must not drift, or the
  -- check would recreate its state on every attempt.
  local again = probe("T-20261123-0004")
  eq(again.state_home, first.state_home, "the same task keeps the same XDG_STATE_HOME")

  -- The locale pin is unchanged and the inherited environment survives.
  eq(first.lc_all, "C", "LC_ALL=C is still pinned")
  eq(first.lang, "C", "LANG=C is still pinned")
  eq(first.home ~= "", true, "HOME survives the prefix")
  eq(first.path ~= "", true, "PATH survives the prefix")

  -- Without an explicit root, the task home falls back under maki.env.state_dir().
  local default_root = probe("T-20261123-0006", { root = false })
  local state_dir = maki.env.state_dir()
  eq(type(state_dir), "string", "the state dir is known")
  eq(default_root.state_home:sub(1, #state_dir + 1), state_dir .. "/",
    "without a root, the task home lives under the state dir: " .. tostring(default_root.state_home))

  -- Proof 2: the inherited XDG_STATE_HOME is never what the check sees --------

  -- The harness itself exports XDG_STATE_HOME (it points at the run dir): a
  -- value merely inherited from the shell must never disable the injection.
  local inherited = maki.uv.os_getenv("XDG_STATE_HOME")
  eq(first.state_home ~= inherited, true,
    "the check does not inherit the shell's XDG_STATE_HOME ("
      .. tostring(inherited) .. ")")
  eq(second.state_home ~= inherited, true,
    "the second check does not inherit the shell's XDG_STATE_HOME")

  -- Proof 3: a command that pins XDG_STATE_HOME itself is not rewritten -------

  -- `sh -c` reads the variable in a child process: the observation is the
  -- child's environment, not the outer shell's (which expands its arguments
  -- before applying a temporary assignment).
  local INNER = [[sh -c 'printf %s "${XDG_STATE_HOME:-}"']]

  local function run_out(task_id, command)
    local result, err = checks.run({ command }, {
      worktree = work,
      root = root,
      task_id = task_id,
    })
    eq(err, nil, "run of [" .. command .. "] has no error: " .. tostring(err))
    eq(result and result.ok, true, "run of [" .. command .. "] is ok: "
      .. tostring(result and result.results[1].stderr))
    return ((result and result.results[1].stdout) or ""):gsub("%s+$", "")
  end

  local fixed = maki.fs.joinpath(base, "fixed-state-home")

  eq(run_out("T-20261123-0004", "XDG_STATE_HOME=" .. fixed .. " " .. INNER), fixed,
    "a `VAR=... cmd` assignment is left untouched")
  eq(run_out("T-20261123-0005", "env XDG_STATE_HOME=" .. fixed .. " " .. INNER), fixed,
    "an `env VAR=... cmd` form is left untouched")

  -- Detection is on the text, so a command that merely mentions the variable
  -- keeps the injection off: its child sees no task state home at all.
  local mentioned = run_out("T-20261123-0004",
    "echo XDG_STATE_HOME=fixture >/dev/null; " .. INNER)
  eq(mentioned, inherited or "",
    "a command whose text contains XDG_STATE_HOME= is not rewritten, got " .. tostring(mentioned))
end
