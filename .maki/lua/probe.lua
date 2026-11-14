local dir = maki.env.state_dir()
local out = {}
local function add(s) out[#out+1] = s end
add("load=" .. tostring(type(load)))
add("loadstring=" .. tostring(type(loadstring)))
add("require=" .. tostring(type(require)))
add("dofile=" .. tostring(type(dofile)))
add("setfenv=" .. tostring(type(setfenv)))
local ok, err = pcall(function()
  if type(load) == "function" then
    local chunk, e = load("return 1 + 1", "=probe")
    add("load_ok=" .. tostring(chunk ~= nil) .. " err=" .. tostring(e))
    if chunk then add("load_result=" .. tostring(chunk())) end
  end
end)
add("load_pcall=" .. tostring(ok) .. " " .. tostring(err))
maki.fs.write(dir .. "/probe-loaded.txt", table.concat(out, "\n") .. "\n")
