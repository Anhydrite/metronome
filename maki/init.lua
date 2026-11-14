-- Metronome plugin entry point.
--
-- Installed into ~/.config/maki/init.lua by scripts/install.sh, inside a
-- managed block so the user's own code is preserved. Loading a module has no
-- side effects: the tools, the commands and the panel are registered by the
-- runtime once a project is bound. Loading them here is what makes /reload a
-- proof that the installed tree is complete and compiles.

local modules = {
  "metronome.config",
  "metronome.state",
  "metronome.roles",
  "metronome.runner",
  "metronome.git",
  "metronome.qualify",
  "metronome.questions",
  "metronome.analyze",
  "metronome.implement",
  "metronome.checks",
  "metronome.converge",
  "metronome.review",
  "metronome.merge",
  "metronome.calibrate",
  "metronome.deploy",
  "metronome.pipeline",
  "metronome.fence",
  "metronome.tools",
  "metronome.commands",
  "metronome.mode",
  "metronome.runtime",
  "metronome.ui.render",
  "metronome.ui.panel",
}

for _, name in ipairs(modules) do
  local ok, err = pcall(require, name)
  if not ok then
    maki.log.error("metronome: cannot load " .. name .. ": " .. tostring(err))
  end
end

-- Register the tool and command surface. The runtime owns the pipeline; the
-- adapters only shape the call, so a broken project fails at the call, not at
-- plugin load.
local function wire()
  local deps = {
    config = require("metronome.config"),
    state = require("metronome.state"),
    roles = require("metronome.roles"),
    runner = require("metronome.runner"),
    git = require("metronome.git"),
    qualify = require("metronome.qualify"),
    questions = require("metronome.questions"),
    analyze = require("metronome.analyze"),
    implement = require("metronome.implement"),
    checks = require("metronome.checks"),
    converge = require("metronome.converge"),
    review = require("metronome.review"),
    merge = require("metronome.merge"),
    calibrate = require("metronome.calibrate"),
    deploy = require("metronome.deploy"),
    pipeline = require("metronome.pipeline"),
    fence = require("metronome.fence"),
    mode = require("metronome.mode"),
    ui_render = require("metronome.ui.render"),
    ui_panel = require("metronome.ui.panel"),
  }
  local runtime, err = require("metronome.runtime").new(deps)
  if not runtime then
    maki.log.error("metronome: runtime not wired: " .. tostring(err))
    return
  end
  require("metronome.tools").register(runtime)
  require("metronome.commands").register(runtime)
  local routed, route_err = require("metronome.mode").register(runtime)
  if not routed then
    maki.log.warn("metronome: natural-language mode not wired: " .. tostring(route_err))
  end
  maki.log.info("metronome: tools and /metronome commands registered")
end

local wired, wire_err = pcall(wire)
if not wired then
  maki.log.error("metronome: wiring failed: " .. tostring(wire_err))
end
