-- Recovery entry point for the crash test (REQ-20261114-18).
--
-- The shell test cannot call into Lua directly, so it drops a request file
-- naming a state root; this loads that root through state.lua and writes what
-- it recovered. Running it is the "restart" half of the crash scenario.
local cwd = maki.uv.cwd()
local request = maki.fs.joinpath(cwd, "tests", "recover-request.txt")
local text = maki.fs.read(request)
if not text then
  return
end
local root = text:gsub("%s+$", "")
maki.fs.rm(request)

local path = maki.fs.joinpath(cwd, "maki", "lua", "metronome", "state.lua")
local src = maki.fs.read(path)
local chunk = loadstring(src, "@" .. path)
setfenv(chunk, setmetatable({ maki = maki }, { __index = _G }))
local state = chunk()

local snapshot = state.load(root)
local lines = { "events=" .. tostring(snapshot.events) }
local ids = {}
for id in pairs(snapshot.tasks) do
  ids[#ids + 1] = id
end
table.sort(ids)
for _, id in ipairs(ids) do
  lines[#lines + 1] = "task=" .. id .. " status=" .. tostring(snapshot.tasks[id].status)
end
maki.fs.write(maki.fs.joinpath(cwd, "tests", "recover-result.txt"), table.concat(lines, "\n") .. "\n")
