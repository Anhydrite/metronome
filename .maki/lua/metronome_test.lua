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

-- Isolation token. init.lua resolves it once (MAKI_TEST_TOKEN, or a
-- process-local suffix when the variable is absent) and passes it in as
-- test_token_value, so the error file and these results always land in the same
-- <state_dir>/metronome-tests/<token>/ directory. Resolving it again here keeps
-- this file usable on its own.
-- Process-local suffix used when MAKI_TEST_TOKEN is absent (a test file or the
-- harness run on its own). The pid keeps it unique; the fallback stays numeric
-- and seed-free of odd characters, because it ends up as a directory name.
local function local_test_suffix()
  local pid
  if type(maki.uv) == "table" then
    for _, name in ipairs({ "os_getpid", "getpid" }) do
      local fn = maki.uv[name]
      if type(fn) == "function" then
        local ok, value = pcall(fn)
        if ok and value then pid = tonumber(value) or pid; break end
      end
    end
  end
  pid = pid or 0
  math.randomseed(os.time() + pid)
  return string.format("local-%d-%d-%d", pid, os.time(), math.random(0, 999999))
end

local function resolve_test_token()
  if type(test_token_value) == "string" and test_token_value ~= "" then
    return test_token_value
  end
  -- maki.env only exposes state_dir/config_dir/logs_dir/legacy_dir, so reading
  -- the token goes through maki.env.get when it exists, then uv.os_getenv.
  local readers = {}
  if type(maki.env) == "table" and type(maki.env.get) == "function" then
    readers[#readers + 1] = maki.env.get
  end
  if type(maki.uv) == "table" and type(maki.uv.os_getenv) == "function" then
    readers[#readers + 1] = maki.uv.os_getenv
  end
  for _, reader in ipairs(readers) do
    local ok, value = pcall(reader, "MAKI_TEST_TOKEN")
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return local_test_suffix()
end

local TEST_TOKEN = resolve_test_token()
local test_dir = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", TEST_TOKEN)
maki.fs.mkdir(test_dir, { parents = true })
local results_path = maki.fs.joinpath(test_dir, "lua-results.txt")

-- test_base(label): the directory a test file uses for its throwaway state. It
-- lives under this run's token, so a concurrent run has its own, and it starts
-- empty so a rerun is not polluted by the previous one.
local function test_base(label)
  local base = maki.fs.joinpath(test_dir, label)
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })
  return base
end

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
    test_base = test_base,
    test_token = function() return TEST_TOKEN end,
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
