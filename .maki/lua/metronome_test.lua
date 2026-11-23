-- Lua test harness for Metronome, run inside maki's own Lua host.
--
-- This machine has no standalone Lua interpreter, but maki embeds one and
-- `maki index <file>` loads project plugins without calling a model. The
-- harness executes every tests/lua/*.lua file against the real `maki` API and
-- writes a result the shell test reads.
--
-- Two host quirks shape this file:
--   * `load` is nil, but `loadstring`/`setfenv` exist (Lua 5.1 semantics).
--   * a module loaded through `require` cannot yield, and maki.fs calls yield,
--     so init.lua loads this file with loadstring instead of require.

local cwd = maki.uv.cwd()

-- Read an environment variable, treating an empty value as absent.
local function env(name)
  local value = maki.uv.os_getenv(name)
  if value == "" then
    return nil
  end
  return value
end

-- The shell harness tells us where to write the results; the fixed path is only
-- a fallback for a bare `maki index` run outside tests/run-lua.sh.
local results_path = env("MAKI_TEST_RESULTS")
  or maki.fs.joinpath(cwd, "tests", "lua-results.txt")

-- maki ships a small test harness; use it as the assertion layer rather than
-- inventing a second one. It wraps each case in pcall and reports at the end.
local helpers = require("maki.test_helpers")

local lines = {}
local failures = 0
local passed = 0

local function emit(s)
  lines[#lines + 1] = s
end

-- Load a module from maki/lua/metronome/<name>.lua with the real maki global.
local function load_module(name)
  local path = maki.fs.joinpath(cwd, "maki", "lua", "metronome", name .. ".lua")
  local src, err = maki.fs.read(path)
  if not src then
    error("cannot read module " .. name .. ": " .. tostring(err))
  end
  local chunk, lerr = loadstring(src, "@" .. path)
  if not chunk then
    error("cannot compile module " .. name .. ": " .. tostring(lerr))
  end
  setfenv(chunk, setmetatable({ maki = maki }, { __index = _G }))
  return chunk()
end

local function fail(msg)
  failures = failures + 1
  emit("FAIL " .. msg)
end

local function ok(msg)
  passed = passed + 1
  emit("ok " .. msg)
end

-- Count and record, then hand the assertion to maki's helper, which raises on
-- failure so the rest of that case is skipped instead of piling up noise.
local function eq(got, want, label)
  if got ~= want then
    fail(string.format("%s: got %s, want %s", label, tostring(got), tostring(want)))
    helpers.eq(got, want, label)
  else
    ok(label)
  end
end

local function has(s, needle, label)
  if type(s) ~= "string" or not s:find(needle, 1, true) then
    fail(string.format("%s: %q not found", label, tostring(needle)))
    helpers.has(s, needle, label)
  else
    ok(label)
  end
end

-- A suffix private to this process, used when the shell harness exported no
-- token: pid (uv's own first, /proc as a fallback), a high-resolution stamp
-- when the host has one, and a random tail. Nothing is seeded: pid and the
-- clock already separate processes, and seeding from os.time()/os.clock()
-- (CPU time in Lua 5.1) made two processes started in the same second draw the
-- same tail, i.e. the same token.
local function process_suffix()
  local pid = "0"
  if type(maki.uv.os_getpid) == "function" then
    pid = tostring(maki.uv.os_getpid())
  end
  if pid == "0" then
    local stat = maki.fs.read("/proc/self/stat")
    if type(stat) == "string" then
      pid = stat:match("^(%d+)") or pid
    end
  end
  local stamp = nil
  if type(maki.uv.hrtime) == "function" then
    stamp = tostring(maki.uv.hrtime())
  end
  if not stamp then
    stamp = tostring(os.time()) .. tostring(os.clock()):gsub("%.", "")
  end
  return string.format("%s-%s-%d", pid, stamp, math.random(100000, 999999))
end

local test_token = env("MAKI_TEST_TOKEN") or process_suffix()

-- Root of the per-test workspaces: one test owns <root>/<name>.
--
-- The token must be applied exactly once. Inside tests/run-lua.sh,
-- XDG_STATE_HOME already equals the run dir, so <state_dir> is <run>/maki and
-- the shell exports MAKI_TEST_JOURNALS -- the very tree validate_journal()
-- inspects. Re-appending the token here would write outside that tree and turn
-- the journal check into a spurious failure. Outside the harness neither
-- variable is exported, so a process-private suffix keeps standalone runs
-- isolated under <state_dir>/metronome-tests/<suffix>/<name>.
local function tests_root()
  local journals = env("MAKI_TEST_JOURNALS")
  if journals then
    return journals
  end
  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests")
  if env("MAKI_TEST_TOKEN") then
    return base
  end
  return maki.fs.joinpath(base, test_token)
end

-- Workspace for one test: derived from tests_root(), emptied and recreated so a
-- rerun never inherits stale files.
local function test_dir(name)
  local dir = maki.fs.joinpath(tests_root(), name)
  if maki.fs.metadata(dir) then
    maki.fs.rm(dir, { recursive = true })
  end
  maki.fs.mkdir(dir, { parents = true })
  return dir
end

-- Exercise the helper on every run: if test_dir() ever resolves outside the
-- journals root, the journals it holds become invisible to validate_journal(),
-- so prove it here instead of failing later with a misleading message.
do
  local root = tests_root()
  local dir = test_dir("harness-probe")
  local inside = dir:sub(1, #root + 1) == root .. "/"
  local marker = maki.fs.joinpath(dir, "probe.txt")
  maki.fs.write(marker, "ok\n")
  local back = maki.fs.read(marker)
  if inside and back == "ok\n" then
    ok("test_dir writes inside the journals root (" .. dir .. ")")
  else
    fail("test_dir resolved outside the journals root: " .. tostring(dir)
      .. " (root " .. tostring(root) .. ")")
  end
  if maki.fs.metadata(dir) then
    maki.fs.rm(dir, { recursive = true })
  end
end

local function run_file(path)
  local src, err = maki.fs.read(path)
  if not src then
    fail("cannot read " .. path .. ": " .. tostring(err))
    return
  end
  local chunk, lerr = loadstring(src, "@" .. path)
  if not chunk then
    fail("cannot compile " .. path .. ": " .. tostring(lerr))
    return
  end
  local env = {
    maki = maki,
    require = require,
    load_module = load_module,
    eq = eq,
    has = has,
    ok = ok,
    fail = fail,
    emit = emit,
    mktmpdir = helpers.mktmpdir,
    rmtree = helpers.rmtree,
    test_dir = test_dir,
    test_root = tests_root,
    test_token = test_token,
  }
  setfenv(chunk, setmetatable(env, { __index = _G }))
  local okrun, body = pcall(chunk)
  if not okrun then
    fail(path .. " threw while loading: " .. tostring(body))
    return
  end
  if type(body) == "function" then
    local okbody, berr = pcall(body)
    if not okbody then
      fail(path .. " threw while running: " .. tostring(berr))
    end
  end
end

local dir = maki.fs.joinpath(cwd, "tests", "lua")
local entries = maki.fs.dir(dir)
if not entries then
  fail("no tests/lua directory at " .. dir)
else
  local names = {}
  for _, entry in ipairs(entries) do
    local name, kind = entry[1], entry[2]
    if kind == "file" and name:match("%.lua$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    emit("-- " .. name)
    helpers.case(name, function()
      run_file(maki.fs.joinpath(dir, name))
    end)
  end
end

-- report() raises when a case failed; the failures are already counted above,
-- so its message is only useful when something escaped the per-case wrapper.
local reported, report_err = pcall(helpers.report)
if not reported and failures == 0 then
  fail("uncaught case failure: " .. tostring(report_err))
end

emit(string.format("SUMMARY passed=%d failed=%d", passed, failures))
maki.fs.write(results_path, table.concat(lines, "\n") .. "\n")
