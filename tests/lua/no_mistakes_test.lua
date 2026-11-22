-- Tests for maki/lua/metronome/no_mistakes.lua.
--
-- The gate is a shell binary, so it is faked: the script records its argv and
-- answers per mode. That proves the exact command shape and the verdict
-- mapping without a real `no-mistakes` install.

return function()
  local nm = load_module("no_mistakes")

  local base = test_base("no-mistakes")
  local scripts = maki.fs.joinpath(base, "bin")
  maki.fs.mkdir(scripts, { parents = true })
  local log = maki.fs.joinpath(base, "nm.log")
  maki.fs.write(log, "")

  local function sh(args, cwd)
    local job = maki.fn.jobstart(args, { cwd = cwd, scope = "plugin" })
    local res = maki.fn.jobwait(job, 30000)
    return res and res.exit_code or -1, res and (res.stdout .. res.stderr) or "no result"
  end

  local function read_log()
    return maki.fs.read(log) or ""
  end

  local log_quoted = "'" .. log:gsub("'", "'\\''") .. "'"

  local function fake(name, body)
    local path = maki.fs.joinpath(scripts, name)
    maki.fs.write(path, "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> " .. log_quoted .. "\n" .. body .. "\n")
    local code, out = sh({ "chmod", "+x", path })
    eq(code, 0, name .. " is executable: " .. out:sub(1, 80))
    return path
  end

  local ok_bin = fake("nm-ok", [[
if [ "$1" = "--version" ]; then
  echo "1.0.0"
  exit 0
fi
if [ "$1" = "axi" ] && [ "$2" = "run" ]; then
  echo "clean"
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
]])

  local fail_bin = fake("nm-fail", [[
if [ "$1" = "axi" ] && [ "$2" = "run" ]; then
  echo "finding: no test covers the change"
  exit 1
fi
exit 2
]])

  -- run: a clean gate approves ------------------------------------------------
  maki.fs.write(log, "")
  local result, err = nm.run({
    worktree = base,
    intent = "add login",
    base = "main",
    bin = ok_bin,
  })
  eq(err, nil, "a clean gate has no error: " .. tostring(err))
  eq(result and result.ok, true, "a clean gate reports ok")
  eq(result and result.approved, true, "a clean gate approves")
  has(read_log(), "axi run --intent add login --yes --base-branch main",
    "the gate receives the intent, --yes and the base branch")

  -- run: the hold is bounded by the task timeout, not the CLI's 8m default --
  maki.fs.write(log, "")
  local held = nm.run({
    worktree = base,
    intent = "add login",
    base = "main",
    bin = ok_bin,
    wait = "30m",
  })
  eq(held and held.ok, true, "a gate with a wait bound still approves")
  has(read_log(), "--wait 30m",
    "the gate holds for the task timeout instead of the CLI default")

  -- run: a failed gate is a verdict, not an error ----------------------------
  local failed, ferr = nm.run({
    worktree = base,
    intent = "add login",
    bin = fail_bin,
  })
  eq(ferr, nil, "a failed gate is not an error")
  eq(failed and failed.ok, false, "a failed gate reports not ok")
  eq(failed and failed.approved, false, "a failed gate does not approve")
  has(tostring(failed and failed.output), "finding", "the gate output is kept")
  has(tostring(failed and failed.error), "did not pass", "the verdict names the failure")

  -- run: an empty intent is refused before anything runs ---------------------
  local nointent, nerr = nm.run({ worktree = base, intent = "   ", bin = ok_bin })
  eq(nointent, nil, "an empty intent is refused")
  has(tostring(nerr), "intent", "the refusal names the intent")

  -- available ---------------------------------------------------------------
  eq(nm.available({ bin = ok_bin }), true, "a working binary is available")
  eq(nm.available({ bin = maki.fs.joinpath(scripts, "missing") }), false,
    "a missing binary is not available")
end
