-- Tests for maki/lua/metronome/mode.lua.
--
-- The on/off mode is a persisted flag plus a prompt hint evaluated before every
-- run: when it is on, the agent is told to call the matching tool instead of
-- answering in prose. A prompt hint is used instead of an `agent.user_message`
-- layer because an agent slot costs every permission, and a plugin with
-- `env = false` would have the layer silently skipped.

return function()
  local mode = load_module("mode")

  -- Flag -------------------------------------------------------------------

  local root = mktmpdir("metronome-mode")
  eq(mode.enabled(root), false, "mode is off by default")
  eq(mode.set(root, "on"), true, "set on writes the flag")
  eq(mode.enabled(root), true, "mode reads on")
  eq(mode.set(root, "off"), false, "set off clears the flag")
  eq(mode.enabled(root), false, "mode reads off")
  eq(mode.enabled(nil), false, "mode is off without a root")

  eq(mode.set(root, "on", "chat-42"), true, "set on records the session")
  eq(mode.main_session(root), "chat-42", "the main session is recorded")
  eq(mode.enabled(root), true, "mode with a session still reads on")
  eq(mode.set(root, "off"), false, "set off clears the session flag")
  eq(mode.main_session(root), nil, "off clears the main session")

  local bad, bad_err = mode.set(root, "maybe")
  eq(bad, nil, "set refuses an unknown value")
  eq(type(bad_err), "string", "the refusal names the value")

  -- Rewrite ----------------------------------------------------------------

  local text = mode.rewrite("ajoute une tache export CSV")
  eq(text:find("Metronome mode is ON", 1, true) ~= nil, true, "the directive announces the mode")
  eq(text:find("metronome_submit", 1, true) ~= nil, true, "the directive names submit")
  eq(text:find("metronome_status", 1, true) ~= nil, true, "the directive names status")
  eq(text:find("metronome_abandon", 1, true) ~= nil, true, "the directive names abandon")
  eq(text:find("`question` tool", 1, true) ~= nil, true, "the directive asks the user with the question tool")
  eq(text:find("Never invent an answer", 1, true) ~= nil, true, "the directive forbids inventing answers")
  eq(text:find("Never sleep, poll", 1, true) ~= nil, true, "the directive forbids polling for a task")
  eq(text:find("code_execution", 1, true) ~= nil, true, "the directive forbids code_execution polling")
  eq(text:find("ajoute une tache export CSV", 1, true) ~= nil, true, "the directive keeps the request")

  -- Hint -------------------------------------------------------------------

  local hint
  local register_prompt_hint = function(spec)
    hint = spec
  end

  local slots = {}
  local set_slot = function(name, fn)
    slots[name] = fn
  end

  local enabled = true
  local main_session = "main-session"
  local runtime = {
    mode_enabled = function()
      return enabled
    end,
    main_session = function()
      return main_session
    end,
  }

  eq(mode.register(runtime, {
    register_prompt_hint = register_prompt_hint,
    set_slot = set_slot,
  }), true, "register installs the prompt hint")
  eq(type(hint), "table", "register passes a spec")
  eq(hint.slot, "tool_usage", "the hint lives in the tool_usage slot")
  eq(type(hint.content), "function", "the hint content is evaluated before every run")

  local on_text = hint.content()
  eq(type(on_text), "string", "the hint returns text")
  eq(on_text:find("Metronome mode is ON", 1, true) ~= nil, true, "the hint routes when on")
  eq(on_text:find("metronome_submit", 1, true) ~= nil, true, "the hint names submit")

  enabled = false
  eq(hint.content(), "", "the hint is empty when off")

  -- Guard ------------------------------------------------------------------

  for _, slot in ipairs({
    "tool.write.input",
    "tool.edit.input",
    "tool.bash.input",
    "tool.code_execution.input",
  }) do
    eq(type(slots[slot]), "function", "register guards " .. slot)
  end

  local function prev(input)
    return input
  end

  enabled = true
  local blocked, reason = slots["tool.write.input"](prev, { path = "x" }, {})
  eq(blocked, nil, "the guard blocks a main-session write")
  eq(type(reason), "string", "the block explains why")
  eq(reason:find("metronome_submit", 1, true) ~= nil, true, "the block names the pipeline tool")

  eq(slots["tool.bash.input"](prev, { command = "rm -rf /" }, {}), nil,
    "the guard blocks a main-session shell command")

  mode.enter_subagent()
  local subagent_input = slots["tool.write.input"](prev, { path = "x" }, {})
  eq(subagent_input.path, "x", "the guard lets a pipeline subagent write")
  eq(slots["tool.bash.input"](prev, { command = "ls" }, {}).command, "ls",
    "the guard lets a pipeline subagent run a command")
  mode.leave_subagent()
  eq(slots["tool.write.input"](prev, { path = "x" }, {}), nil,
    "the guard blocks again once the subagent is done")

  enabled = false
  local off_input = slots["tool.write.input"](prev, { path = "x" }, {})
  eq(off_input.path, "x", "the guard lets the main session write when the mode is off")

  local no_runtime, no_runtime_err = mode.register({}, { register_prompt_hint = register_prompt_hint })
  eq(no_runtime, nil, "register refuses a runtime without mode_enabled")
  eq(type(no_runtime_err), "string", "the refusal names the missing method")

  rmtree(root)
end
