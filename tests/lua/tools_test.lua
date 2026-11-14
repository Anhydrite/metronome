-- Tests for maki/lua/metronome/tools.lua (REQ-20261114-36).
--
-- The tools are thin adapters over an injected runtime table: the runtime is
-- the pipeline wiring (REQ-39) and is never implemented here. These tests use
-- a fake runtime and a fake register so the tool surface can be proven without
-- a model, a session or a repository.

return function()
  local tools = load_module("tools")

  local NAMES = {
    "metronome_submit",
    "metronome_status",
    "metronome_answer",
    "metronome_retry",
    "metronome_abandon",
    "metronome_delete",
    "metronome_calibrate",
    "metronome_config",
    "metronome_panel",
  }

  local function required_has(schema, field)
    if type(schema.required) ~= "table" then return false end
    for _, name in ipairs(schema.required) do
      if name == field then return true end
    end
    return false
  end

  local function by_name(defs)
    local map = {}
    for _, def in ipairs(defs) do
      map[def.name] = def
    end
    return map
  end

  -- definitions ------------------------------------------------------------

  local defs = tools.definitions()
  eq(type(defs), "table", "definitions returns a table")
  eq(#defs, 9, "definitions returns exactly 9 specs")

  for i, name in ipairs(NAMES) do
    eq(defs[i] and defs[i].name, name, "definition " .. i .. " is " .. name)
  end

  local map = by_name(defs)
  for _, name in ipairs(NAMES) do
    local def = map[name]
    eq(type(def), "table", name .. " exists")
    eq(type(def and def.description), "string", name .. " has a description")
    eq(def and #def.description > 0, true, name .. " description is non-empty")
    eq(def and def.schema and def.schema.type, "object", name .. " schema is an object")
    eq(type(def and def.permission), "string", name .. " declares a permission")
  end

  -- maki refuses a fs_write tool without a schema mutable_path, and the whole
  -- wire() then fails, taking /metronome down with it.
  for _, def in ipairs(defs) do
    if def.permission == "fs_write" then
      eq(type(def.mutable_path), "string", def.name .. " declares mutable_path with fs_write")
    end
  end

  eq(required_has(map.metronome_submit.schema, "intention"), true, "submit requires intention")
  eq(required_has(map.metronome_answer.schema, "answers"), true, "answer requires answers")
  eq(required_has(map.metronome_retry.schema, "id"), true, "retry requires id")
  eq(required_has(map.metronome_abandon.schema, "id"), true, "abandon requires id")

  eq(map.metronome_status.schema.properties.id ~= nil, true, "status has an id property")
  eq(required_has(map.metronome_status.schema, "id"), false, "status id is optional")
  eq(map.metronome_calibrate.schema.properties.dry_run ~= nil, true, "calibrate has a dry_run property")
  eq(map.metronome_calibrate.schema.properties.dry_run.type, "boolean", "calibrate dry_run is boolean")
  eq(required_has(map.metronome_calibrate.schema, "dry_run"), false, "calibrate dry_run is optional")

  local action = map.metronome_panel.schema.properties.action
  eq(type(action), "table", "panel has an action property")
  eq(action and action.enum and #action.enum, 3, "panel action has three choices")
  eq(action and action.enum[1], "open", "panel action offers open")
  eq(action and action.enum[2], "close", "panel action offers close")
  eq(action and action.enum[3], "toggle", "panel action offers toggle")
  eq(required_has(map.metronome_panel.schema, "action"), false, "panel action is optional")

  local answers = map.metronome_answer.schema.properties.answers
  eq(type(answers), "table", "answer has an answers property")
  eq(answers and answers.type, "object", "answers is an object")
  eq(answers and answers.additionalProperties and answers.additionalProperties.type, "string", "answers are strings")

  -- format -----------------------------------------------------------------

  eq(tools.format("hi"), "hi", "format leaves a string alone")
  eq(tools.format(42), "42", "format renders a number")
  eq(tools.format(true), "true", "format renders a boolean")
  eq(tools.format({ ok = true }), maki.json.encode({ ok = true }), "format encodes a table as JSON")

  -- call -------------------------------------------------------------------

  local seen = {}
  local done_result = { llm_output = "done" }
  local runtime = {
    metronome_submit = function(input, ctx)
      seen.submit = input
      seen.submit_ctx = ctx
      return "submitted " .. input.intention
    end,
    metronome_status = function(input, ctx)
      seen.status = input
      return "all tasks"
    end,
    metronome_answer = function(input, ctx)
      seen.answer = input
      return "answered"
    end,
    metronome_retry = function(input, ctx)
      return nil, "boom"
    end,
    metronome_abandon = function(input, ctx)
      error("kaboom")
    end,
    metronome_calibrate = function(input, ctx)
      return { ok = false, error = "no" }
    end,
    metronome_config = function(input, ctx)
      return done_result
    end,
    metronome_panel = function(input, ctx)
      return "panel"
    end,
  }

  local ctx = { session = "test" }

  local sub = tools.call(runtime, "metronome_submit", { intention = "ship it" }, ctx)
  eq(sub.llm_output, "submitted ship it", "call returns the runtime string")
  eq(sub.is_error, nil, "a successful call is not an error")
  eq(seen.submit and seen.submit.intention, "ship it", "submit receives the input")
  eq(seen.submit_ctx, ctx, "submit receives the maki ctx as the second argument")

  local st = tools.call(runtime, "metronome_status", nil, ctx)
  eq(type(seen.status), "table", "status receives a table when no input is given")
  eq(next(seen.status), nil, "status with no id receives an empty table")
  eq(st.llm_output, "all tasks", "status returns the runtime string")

  local ans = tools.call(runtime, "metronome_answer", { answers = { q1 = "yes" } }, ctx)
  eq(seen.answer and seen.answer.answers and seen.answer.answers.q1, "yes", "answer passes the answers map")
  eq(ans.llm_output, "answered", "answer returns the runtime string")

  local retry = tools.call(runtime, "metronome_retry", { id = "T-1" }, ctx)
  eq(retry.is_error, true, "nil result is an error")
  eq(retry.llm_output ~= nil and retry.llm_output:find("boom", 1, true) ~= nil, true, "the error carries the message")

  local abandon = tools.call(runtime, "metronome_abandon", { id = "T-1" }, ctx)
  eq(abandon.is_error, true, "a raising runtime is an error")

  local cal = tools.call(runtime, "metronome_calibrate", {}, ctx)
  eq(cal.is_error, true, "ok=false is an error")
  eq(cal.llm_output ~= nil and cal.llm_output:find("no", 1, true) ~= nil, true, "ok=false carries the error text")

  local cfg = tools.call(runtime, "metronome_config", {}, ctx)
  eq(cfg, done_result, "a table with llm_output is returned as-is")

  local short_runtime = {
    submit = function(input)
      return "short " .. input.intention
    end,
  }
  local short = tools.call(short_runtime, "metronome_submit", { intention = "x" }, ctx)
  eq(short.llm_output, "short x", "a bare runtime key serves the prefixed tool name")

  local unwired = tools.call({}, "metronome_submit", {}, ctx)
  eq(unwired.is_error, true, "an unwired tool is an error")
  eq(unwired.llm_output ~= nil and unwired.llm_output:find("not wired", 1, true) ~= nil, true, "the unwired error explains itself")

  -- handlers ---------------------------------------------------------------

  local handlers = tools.handlers(runtime)
  local count = 0
  for _ in pairs(handlers) do count = count + 1 end
  eq(count, 9, "handlers exposes nine functions")
  for _, name in ipairs(NAMES) do
    eq(type(handlers[name]), "function", "handler exists for " .. name)
  end

  seen.submit = nil
  local via_handler = handlers.metronome_submit({ intention = "through handler" }, ctx)
  eq(via_handler.llm_output, "submitted through handler", "a handler routes to the runtime")
  eq(seen.submit and seen.submit.intention, "through handler", "the handler passes the input through")

  -- register ---------------------------------------------------------------

  local registered = {}
  local function fake_register(spec)
    registered[#registered + 1] = spec
  end

  local names = tools.register(runtime, fake_register)
  eq(#names, 9, "register returns nine names")
  eq(#registered, 9, "register registers nine specs")
  for i, name in ipairs(NAMES) do
    eq(names[i], name, "registered name " .. i .. " is " .. name)
    eq(registered[i] and registered[i].name, name, "registered spec " .. i .. " is " .. name)
    eq(type(registered[i] and registered[i].handler), "function", "registered spec " .. i .. " has a handler")
  end

  seen.submit = nil
  local reg_out = registered[1].handler({ intention = "registered" }, ctx)
  eq(reg_out.llm_output, "submitted registered", "a registered handler calls the runtime")
  eq(seen.submit and seen.submit.intention, "registered", "the registered handler passes the input through")

  local fresh = tools.definitions()
  for _, def in ipairs(fresh) do
    eq(def.handler, nil, "definitions are not mutated for " .. def.name)
  end
  eq(registered[1] ~= fresh[1], true, "register copies the spec instead of mutating it")
end
