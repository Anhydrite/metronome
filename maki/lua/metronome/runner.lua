-- Run one agent turn and record everything about it.
--
-- The runner owns the parts of a run that must be identical for every role:
-- opening the session, retrying what is worth retrying, writing a durable run
-- directory, and capturing cost and tokens. It deliberately does not decide
-- what a role does — that is the pipeline's job.
--
-- Two seams make it testable without spending a token:
--   * `opts.open_session` defaults to maki.agent.session and can be replaced.
--   * `opts.clock` defaults to os.time and can be replaced.
-- Everything else is real: the run directory, the retry policy, the cost
-- arithmetic.

local M = {}

local fs = maki.fs
local json = maki.json

-- Errors that mean "a human or the host stopped this". Retrying them would
-- fight the person who pressed Esc, so they end the run immediately.
local NOT_RETRYABLE = {
  ["cancelled"] = true,
  ["stopped by user"] = true,
  ["stopped by parent agent"] = true,
  ["session closed"] = true,
}

function M.classify_error(err)
  if not err then
    return "none"
  end
  local text = tostring(err):lower()
  for needle in pairs(NOT_RETRYABLE) do
    if text:find(needle, 1, true) then
      return "fatal"
    end
  end
  return "retryable"
end

-- A run directory is the evidence for one attempt: the prompt that was sent,
-- the answer that came back, and the metadata that ties them together.
function M.run_dir(state_root, task_id, phase, attempt)
  return fs.joinpath(state_root, "runs", task_id, phase, tostring(attempt))
end

local function write_attempt(dir, prompt, meta)
  fs.mkdir(dir, { parents = true })
  fs.write(fs.joinpath(dir, "prompt.txt"), prompt or "")
  fs.write(fs.joinpath(dir, "meta.json"), json.encode(meta))
end

local function write_result(dir, result)
  fs.write(fs.joinpath(dir, "result.json"), json.encode(result))
end

-- Run one role turn.
--
-- opts:
--   role, task_id, phase, prompt, system, model_spec, thinking, tools
--   state_root        where runs/ lives
--   max_attempts      default 3
--   deadline_secs     optional; a run slower than this is marked timed_out
--   open_session      injectable, defaults to maki.agent.session
--   clock             injectable, defaults to os.time
--
-- Returns a result table, never raises:
--   { ok, text, error, attempts, cost, input_tokens, output_tokens,
--     duration_ms, run_dir, timed_out, fatal }
-- Resolve the role's tool set into the definitions array
-- `maki.agent.session` expects. A config whitelist is a list of names, not
-- definitions: asking the host for those names is the only way to get tools a
-- subagent can actually call. Without this, the implementer opened a session
-- with no tools and answered with a plan instead of writing the file.
local function default_tools(ctx, tools)
  if type(tools) == "table" and type(tools[1]) == "table" then
    return tools
  end
  if not (maki.agent and type(maki.agent.tools) == "function") then
    return tools
  end
  local req = { audience = "general_sub" }
  if type(tools) == "table" and #tools > 0 then
    req.only = tools
  end
  local ok, defs = pcall(maki.agent.tools, ctx, req)
  if ok and defs then
    return defs
  end
  return tools
end

M._default_tools = default_tools

function M.run(opts)
  if type(opts) ~= "table" then
    return { ok = false, error = "runner.run needs an options table", attempts = 0 }
  end
  if type(opts.prompt) ~= "string" or opts.prompt == "" then
    return { ok = false, error = "runner.run needs a prompt", attempts = 0 }
  end

  local clock = opts.clock or os.time
  local open_session = opts.open_session or maki.agent.session
  local resolve_tools = opts.resolve_tools or default_tools
  local max_attempts = opts.max_attempts or 3
  local state_root = opts.state_root
  local task_id = opts.task_id or "unknown"
  local phase = opts.phase or "run"

  local total_cost = 0
  local total_in, total_out = 0, 0
  local last_error = nil
  local last_timed_out = false
  local started = clock()

  for attempt = 1, max_attempts do
    local dir = state_root and M.run_dir(state_root, task_id, phase, attempt) or nil
    local attempt_started = clock()

    local session, open_err = open_session(opts.ctx, {
      name = "metronome-" .. tostring(opts.role or "role"),
      model_spec = opts.model_spec,
      thinking = opts.thinking,
      system = opts.system,
      tools = resolve_tools(opts.ctx, opts.tools),
    })

    if not session then
      last_error = "open failed: " .. tostring(open_err)
      if dir then
        write_attempt(dir, opts.prompt, { attempt = attempt, error = last_error })
      end
      -- An open failure is a configuration problem; retrying it just burns
      -- time, so it ends the run.
      return {
        ok = false,
        error = last_error,
        attempts = attempt,
        cost = total_cost,
        input_tokens = total_in,
        output_tokens = total_out,
        duration_ms = (clock() - started) * 1000,
        run_dir = dir,
        fatal = true,
      }
    end

    local result, prompt_err = session:prompt(opts.prompt)
    session:close()

    local elapsed = clock() - attempt_started
    local timed_out = opts.deadline_secs ~= nil and elapsed > opts.deadline_secs

    local tokens_in = (result and result.input_tokens) or 0
    local tokens_out = (result and result.output_tokens) or 0
    total_in = total_in + tokens_in
    total_out = total_out + tokens_out

    local attempt_record = {
      attempt = attempt,
      role = opts.role,
      task_id = task_id,
      phase = phase,
      duration_secs = elapsed,
      input_tokens = tokens_in,
      output_tokens = tokens_out,
      timed_out = timed_out,
      error = prompt_err and tostring(prompt_err) or nil,
      text = result and result.text or nil,
    }
    if dir then
      write_attempt(dir, opts.prompt, attempt_record)
      write_result(dir, attempt_record)
    end

    if not prompt_err and not timed_out then
      return {
        ok = true,
        text = result and result.text or "",
        attempts = attempt,
        cost = total_cost,
        input_tokens = total_in,
        output_tokens = total_out,
        duration_ms = (clock() - started) * 1000,
        run_dir = dir,
        timed_out = false,
      }
    end

    last_error = timed_out and ("timed out after " .. tostring(elapsed) .. "s") or tostring(prompt_err)
    last_timed_out = timed_out

    local kind = timed_out and "retryable" or M.classify_error(prompt_err)
    if kind == "fatal" then
      return {
        ok = false,
        error = last_error,
        attempts = attempt,
        cost = total_cost,
        input_tokens = total_in,
        output_tokens = total_out,
        duration_ms = (clock() - started) * 1000,
        run_dir = dir,
        timed_out = timed_out,
        fatal = true,
      }
    end
  end

  return {
    ok = false,
    error = last_error,
    attempts = max_attempts,
    cost = total_cost,
    input_tokens = total_in,
    output_tokens = total_out,
    duration_ms = (clock() - started) * 1000,
    timed_out = last_timed_out,
    exhausted = true,
  }
end

return M
