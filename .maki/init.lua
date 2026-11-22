-- Run the Metronome Lua test harness.
--
-- `require` runs a module in a context where a yielding maki.fs call fails
-- ("attempt to yield across metamethod/C-call boundary"), so the harness is
-- loaded with loadstring and run as a plain Lua chunk instead.

-- Isolation token for the test harness. tests/run-lua.sh exports
-- MAKI_TEST_TOKEN and keeps every temporary path under
-- <state_dir>/metronome-tests/<token>/; the harness error file and the results
-- live there too, so two concurrent runs never overwrite each other. A harness
-- started without the variable (a test file run alone) derives a suffix that is
-- specific to this process, so it still shares state with nobody.
local function local_test_suffix()
  local pid
  if type(maki.uv) == "table" then
    for _, name in ipairs({ "os_getpid", "getpid" }) do
      local fn = maki.uv[name]
      if type(fn) == "function" then
        local ok, value = pcall(fn)
        if ok and value then pid = value; break end
      end
    end
  end
  return string.format("local-%s-%d-%d", tostring(pid or tostring({})), os.time(),
    math.random(0, 999999))
end

local function resolve_test_token()
  local readers = {}
  -- maki.env does not expose arbitrary variables today (only state_dir,
  -- config_dir, logs_dir and legacy_dir), so os_getenv is the working fallback.
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

local function harness_dir()
  local dir = maki.env.state_dir()
  if not dir then return nil end
  return maki.fs.joinpath(dir, "metronome-tests", TEST_TOKEN)
end

-- End-to-end hook: scripts/e2e.sh sets METRONOME_E2E_DRIVER to a Lua file that
-- composes the real modules against a throwaway repository. It runs instead of
-- the unit harness, and writes its own result file.
local e2e_driver = maki.uv.os_getenv("METRONOME_E2E_DRIVER")
if e2e_driver and e2e_driver ~= "" then
  local driver_src = maki.fs.read(e2e_driver)
  if not driver_src then
    local dir = maki.env.state_dir()
    if dir then maki.fs.write(dir .. "/metronome-e2e-error.txt", "cannot read " .. e2e_driver .. "\n") end
    return
  end
  local driver_chunk, driver_err = loadstring(driver_src, "@" .. e2e_driver)
  if not driver_chunk then
    local dir = maki.env.state_dir()
    if dir then maki.fs.write(dir .. "/metronome-e2e-error.txt", "compile: " .. tostring(driver_err) .. "\n") end
    return
  end
  local driver_cwd = maki.uv.cwd()
  local function load_module(name)
    local path = maki.fs.joinpath(driver_cwd, "maki", "lua", "metronome", name .. ".lua")
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
  setfenv(driver_chunk, setmetatable({
    maki = maki,
    require = require,
    load_module = load_module,
  }, { __index = _G }))
  local ran, run_err = pcall(driver_chunk)
  if not ran then
    local dir = maki.env.state_dir()
    if dir then maki.fs.write(dir .. "/metronome-e2e-error.txt", tostring(run_err) .. "\n") end
  end
  return
end

-- The unit harness is a test entry point, not startup work: `tests/run-lua.sh`
-- opts in with METRONOME_LUA_TESTS=1. Running the full suite on every TUI
-- launch wedged the UI (the harness completes, but the TUI never draws).
local run_lua_tests = maki.uv.os_getenv("METRONOME_LUA_TESTS")
if run_lua_tests and run_lua_tests ~= "" then
local path = maki.fs.joinpath(maki.uv.cwd(), ".maki", "lua", "metronome_test.lua")
local src = maki.fs.read(path)
if not src then
  local dir = harness_dir()
  if dir then
    pcall(maki.fs.mkdir, dir, { parents = true })
    maki.fs.write(maki.fs.joinpath(dir, "metronome-harness-error.txt"), "cannot read " .. path .. "\n")
  end
  return
end
local chunk, err = loadstring(src, "@" .. path)
if not chunk then
  local dir = harness_dir()
  if dir then
    pcall(maki.fs.mkdir, dir, { parents = true })
    maki.fs.write(maki.fs.joinpath(dir, "metronome-harness-error.txt"), "compile: " .. tostring(err) .. "\n")
  end
  return
end
setfenv(chunk, setmetatable({ maki = maki, require = require, test_token_value = TEST_TOKEN }, { __index = _G }))
chunk()
end

-- Recovery entry point: the crash test drops a request file and runs maki,
-- which is the "restart after a kill" half of the scenario.
pcall(function()
  local cwd = maki.uv.cwd()
  local path = maki.fs.joinpath(cwd, ".maki", "lua", "metronome_recover.lua")
  local src = maki.fs.read(path)
  if not src then return end
  local chunk = loadstring(src, "@" .. path)
  if not chunk then return end
  setfenv(chunk, setmetatable({ maki = maki, require = require }, { __index = _G }))
  chunk()
end)
