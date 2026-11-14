-- Tests for maki/lua/metronome/roles.lua (REQ-20261114-15).

return function()
  local roles = load_module("roles")
  local cwd = maki.uv.cwd()
  local prompts_dir = maki.fs.joinpath(cwd, "prompts")

  local config = {
    roles = {
      qualifier = { model = "ocgo/deepseek-v4.1-flash", thinking = "high" },
      analyst = { model = "ocgo/deepseek-v4.1-flash", thinking = "medium" },
      implementer = { model = "opencode-go/kimi-k3", thinking = "max", tools = { "read", "write" } },
      reviewer = { model = "ocgo/deepseek-v4-pro", thinking = "high" },
      deployer = { model = "ocgo/deepseek-v4.1-flash", thinking = "medium" },
    },
  }

  -- Known roles -------------------------------------------------------------

  local known = roles.known()
  eq(#known, 5, "five roles are known")
  eq(roles.is_known("reviewer"), true, "reviewer is known")
  eq(roles.is_known("wizard"), false, "wizard is not known")

  -- Orchestra names ---------------------------------------------------------

  eq(roles.display_name("qualifier"), "chef de pupitre", "qualifier is the chef de pupitre")
  eq(roles.display_name("analyst"), "harmoniste", "analyst is the harmoniste")
  eq(roles.display_name("implementer"), "instrumentiste", "implementer is the instrumentiste")
  eq(roles.display_name("reviewer"), "critique", "reviewer is the critique")
  eq(roles.display_name("deployer"), "timbalier", "deployer is the timbalier")
  eq(roles.display_name("wizard"), "wizard", "an unknown role falls back to its key")

  local render = load_module("ui/render")
  for _, role in ipairs(known) do
    eq(render.role_name(role), roles.display_name(role),
      "the panel and roles agree on the name of " .. role)
  end

  -- Thinking ladder ---------------------------------------------------------

  eq(roles.thinking_rank("off"), 0, "off is the lowest")
  eq(roles.thinking_rank("max"), 6, "max is the highest")
  eq(roles.thinking_rank("nonsense"), nil, "unknown level has no rank")

  eq(roles.clamp_thinking("high", "max"), "high", "request above the parent is capped")
  eq(roles.clamp_thinking("max", "low"), "low", "request below the parent is kept")
  eq(roles.clamp_thinking("max", "max"), "max", "equal levels are kept")
  eq(roles.clamp_thinking(nil, "high"), "high", "unknown parent keeps the request")
  eq(roles.clamp_thinking("high", nil), "high", "no request inherits the parent")

  -- Prompt loading ----------------------------------------------------------

  local global = roles.load_prompt(prompts_dir, "_global")
  eq(type(global), "string", "global prompt loads")
  eq(global:find("shared rules") ~= nil, true, "global prompt has content")

  local missing, merr = roles.load_prompt(prompts_dir, "wizard")
  eq(missing, nil, "missing prompt returns nil")
  eq(merr ~= nil, true, "missing prompt explains itself")

  local composed, cerr = roles.compose_prompt(prompts_dir, "reviewer")
  eq(cerr, nil, "compose has no error")
  eq(composed:find("shared rules") ~= nil, true, "composed prompt starts with the global rules")
  eq(composed:find("Role — critique (reviewer)", 1, true) ~= nil, true, "composed prompt includes the role")
  eq(composed:find("shared rules") < composed:find("Role — critique (reviewer)", 1, true), true, "global comes first")

  -- Resolution --------------------------------------------------------------

  local impl, ierr = roles.resolve(config, "implementer")
  eq(ierr, nil, "known role resolves")
  eq(impl and impl.model_spec, "opencode-go/kimi-k3", "model resolved")
  eq(impl and impl.thinking, "max", "thinking resolved")
  eq(impl and impl.tools[1], "read", "tools resolved")
  eq(impl and impl.display_name, "instrumentiste", "resolution carries the orchestra name")

  -- A role without a whitelist gets a capability-declaring default, never nil.
  local qual, qerr = roles.resolve(config, "qualifier")
  eq(qerr, nil, "qualifier resolves")
  eq(type(qual and qual.tools), "table", "a role without a whitelist gets default tools")
  eq(qual and qual.tools[1], "read", "the default starts with read")
  local has_write = false
  for _, name in ipairs(qual and qual.tools or {}) do
    if name == "write" then has_write = true end
  end
  eq(has_write, false, "the qualifier default has no write tool")

  local unknown, uerr = roles.resolve(config, "wizard")
  eq(unknown, nil, "unknown role returns nil")
  eq(uerr and uerr:find("unknown role") ~= nil, true, "unknown role explains itself")
  eq(uerr and uerr:find("implementer") ~= nil, true, "unknown role lists the known ones")

  local no_model, nmerr = roles.resolve({ roles = { reviewer = { thinking = "high" } } }, "reviewer")
  eq(no_model, nil, "role without a model returns nil")
  eq(nmerr and nmerr:find("no model") ~= nil, true, "missing model explains itself")

  local bad_thinking, bterr = roles.resolve(
    { roles = { reviewer = { model = "a/b", thinking = "ultra" } } },
    "reviewer"
  )
  eq(bad_thinking, nil, "unknown thinking returns nil")
  eq(bterr and bterr:find("thinking") ~= nil, true, "unknown thinking explains itself")

  local no_roles, nerr = roles.resolve({}, "reviewer")
  eq(no_roles, nil, "config without roles returns nil")
  eq(nerr ~= nil, true, "config without roles explains itself")

  -- Resolve everything at once: a broken config fails at load, not mid-run.

  local all, aerr = roles.resolve_all(config)
  eq(aerr, nil, "complete config resolves")
  eq(all and all.qualifier ~= nil, true, "qualifier resolved")
  eq(all and all.deployer ~= nil, true, "deployer resolved")

  local broken = {
    roles = {
      qualifier = { model = "ocgo/deepseek-v4.1-flash", thinking = "high" },
      analyst = { model = "ocgo/deepseek-v4.1-flash", thinking = "medium" },
      implementer = { model = "opencode-go/kimi-k3", thinking = "max" },
      reviewer = { model = "ocgo/deepseek-v4-pro", thinking = "high" },
      -- deployer missing
    },
  }
  local none, berr = roles.resolve_all(broken)
  eq(none, nil, "incomplete config returns nil")
  eq(berr and berr:find("deployer") ~= nil, true, "incomplete config names the missing role")

  -- Session options: the shape the runner will hand to maki.agent.session.

  local opts, oerr = roles.session_opts(config, "implementer", prompts_dir, "high")
  eq(oerr, nil, "session_opts has no error")
  eq(opts and opts.model_spec, "opencode-go/kimi-k3", "session model set")
  eq(opts and opts.thinking, "high", "session thinking clamped to the parent")
  eq(opts and opts.name, "metronome-implementer", "session name set")
  eq(opts and opts.system:find("Role — instrumentiste (implementer)", 1, true) ~= nil, true, "session prompt composed")

  local unclamped = roles.session_opts(config, "implementer", prompts_dir, "max")
  eq(unclamped and unclamped.thinking, "max", "no clamp when the parent allows it")

  local missing_prompt_dir = maki.fs.joinpath(cwd, "prompts-does-not-exist")
  local no_prompt, nperr = roles.session_opts(config, "reviewer", missing_prompt_dir, "max")
  eq(no_prompt, nil, "missing prompts return nil")
  eq(nperr and nperr:find("missing prompt") ~= nil, true, "missing prompts explain themselves")
end
