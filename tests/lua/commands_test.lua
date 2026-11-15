-- Tests for maki/lua/metronome/commands.lua (REQ-20261114-38).
--
-- maki command names are single tokens, so the eleven `/metronome <verb>`
-- commands are one dispatcher. These tests pin the subcommand table, the
-- argument normalisation, and the forwarding to an injected runtime.

return function()
  local commands = load_module("commands")

  local NAMES = {
    "init", "submit", "status", "answer", "calibrate", "retry",
    "abandon", "stop", "delete", "config", "panel", "resume", "feedback", "on", "off",
  }

  -- definitions ------------------------------------------------------------

  local defs = commands.definitions()
  eq(#defs, 15, "definitions returns every subcommand")
  for i, name in ipairs(NAMES) do
    eq(defs[i] and defs[i].name, name, "subcommand " .. i .. " is " .. name)
    eq(type(defs[i] and defs[i].description), "string", name .. " has a description")
    eq(#(defs[i] and defs[i].description or "") > 0, true, name .. " description is non-empty")
    eq(type(defs[i] and defs[i].usage), "string", name .. " has a usage line")
    eq(defs[i] and defs[i].build, nil, name .. " definition hides its builder")
  end

  local names = commands.names()
  eq(#names, 15, "names returns every subcommand")
  eq(names[1], "init", "names starts with init")
  eq(names[13], "feedback", "feedback stays before the mode toggles")
  eq(names[15], "off", "names ends with off")

  local help = commands.help()
  eq(help:find("/metronome submit [--fast|--full|--auto] <intention>", 1, true) ~= nil, true,
    "help lists submit and its complexity flags")
  eq(help:find("/metronome panel", 1, true) ~= nil, true, "help lists panel")
  eq(help:find("/metronome on", 1, true) ~= nil, true, "help lists on")
  eq(help:find("/metronome off", 1, true) ~= nil, true, "help lists off")

  -- parse: dispatch --------------------------------------------------------

  local parsed, err = commands.parse("")
  eq(parsed, nil, "an empty command line is refused")
  eq(type(err), "string", "the empty command line names the reason")

  parsed, err = commands.parse("nope")
  eq(parsed, nil, "an unknown subcommand is refused")
  eq(err:find("unknown subcommand", 1, true) ~= nil, true, "the refusal names the unknown subcommand")

  parsed = commands.parse("init")
  eq(parsed.command, "init", "init parses")
  eq(parsed.input.ask, true, "init without arguments asks the questions")
  parsed = commands.parse("init --defaults")
  eq(parsed.input.defaults, true, "init --defaults accepts every default")
  parsed = commands.parse("init base_ref=master auto_merge=true")
  eq(parsed.input.answers.base_ref, "master", "init parses key=value answers")
  eq(parsed.input.answers.auto_merge, "true", "init keeps every answer")
  parsed, err = commands.parse("init nonsense")
  eq(parsed, nil, "init refuses an argument that is not key=value")
  eq(err:find("key=value", 1, true) ~= nil, true, "the init refusal explains the shape")

  parsed = commands.parse("submit add CSV export")
  eq(parsed.command, "submit", "submit parses")
  eq(parsed.input.intention, "add CSV export", "submit keeps the whole intention")
  eq(parsed.input.complexity, nil, "submit defaults to auto complexity")

  parsed = commands.parse("submit --fast add a red button")
  eq(parsed.input.complexity, "fast", "--fast asks for the fast lane")
  eq(parsed.input.intention, "add a red button", "--fast is stripped from the intention")

  parsed = commands.parse("submit --full redesign the checkout")
  eq(parsed.input.complexity, "full", "--full forces qualification")
  eq(parsed.input.intention, "redesign the checkout", "--full is stripped from the intention")

  parsed, err = commands.parse("submit")
  eq(parsed, nil, "submit without an intention is refused")
  eq(err:find("intention", 1, true) ~= nil, true, "the submit refusal names the intention")

  parsed = commands.parse("status")
  eq(parsed.input.id, nil, "status without an id is allowed")
  parsed = commands.parse("status T-20261114-a3f2")
  eq(parsed.input.id, "T-20261114-a3f2", "status takes an id")

  parsed = commands.parse("answer")
  eq(parsed.input.open, true, "answer with no argument opens the queue")
  parsed = commands.parse("answer q1=postgres q2=5432")
  eq(parsed.input.answers.q1, "postgres", "answer parses the first pair")
  eq(parsed.input.answers.q2, "5432", "answer parses the second pair")
  parsed, err = commands.parse("answer nonsense")
  eq(parsed, nil, "answer without a pair is refused")
  eq(err:find("id=text", 1, true) ~= nil, true, "the answer refusal explains the shape")

  parsed = commands.parse("calibrate")
  eq(parsed.input.dry_run, false, "calibrate defaults to writing")
  parsed = commands.parse("calibrate --dry-run")
  eq(parsed.input.dry_run, true, "calibrate recognises --dry-run")

  parsed = commands.parse("retry T-20261114-b7c1")
  eq(parsed.input.id, "T-20261114-b7c1", "retry takes an id")
  parsed, err = commands.parse("retry")
  eq(parsed, nil, "retry without an id is refused")
  eq(err:find("task id", 1, true) ~= nil, true, "the retry refusal names the id")

  parsed = commands.parse("abandon T-20261114-c9d0")
  eq(parsed.input.id, "T-20261114-c9d0", "abandon takes an id")
  eq(commands.parse("abandon"), nil, "abandon without an id is refused")

  parsed = commands.parse("config")
  eq(next(parsed.input), nil, "config with no argument reads the config")
  parsed = commands.parse("config implementer_model=acme/coder")
  eq(parsed.input.answers.implementer_model, "acme/coder", "config parses key=value updates")
  parsed, err = commands.parse("config nonsense")
  eq(parsed, nil, "config refuses an argument that is not key=value")
  eq(err:find("key=value", 1, true) ~= nil, true, "the config refusal explains the shape")

  parsed = commands.parse("panel")
  eq(parsed.input.action, "toggle", "panel defaults to toggle")
  eq(commands.parse("panel open").input.action, "open", "panel takes open")
  eq(commands.parse("panel close").input.action, "close", "panel takes close")
  parsed, err = commands.parse("panel bogus")
  eq(parsed, nil, "panel refuses an unknown action")
  eq(err:find("open, close or toggle", 1, true) ~= nil, true, "the panel refusal names the actions")

  parsed = commands.parse("resume")
  eq(next(parsed.input), nil, "resume takes no arguments")

  parsed = commands.parse("feedback T-20261114-a3f2 up")
  eq(parsed.input.id, "T-20261114-a3f2", "feedback takes an id")
  eq(parsed.input.vote, "up", "feedback takes a vote")
  eq(commands.parse("feedback T-20261114-a3f2").input.vote, nil, "feedback vote is optional")
  eq(commands.parse("feedback"), nil, "feedback without an id is refused")

  parsed = commands.parse("on")
  eq(parsed.command, "on", "on parses")
  eq(parsed.input.value, "on", "on carries the value")
  parsed = commands.parse("off")
  eq(parsed.command, "off", "off parses")
  eq(parsed.input.value, "off", "off carries the value")

  -- parse: fargs fallback --------------------------------------------------

  parsed = commands.parse({ fargs = { "retry", "T-1" } })
  eq(parsed.command, "retry", "parse accepts fargs")
  eq(parsed.input.id, "T-1", "fargs are joined into the argument string")

  -- run --------------------------------------------------------------------

  local seen = {}
  local runtime = {
    init = function(input)
      seen.init = input
      return "project bound"
    end,
    submit = function(input)
      seen.submit = input
      return "submitted"
    end,
    status = function(input)
      seen.status = input
      return { ok = true, llm_output = "one task" }
    end,
    answer = function(input)
      seen.answer = input
      return { ok = false, error = "no pending round" }
    end,
    retry = function(input)
      seen.retry = input
      return 42
    end,
  }

  local ok_run = commands.run(runtime, "init")
  eq(ok_run.ok, true, "run reports success")
  eq(ok_run.command, "init", "run names the subcommand")
  eq(ok_run.text, "project bound", "run returns the runtime text")

  local submit_run = commands.run(runtime, { args = "submit add CSV export" })
  eq(submit_run.text, "submitted", "run dispatches through args")
  eq(seen.submit.intention, "add CSV export", "run passes the parsed input")

  local status_run = commands.run(runtime, "status T-1")
  eq(status_run.text, "one task", "run honours llm_output")
  eq(seen.status.id, "T-1", "run passes the status id")

  local answer_run = commands.run(runtime, "answer")
  eq(answer_run.ok, false, "a runtime refusal is an error")
  eq(answer_run.error, "no pending round", "the runtime error is preserved")

  local retry_run = commands.run(runtime, "retry T-1")
  eq(retry_run.ok, true, "a scalar result is a success")
  eq(retry_run.text, "42", "a scalar result is stringified")

  local parse_fail = commands.run(runtime, "bogus")
  eq(parse_fail.ok, false, "run refuses an unknown subcommand")
  eq(parse_fail.error:find("unknown subcommand", 1, true) ~= nil, true, "run names the unknown subcommand")

  local unwired = commands.run(runtime, "abandon T-1")
  eq(unwired.ok, false, "run refuses an unwired subcommand")
  eq(unwired.error:find("not wired", 1, true) ~= nil, true, "run names the missing wiring")

  local question_runtime = {
    init = function()
      return {
        ok = false,
        error = "project is not bound",
        questions = { { key = "repo", default = "/tmp/x", question = "repository path" } },
      }
    end,
  }
  local asked = commands.run(question_runtime, "init")
  eq(asked.ok, false, "an init question round is not a success")
  eq(type(asked.result.questions), "table", "run keeps the questions")
  local rendered = commands.format_questions(asked.result.questions)
  eq(rendered:find("repo = /tmp/x", 1, true) ~= nil, true, "format_questions lists the key and default")
  eq(rendered:find("--defaults", 1, true) ~= nil, true, "format_questions names the shortcut")

  local raising = {
    init = function()
      error("boom")
    end,
  }
  local raised = commands.run(raising, "init")
  eq(raised.ok, false, "a raising runtime becomes an error")
  eq(raised.error:find("boom", 1, true) ~= nil, true, "the raised message is kept")

  -- format ----------------------------------------------------------------

  eq(commands.format("text"), "text", "format passes a string through")
  eq(commands.format(true), "true", "format stringifies a boolean")
  eq(commands.format({ a = 1 }):find("\"a\"", 1, true) ~= nil, true, "format encodes a table as JSON")

  -- register --------------------------------------------------------------

  local registered = {}
  local function fake_register(spec)
    registered[#registered + 1] = spec
  end
  local flashed = {}
  local function fake_flash(text)
    flashed[#flashed + 1] = text
  end

  local shown_questions = nil
  local function fake_show_questions(questions)
    shown_questions = questions
    return true
  end

  local registered_names = commands.register(runtime, fake_register, fake_flash, fake_show_questions)
  eq(#registered_names, 1, "register registers one dispatcher")
  eq(registered_names[1], "/metronome", "the dispatcher is /metronome")
  eq(#registered, 1, "one command spec was registered")
  eq(registered[1].name, "/metronome", "the spec is named /metronome")
  eq(registered[1].nargs, "*", "the dispatcher accepts any number of arguments")
  eq(type(registered[1].description), "string", "the dispatcher has a description")
  eq(registered[1].description:find("feedback", 1, true) ~= nil, true, "the description lists feedback")
  eq(type(registered[1].handler), "function", "the dispatcher has a handler")

  seen.submit = nil
  local out = registered[1].handler({ args = "submit through handler" })
  eq(out, "submitted", "the handler returns the runtime text")
  eq(seen.submit.intention, "through handler", "the handler passes the input through")
  eq(flashed[#flashed], "submitted", "the handler flashes the result")

  local failed_out = registered[1].handler({ args = "bogus" })
  eq(failed_out:find("error:", 1, true) ~= nil, true, "the handler prefixes an error")
  eq(flashed[#flashed]:find("unknown subcommand", 1, true) ~= nil, true, "the handler flashes the error")

  -- The init questions are asked natively, through the agent's question tool.
  local asked_questions = nil
  local function fake_ask_questions(questions)
    asked_questions = questions
    return true
  end
  commands.register(question_runtime, fake_register, fake_flash, fake_show_questions,
    nil, fake_ask_questions)
  local question_spec = registered[#registered]
  asked_questions = nil
  shown_questions = nil
  local question_out = question_spec.handler({ args = "init" })
  eq(type(asked_questions), "table", "the handler asks the init questions natively")
  eq(asked_questions[1].key, "repo", "the asked questions come from the runtime")
  eq(shown_questions, nil, "the custom window is not used when the native ask works")
  eq(question_out:find("in the chat", 1, true) ~= nil, true,
    "the flash points at the chat")

  -- If no live session can take the prompt, fall back to the window.
  local function fake_ask_fails()
    return false
  end
  commands.register(question_runtime, fake_register, fake_flash, fake_show_questions,
    nil, fake_ask_fails)
  local fallback_spec = registered[#registered]
  shown_questions = nil
  local fallback_out = fallback_spec.handler({ args = "init" })
  eq(type(shown_questions), "table", "the fallback window shows the questions")
  eq(fallback_out:find("Metronome init window", 1, true) ~= nil, true,
    "the fallback flash points at the window")

  -- `/metronome config` shows the config, and an update is reported.
  local shown_text = nil
  local function fake_show_text(title, text)
    shown_text = { title = title, text = text }
    return true
  end
  local config_runtime = {
    config = function(input)
      if input and input.answers then
        return { ok = true, updated = true, path = "/tmp/config.toml" }
      end
      return { ok = true, path = "/tmp/config.toml", llm_output = "[project]\nrepo = \"/tmp\"" }
    end,
  }
  commands.register(config_runtime, fake_register, fake_flash, fake_show_questions, fake_show_text)
  local config_spec = registered[#registered]
  shown_text = nil
  local config_out = config_spec.handler({ args = "config" })
  eq(type(shown_text), "table", "the config command shows the config in a window")
  eq(shown_text.title, "Metronome config", "the config window is titled")
  eq(shown_text.text:find("[project]", 1, true) ~= nil, true, "the window carries the config")
  eq(config_out:find("config: /tmp/config.toml", 1, true) ~= nil, true,
    "the flash names the config path")
  local updated_out = config_spec.handler({ args = "config implementer_model=x" })
  eq(updated_out:find("config updated", 1, true) ~= nil, true,
    "an update is reported")

  local fresh = commands.definitions()
  eq(fresh[1].handler, nil, "definitions stay pure after register")
  eq(registered[1] ~= fresh[1], true, "register builds its own spec")

  -- Every subcommand has a runtime method ----------------------------------

  local runtime_mod = load_module("runtime")
  local fake_deps = {}
  for _, name in ipairs({
    "config", "state", "roles", "runner", "git", "qualify", "questions",
    "analyze", "implement", "checks", "converge", "review", "merge",
    "deploy", "calibrate", "pipeline", "fence", "mode",
  }) do
    fake_deps[name] = {}
  end
  local real_runtime = runtime_mod.new(fake_deps)
  eq(type(real_runtime), "table", "the real runtime wires with stub modules")
  for _, name in ipairs(commands.names()) do
    eq(type(real_runtime[name]), "function", "the runtime implements /metronome " .. name)
  end
end
