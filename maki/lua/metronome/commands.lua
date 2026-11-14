-- Slash commands for Metronome.
--
-- maki command names are single tokens, so the eleven commands from the plan
-- are subcommands of one `/metronome` dispatcher: `/metronome init`,
-- `/metronome submit <intention>`, and so on. The dispatcher parses the
-- subcommand, normalises its arguments into the same input shape the matching
-- tool takes, and forwards it to an injected runtime. Like tools.lua, this
-- module never runs a pipeline step: it only shapes the call and formats the
-- answer so a handler cannot raise into maki.

local M = {}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_word(s)
  return tostring(s or ""):match("^(%S+)")
end

local function need_id(rest, name)
  local id = first_word(rest)
  if not id then
    return nil, name .. " needs a task id"
  end
  return { id = id }
end

-- The eleven subcommands, in the order the system prompt lists them. `build`
-- turns the raw argument string into the input table the runtime expects; a
-- missing or malformed argument is refused here, before any work starts.
M.COMMANDS = {
  {
    name = "init",
    description = "Bind a project: ask the config questions, then write the state and prompts.",
    usage = "/metronome init [--defaults | key=value ...]",
    build = function(rest)
      local text = trim(rest)
      if text == "" then
        return { ask = true }
      end
      if text == "--defaults" or text == "--yes" then
        return { defaults = true }
      end
      local answers = {}
      for token in text:gmatch("%S+") do
        local key, value = token:match("^([%w_]+)=(.*)$")
        if key and value ~= "" then
          answers[key] = value
        end
      end
      if next(answers) == nil then
        return nil, "init needs key=value pairs, or --defaults"
      end
      return { answers = answers }
    end,
  },
  {
    name = "submit",
    description = "Create an intent from an intention and start qualification.",
    usage = "/metronome submit <intention>",
    build = function(rest)
      if trim(rest) == "" then
        return nil, "submit needs an intention"
      end
      return { intention = trim(rest) }
    end,
  },
  {
    name = "status",
    description = "Show task state, or one task in detail.",
    usage = "/metronome status [id]",
    build = function(rest)
      return { id = first_word(rest) }
    end,
  },
  {
    name = "answer",
    description = "Open the pending question queue, or answer id=text pairs.",
    usage = "/metronome answer [id=text ...]",
    build = function(rest)
      if trim(rest) == "" then
        return { open = true }
      end
      local answers = {}
      for token in trim(rest):gmatch("%S+") do
        local id, text = token:match("^([^=]+)=(.*)$")
        if id and trim(text) ~= "" then
          answers[id] = trim(text)
        end
      end
      if next(answers) == nil then
        return nil, "answer needs id=text pairs, or no argument to open the queue"
      end
      return { answers = answers }
    end,
  },
  {
    name = "calibrate",
    description = "Analyze the repository and generate review-rules.md.",
    usage = "/metronome calibrate [--dry-run]",
    build = function(rest)
      return { dry_run = trim(rest):find("--dry%-run") ~= nil }
    end,
  },
  {
    name = "retry",
    description = "Restart a failed task from its last stable phase.",
    usage = "/metronome retry <id>",
    build = function(rest)
      return need_id(rest, "retry")
    end,
  },
  {
    name = "abandon",
    description = "Archive a task.",
    usage = "/metronome abandon <id>",
    build = function(rest)
      return need_id(rest, "abandon")
    end,
  },
  {
    name = "config",
    description = "Show the project configuration, or update it with key=value pairs.",
    usage = "/metronome config [key=value ...]",
    build = function(rest)
      local text = trim(rest)
      if text == "" then
        return {}
      end
      local answers = {}
      for token in text:gmatch("%S+") do
        local key, value = token:match("^([%w_]+)=(.*)$")
        if key and value ~= "" then
          answers[key] = value
        end
      end
      if next(answers) == nil then
        return nil, "config needs key=value pairs, or no argument to read it"
      end
      return { answers = answers }
    end,
  },
  {
    name = "panel",
    description = "Open, close or toggle the live panel.",
    usage = "/metronome panel [open|close|toggle]",
    build = function(rest)
      local action = first_word(rest) or "toggle"
      if action ~= "open" and action ~= "close" and action ~= "toggle" then
        return nil, "panel action must be open, close or toggle"
      end
      return { action = action }
    end,
  },
  {
    name = "resume",
    description = "Restart tasks interrupted by a reload.",
    usage = "/metronome resume",
    build = function()
      return {}
    end,
  },
  {
    name = "feedback",
    description = "Rate a review's findings to calibrate the reviewer.",
    usage = "/metronome feedback <id> [up|down]",
    build = function(rest)
      local id, vote = trim(rest):match("^(%S+)%s*(%S*)")
      if not id then
        return nil, "feedback needs a task id"
      end
      if vote == "" then
        vote = nil
      end
      return { id = id, vote = vote }
    end,
  },
  {
    name = "on",
    description = "Turn on natural-language routing: requests call the matching tool.",
    usage = "/metronome on",
    build = function()
      return { value = "on" }
    end,
  },
  {
    name = "off",
    description = "Turn off natural-language routing.",
    usage = "/metronome off",
    build = function()
      return { value = "off" }
    end,
  },
}

local INDEX = {}
for _, command in ipairs(M.COMMANDS) do
  INDEX[command.name] = command
end

-- The subcommand table without the builders, for docs and tests.
function M.definitions()
  local list = {}
  for _, command in ipairs(M.COMMANDS) do
    list[#list + 1] = {
      name = command.name,
      description = command.description,
      usage = command.usage,
    }
  end
  return list
end

function M.names()
  local list = {}
  for _, command in ipairs(M.COMMANDS) do
    list[#list + 1] = command.name
  end
  return list
end

function M.help()
  local lines = { "Metronome commands:" }
  for _, command in ipairs(M.COMMANDS) do
    lines[#lines + 1] = "  " .. command.usage .. "  — " .. command.description
  end
  return table.concat(lines, "\n")
end

-- Parse a command line into `{ command, input, raw }`. Accepts either the raw
-- `opts.args` string or an `opts.fargs` list, because maki hands both.
function M.parse(args)
  local raw
  if type(args) == "table" then
    raw = args.args
    if raw == nil and type(args.fargs) == "table" then
      raw = table.concat(args.fargs, " ")
    end
  elseif type(args) == "string" then
    raw = args
  end
  raw = trim(raw)

  local name, rest = raw:match("^(%S+)%s*(.*)$")
  if not name then
    return nil, "missing subcommand; try /metronome status"
  end
  local command = INDEX[name]
  if not command then
    return nil, "unknown subcommand: " .. name .. "; try /metronome status"
  end
  local input, err = command.build(rest)
  if not input then
    return nil, err
  end
  return { command = name, input = input, raw = rest }
end

-- Render a runtime result as text. Mirrors tools.format: a string passes
-- through, a scalar is stringified, a table is JSON, and an unencodable table
-- falls back to tostring rather than raising.
function M.format(result)
  local t = type(result)
  if t == "string" then
    return result
  end
  if t == "boolean" or t == "number" then
    return tostring(result)
  end
  if t == "table" then
    local ok, encoded = pcall(maki.json.encode, result)
    if ok and encoded then
      return encoded
    end
    return tostring(result)
  end
  return tostring(result)
end

-- Render the init questions as text the user can answer with key=value pairs.
function M.format_questions(questions)
  local lines = { "Metronome init — answer with /metronome init key=value ..." }
  for _, question in ipairs(questions) do
    lines[#lines + 1] = string.format("  %s = %s  (%s)",
      tostring(question.key), tostring(question.default), tostring(question.question))
  end
  lines[#lines + 1] = "Or /metronome init --defaults to accept every default."
  return table.concat(lines, "\n")
end

-- Show a block of text in a floating window. A command handler cannot print to
-- the transcript and a flash is one line, so long answers get their own
-- readable window. Returns false when there is no UI (headless, tests), and the
-- caller falls back to the text.
function M.show_text(title, text)
  if not (maki.ui and type(maki.ui.buf) == "function" and type(maki.ui.open_win) == "function") then
    return false
  end
  local buf = maki.ui.buf()
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    buf:line(line)
  end
  local win = maki.ui.open_win(buf, {
    title = title,
    anchor = "NE",
    width = "60%",
    height = "50%",
    footer = { { "q", "close" }, { "Esc", "close" } },
  })
  local function close()
    if maki.keymap then
      pcall(maki.keymap.del, "n", "q", { buffer = buf })
      pcall(maki.keymap.del, "n", "<Esc>", { buffer = buf })
    end
    if win and type(win.close) == "function" then
      win:close()
    end
  end
  if maki.keymap then
    pcall(maki.keymap.set, "n", "q", close, { buffer = buf })
    pcall(maki.keymap.set, "n", "<Esc>", close, { buffer = buf })
  end
  return true
end

function M.show_questions(questions)
  return M.show_text("Metronome init", M.format_questions(questions))
end

-- Ask the questions the way maki asks any other question: send the agent a
-- prompt that tells it to use the built-in `question` tool, so the user
-- answers in the normal prompt instead of a plugin-owned window. Returns true
-- when the prompt was accepted; the caller falls back to `show_questions` when
-- no live session can take it.
function M.ask_questions(questions)
  if type(questions) ~= "table" or #questions == 0 then
    return false
  end
  if not (maki.session and type(maki.session.prompt) == "function") then
    return false
  end
  local lines = {
    "Metronome needs answers to configure this project.",
    "Ask the user with the `question` tool (one question per entry), then call `metronome_config` with the answers; the key of each answer is shown in parentheses.",
  }
  for _, q in ipairs(questions) do
    lines[#lines + 1] = string.format("- (%s) %s — default: %s",
      tostring(q.key), tostring(q.question), tostring(q.default))
  end
  local sent = maki.session.prompt(table.concat(lines, "\n"))
  return sent ~= nil
end

-- Parse, dispatch and normalise. Every path returns a table with `ok`, so the
-- caller can flash an error instead of raising.
function M.run(runtime, args)
  local parsed, err = M.parse(args)
  if not parsed then
    return { ok = false, error = err }
  end

  local fn = type(runtime) == "table" and runtime[parsed.command] or nil
  if type(fn) ~= "function" then
    return { ok = false, error = "command not wired: " .. parsed.command }
  end

  local ok, result = pcall(fn, parsed.input)
  if not ok then
    return { ok = false, error = tostring(result) }
  end
  if result == nil then
    return { ok = false, error = "no result" }
  end
  if type(result) == "table" then
    if result.ok == false then
      return { ok = false, error = tostring(result.error or "failed"), result = result }
    end
    if result.llm_output ~= nil then
      return { ok = true, command = parsed.command, text = result.llm_output, result = result }
    end
  end
  return { ok = true, command = parsed.command, text = M.format(result), result = result }
end

-- Register the `/metronome` dispatcher. `register`, `flash`,
-- `show_questions`, `show_text` and `ask_questions` are injected so a test can
-- observe the spec and the message without a real UI.
function M.register(runtime, register, flash, show_questions, show_text, ask_questions)
  register = register or maki.api.register_command
  show_questions = show_questions or M.show_questions
  show_text = show_text or M.show_text
  ask_questions = ask_questions or M.ask_questions
  local spec = {
    name = "/metronome",
    description = "Drive the Metronome pipeline: init, submit, status, answer, calibrate, retry, abandon, config, panel, resume, feedback.",
    nargs = "*",
    handler = function(opts)
      local result = M.run(runtime, opts)
      -- Do not drain the queue here: a role session opened inside a command
      -- handler is still tied to the UI turn. The plugin's top-level spawn loop
      -- picks the queued work up within a second, off any turn.
      local text = result.ok and result.text or ("error: " .. tostring(result.error))
      local questions = not result.ok and type(result.result) == "table"
        and result.result.questions or nil
      if type(questions) == "table" then
        local asked = ask_questions(questions)
        if asked then
          text = "Metronome needs answers — the questions are in the chat"
        else
          local shown = show_questions(questions)
          if shown then
            text = "init needs answers — see the Metronome init window"
          else
            text = text .. "\n" .. M.format_questions(questions)
          end
        end
      elseif result.ok and result.command == "config" then
        local payload = type(result.result) == "table" and result.result or {}
        if payload.updated then
          text = "config updated: " .. tostring(payload.path)
        elseif type(result.text) == "string" then
          local shown = show_text("Metronome config", result.text)
          if shown then
            text = "config: " .. tostring(payload.path)
          end
        end
      end
      local show = flash
      if type(show) ~= "function" then
        show = maki.ui and maki.ui.flash
      end
      if type(show) == "function" then
        pcall(show, text)
      end
      return text
    end,
  }
  register(spec)
  return { "/metronome" }
end

return M
