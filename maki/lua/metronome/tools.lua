-- Tool surface for Metronome.
--
-- The eight tools the conductor drives the pipeline with. They are thin
-- adapters: every definition is a maki tool spec without a handler, and every
-- call is forwarded to an injected runtime table. The runtime itself is the
-- pipeline wiring (REQ-39); this module never implements a step, it only
-- shapes the input, guards the call, and formats the answer so a handler can
-- never raise into maki.

local M = {}

-- The eight tools, in the order the system prompt lists them. A definition
-- carries no handler on purpose: `definitions()` is pure data, and `register`
-- is what copies a spec and attaches the forwarding handler.
function M.definitions()
  return {
    {
      name = "metronome_submit",
      description = "Create an intent from an intention and start qualification. Blocks until qualification returns, then answers with the created tasks (or the questions the qualifier raised). The pipeline then runs in the background: do not poll with sleeps, call metronome_status only when you need it.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          intention = {
            type = "string",
            description = "The intention to deliver, captured verbatim.",
          },
        },
        required = { "intention" },
      },
    },
    {
      name = "metronome_status",
      description = "Read the state of all tasks, or the detail of one task by id.",
      permission = "fs_read",
      schema = {
        type = "object",
        properties = {
          id = {
            type = "string",
            description = "Task id to inspect. Omit to read every task.",
          },
        },
      },
    },
    {
      name = "metronome_answer",
      description = "Deliver answers to the pending question round.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          answers = {
            type = "object",
            description = "Question id to answer text.",
            additionalProperties = { type = "string" },
          },
        },
        required = { "answers" },
      },
    },
    {
      name = "metronome_retry",
      description = "Restart a failed, stalled or abandoned task from its last stable phase.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          id = {
            type = "string",
            description = "Task id to restart.",
          },
        },
        required = { "id" },
      },
    },
    {
      name = "metronome_abandon",
      description = "Archive a task.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          id = {
            type = "string",
            description = "Task id to archive.",
          },
        },
        required = { "id" },
      },
    },
    {
      name = "metronome_stop",
      description = "Stop an in-flight task: cancel its session and park it as abandoned with a reason. The task can be restarted with metronome_retry.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          id = {
            type = "string",
            description = "Task id to stop.",
          },
        },
        required = { "id" },
      },
    },
    {
      name = "metronome_delete",
      description = "Remove a task from the panel and status. The journal keeps the history; the task disappears from status and the panel.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          id = {
            type = "string",
            description = "Task id to delete.",
          },
        },
        required = { "id" },
      },
    },
    {
      name = "metronome_calibrate",
      description = "Analyze the repository and generate review-rules.md.",
      permission = "run",
      schema = {
        type = "object",
        properties = {
          dry_run = {
            type = "boolean",
            description = "Analyze and report without writing review-rules.md.",
          },
        },
      },
    },
    {
      name = "metronome_config",
      description = "Read the project configuration, or update it. Pass answers to change settings; they are merged with the config on disk, so changing one model does not reset the checks or the merge/deploy policy.",
      -- The handler writes the fixed project config path through the plugin,
      -- which holds fs_write. The tool itself declares fs_read: maki requires a
      -- schema `mutable_path` for fs_write, and the path is not model-supplied.
      permission = "fs_read",
      schema = {
        type = "object",
        properties = {
          answers = {
            type = "object",
            description = "Configuration keys to change (for example implementer_model), merged with the current config.",
            additionalProperties = { type = "string" },
          },
        },
      },
    },
    {
      name = "metronome_panel",
      description = "Open, close or toggle the live panel.",
      permission = "fs_read",
      schema = {
        type = "object",
        properties = {
          action = {
            type = "string",
            enum = { "open", "close", "toggle" },
            description = "Panel action. Defaults to toggle.",
          },
        },
      },
    },
  }
end

-- Render a runtime result as the text a tool handler returns. A string is
-- already text, a scalar is stringified, and a table is encoded as JSON. A
-- table that cannot be encoded must not raise: fall back to tostring.
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

-- Forward one call to the runtime and normalise the outcome. Every path
-- returns a table with an `llm_output`, and failures set `is_error` instead of
-- raising, so a broken runtime surfaces as a tool error and not a crash.
function M.call(runtime, name, input, ctx)
  -- The tool surface names are prefixed (`metronome_submit`); the runtime
  -- table the commands share uses the bare verb (`submit`). Accept both so a
  -- single runtime can serve both adapters.
  local fn = nil
  if type(runtime) == "table" then
    fn = runtime[name] or runtime[tostring(name):gsub("^metronome_", "")]
  end
  if type(fn) ~= "function" then
    return { llm_output = "error: tool " .. tostring(name) .. " is not wired", is_error = true }
  end

  local ok, result, err = pcall(fn, input or {}, ctx)
  if not ok then
    return { llm_output = "error: " .. tostring(result), is_error = true }
  end

  if result == nil then
    return { llm_output = "error: " .. tostring(err or "no result"), is_error = true }
  end

  if type(result) == "table" then
    if result.ok == false then
      return { llm_output = "error: " .. tostring(result.error or "failed"), is_error = true }
    end
    if result.llm_output ~= nil then
      return result
    end
  end

  return { llm_output = M.format(result) }
end

-- The handler map maki expects: one forwarding function per tool name.
function M.handlers(runtime)
  local map = {}
  for _, def in ipairs(M.definitions()) do
    local name = def.name
    map[name] = function(input, ctx)
      return M.call(runtime, name, input, ctx)
    end
  end
  return map
end

-- Register every tool with maki. The spec is shallow-copied so the handler
-- attached here never leaks back into `definitions()`. `register` is injected
-- so a test can observe what would have been registered.
function M.register(runtime, register)
  register = register or maki.api.register_tool
  local names = {}
  for _, def in ipairs(M.definitions()) do
    local spec = {}
    for key, value in pairs(def) do
      spec[key] = value
    end
    spec.handler = function(input, ctx)
      return M.call(runtime, def.name, input, ctx)
    end
    register(spec)
    names[#names + 1] = def.name
  end
  return names
end

return M
