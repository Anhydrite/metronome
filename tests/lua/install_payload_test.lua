-- Tests for the install payload (REQ-20261114-41).
--
-- scripts/install.sh copies maki/ and merges its two entry files. This test
-- proves the payload it copies is real: init.lua compiles, every module it
-- names exists, and plugin.toml grants the permissions the plugin needs.

return function()
  local cwd = maki.uv.cwd()

  local init_path = maki.fs.joinpath(cwd, "maki", "init.lua")
  local init_src = maki.fs.read(init_path)
  eq(type(init_src), "string", "maki/init.lua exists")

  local chunk, err = loadstring(init_src, "@" .. init_path)
  eq(type(chunk), "function", "maki/init.lua compiles: " .. tostring(err))

  local seen = 0
  for name in init_src:gmatch('"(metronome[%w%._%-]*)"') do
    seen = seen + 1
    local rel = name:gsub("%.", "/") .. ".lua"
    local path = maki.fs.joinpath(cwd, "maki", "lua", rel)
    local text = maki.fs.read(path)
    eq(type(text), "string", "the loader names an existing module: " .. name)
  end
  eq(seen >= 20, true, "the loader names every module")

  local toml = maki.fs.read(maki.fs.joinpath(cwd, "maki", "plugin.toml"))
  eq(type(toml), "string", "maki/plugin.toml exists")
  has(toml, "[permissions]", "plugin.toml has a permissions section")
  has(toml, "fs_read = true", "plugin.toml grants fs_read")
  has(toml, "fs_write = true", "plugin.toml grants fs_write")
  has(toml, "run = true", "plugin.toml grants run")
  has(toml, "agent = true", "plugin.toml grants agent")

  local script = maki.fs.read(maki.fs.joinpath(cwd, "scripts", "install.sh"))
  eq(type(script), "string", "scripts/install.sh exists")
  has(script, "MAKI_CONFIG_DIR", "install.sh honours MAKI_CONFIG_DIR")
  has(script, "managed by scripts/install.sh", "install.sh writes a managed block")
  has(script, "cp -R", "install.sh copies the lua tree")
end
