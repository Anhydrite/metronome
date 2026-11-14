-- Natural-language routing mode.
--
-- `/metronome on` persists a flag in the project state directory. While it is
-- set, a prompt hint evaluated before every run tells the agent to route plain
-- requests to the matching `metronome_*` tool instead of answering in prose.
-- The flag is read on every run, so `/metronome off` takes effect on the next
-- turn without a reload.
--
-- A prompt hint is used instead of an `agent.user_message` layer on purpose:
-- maki charges every permission to an agent slot, and a plugin that does not
-- hold all of them (for example with `env = false`) has the layer silently
-- skipped. The hint only needs `fs_read` to read the flag.

local M = {}

local fs = maki.fs

local FILE = "mode"

-- The pipeline runs synchronously: while a role session is prompting, the
-- main agent is blocked inside the tool call that started it, so no main tool
-- call can overlap. A counter is therefore a reliable marker for "this tool
-- call belongs to a pipeline subagent", which the ctx does not expose.
local active_subagents = 0

function M.enter_subagent()
  active_subagents = active_subagents + 1
end

function M.leave_subagent()
  if active_subagents > 0 then
    active_subagents = active_subagents - 1
  end
end

function M.subagent_active()
  return active_subagents > 0
end

M.DIRECTIVE = table.concat({
  "Metronome mode is ON: when the user's message is a Metronome request, call the matching tool instead of answering in prose.",
  "- a new task or intention -> metronome_submit, with the intention verbatim",
  "- status, or where is it -> metronome_status",
  "- an answer the user gave to pending questions -> metronome_answer, with exactly those answers",
  "metronome_submit waits for qualification and returns the created task ids. Report them and stop: the pipeline runs in the background. Never sleep, poll, or use code_execution/bash to wait for a task — questions arrive as prompts, and metronome_status answers instantly when the user asks.",
  "When metronome_submit or metronome_answer returns waiting_questions, ask the user those questions with the `question` tool, then call metronome_answer with the user's answers. Never invent an answer to keep moving.",
  "- retry a failed task -> metronome_retry",
  "- abandon or cancel a task -> metronome_abandon",
  "- review-rules calibration -> metronome_calibrate",
  "- project configuration -> metronome_config",
  "- open, close or toggle the live panel -> metronome_panel",
  "Never write or edit files, run shell commands, commit, push or deploy directly in this mode: the pipeline does that.",
  "Every repository change goes through metronome_submit; the implementer writes it on a task branch and opens a PR.",
  "Deployment is a pipeline phase driven by deploy.md, not a shell command, and protected paths (review-rules.md, AGENTS.md, .metronome/, config.toml, deploy.md) are never edited.",
  "If the message is not a Metronome request, answer it normally.",
}, "\n")

M.GUARD_MESSAGE = table.concat({
  "Metronome mode is on: do not write, edit, run shell commands or use code_execution directly.",
  "Submit the intention with metronome_submit; the implementer writes the code on a task branch and opens a PR.",
  "Use metronome_status to follow it, and do not sleep or poll. Deployment is a pipeline phase, not a shell command.",
}, " ")

function M.path(root)
  return fs.joinpath(root, FILE)
end

-- Read the flag. A missing file, an empty root or any value other than "on"
-- means the mode is off.
function M.enabled(root)
  if type(root) ~= "string" or root == "" then
    return false
  end
  local text = fs.read(M.path(root))
  return type(text) == "string" and text:match("^%s*on") ~= nil
end

-- The chat session that turned the mode on. The guard blocks writes from that
-- session only: a pipeline subagent runs in its own session and keeps its
-- tools. A flag written before this field existed has no id, and the guard
-- then blocks every session (the conservative choice).
function M.main_session(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local text = fs.read(M.path(root))
  if type(text) ~= "string" then
    return nil
  end
  return text:match("^%s*on%s+(%S+)")
end

-- Write or clear the flag. Returns true when on, false when off, or nil and a
-- reason for an unknown value. `session_id` records which chat session owns
-- the mode so the guard can tell it apart from a pipeline subagent.
function M.set(root, value, session_id)
  if type(root) ~= "string" or root == "" then
    return nil, "a state root is required"
  end
  if value == "on" then
    local text = "on\n"
    if type(session_id) == "string" and session_id ~= "" then
      text = "on " .. session_id .. "\n"
    end
    fs.write(M.path(root), text)
    return true
  end
  if value == "off" then
    pcall(fs.rm, M.path(root))
    return false
  end
  return nil, "mode must be on or off"
end

-- The hint text. The request itself is not rewritten; the agent sees the
-- user's words untouched and the routing rule in its prompt.
function M.rewrite(text)
  return M.DIRECTIVE .. "\n\nUser request:\n" .. tostring(text or "")
end

-- Install the prompt hint. `opts.register_prompt_hint` is injectable so a test
-- can observe the registration without a host.
function M.register(runtime, opts)
  opts = type(opts) == "table" and opts or {}
  local register = opts.register_prompt_hint
  if type(register) ~= "function" then
    register = maki.api and maki.api.register_prompt_hint
  end
  if type(register) ~= "function" then
    return nil, "register_prompt_hint is not available"
  end
  if type(runtime) ~= "table" or type(runtime.mode_enabled) ~= "function" then
    return nil, "runtime.mode_enabled is required"
  end

  local ok, err = pcall(register, {
    slot = "tool_usage",
    content = function()
      local enabled = false
      local ok_mode, value = pcall(runtime.mode_enabled)
      if ok_mode then
        enabled = value
      end
      if enabled then
        return M.DIRECTIVE
      end
      return ""
    end,
  })
  if not ok then
    return nil, tostring(err)
  end

  -- The hint alone is advisory: an agent can ignore it and start editing. In
  -- Metronome mode the main chat session is therefore blocked from the tools
  -- that change the repository or the world. A pipeline subagent runs in its
  -- own session, so its `ctx.session_id` differs from the one that turned the
  -- mode on and it keeps its tools.
  local set_slot = opts.set_slot
  if type(set_slot) ~= "function" then
    set_slot = maki.api and maki.api.set_slot
  end
  if type(set_slot) == "function" then
    local function guard(prev, input, ctx)
      if M.subagent_active() then
        return prev(input, ctx)
      end
      local enabled = false
      local ok_mode, value = pcall(runtime.mode_enabled)
      if ok_mode then
        enabled = value
      end
      if not enabled then
        return prev(input, ctx)
      end
      return nil, M.GUARD_MESSAGE
    end
    for _, slot in ipairs({
      "tool.write.input",
      "tool.edit.input",
      "tool.bash.input",
      "tool.code_execution.input",
    }) do
      pcall(set_slot, slot, guard)
    end
  end
  return true
end

return M
