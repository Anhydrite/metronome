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

-- A suffix private to this process, used when no harness token is exported:
-- pid (from /proc when readable), clock and randomness, so standalone runs stay
-- isolated from each other too.
local function process_suffix()
  local pid = "0"
  local stat = maki.fs.read("/proc/self/stat")
  if type(stat) == "string" then
    pid = stat:match("^(%d+)") or pid
  end
  local stamp = tostring(os.time()) .. tostring(os.clock()):gsub("%.", "")
  math.randomseed(tonumber(stamp:sub(-9)) or os.time())
  return string.format("%s-%s-%d", pid, stamp, math.random(100000, 999999))
end

local test_token = env("MAKI_TEST_TOKEN") or process_suffix()

-- Workspace for one test: <state_dir>/metronome-tests/<token>/<name>. The token
-- comes from tests/run-lua.sh, so every run owns a distinct tree; the directory
-- is emptied and recreated so a rerun never inherits stale files.
local function test_dir(name)
  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", test_token)
  local dir = maki.fs.joinpath(base, name)
  if maki.fs.metadata(dir) then
    maki.fs.rm(dir, { recursive = true })
  end
  maki.fs.mkdir(dir, { parents = true })
  return dir
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
