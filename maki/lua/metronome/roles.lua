-- Role resolution.
--
-- A role is the bridge between config.toml and a maki subagent session: it
-- names the model, the thinking level, the tool whitelist, and the markdown
-- prompt files that shape the agent's behaviour. Everything the runner needs
-- comes from here, so a missing role or a missing prompt fails before a
-- session is opened rather than halfway through a run.

local M = {}

local fs = maki.fs

-- The roles the pipeline runs. Kept in one place so an unknown name can list
-- what does exist instead of just refusing.
local KNOWN = { "analyst", "deployer", "implementer", "qualifier", "reviewer" }

-- Orchestra names. The internal keys stay stable (config, journal, prompts and
-- modules use them); the display name is what a human reads in the panel and
-- in the role prompt headings. `ui/render.lua` mirrors this table, and the
-- tests keep the two in sync.
local NAMES = {
  qualifier = "chef de pupitre",
  analyst = "harmoniste",
  implementer = "instrumentiste",
  reviewer = "critique",
  deployer = "timbalier",
}

function M.display_name(role)
  return NAMES[role] or role
end

-- Thinking levels, cheapest first. A subagent's level is capped by its
-- parent's, which is why this ladder exists here and not only in the schema.
local THINKING_RANK = {
  off = 0,
  minimal = 1,
  low = 2,
  medium = 3,
  adaptive = 3,
  high = 4,
  xhigh = 5,
  max = 6,
}

function M.known()
  local copy = {}
  for i, name in ipairs(KNOWN) do
    copy[i] = name
  end
  return copy
end

function M.is_known(role)
  for _, name in ipairs(KNOWN) do
    if name == role then
      return true
    end
  end
  return false
end

function M.thinking_rank(level)
  return THINKING_RANK[level]
end

-- A subagent cannot think harder than its parent. Until the Phase 0 probe
-- says otherwise, the conservative assumption is that the cap is real, so the
-- effective level is the lower of the two. Returning the requested level when
-- the parent's is unknown keeps the caller honest about what it asked for.
function M.clamp_thinking(parent, requested)
  if not requested then
    return parent
  end
  if not parent then
    return requested
  end
  local pr = THINKING_RANK[parent]
  local rr = THINKING_RANK[requested]
  if pr and rr and rr > pr then
    return parent
  end
  return requested
end

-- Prompts -------------------------------------------------------------------

function M.prompt_path(prompts_dir, name)
  return fs.joinpath(prompts_dir, name .. ".md")
end

function M.load_prompt(prompts_dir, name)
  local path = M.prompt_path(prompts_dir, name)
  local text, err = fs.read(path)
  if not text then
    return nil, "missing prompt " .. path .. ": " .. tostring(err)
  end
  if text:match("^%s*$") then
    return nil, "empty prompt " .. path
  end
  return text
end

-- The global prompt sets the shared rules; the role prompt adds what that
-- role does. Both are required: a role running with only half its
-- instructions is worse than one that refuses to start.
function M.compose_prompt(prompts_dir, role)
  local global, gerr = M.load_prompt(prompts_dir, "_global")
  if not global then
    return nil, gerr
  end
  local specific, serr = M.load_prompt(prompts_dir, role)
  if not specific then
    return nil, serr
  end
  return global:gsub("%s+$", "") .. "\n\n" .. specific
end

-- Resolution ----------------------------------------------------------------

-- The tools a role may call when the config does not name a whitelist. Every
-- name here declares a capability (read/write/edit/bash), so a session opened
-- with it does not demand every plugin permission the way a capability-less
-- tool (bg_status, batch) would.
local DEFAULT_TOOLS = {
  qualifier = { "read", "glob", "grep", "list", "index" },
  analyst = { "read", "glob", "grep", "list", "index" },
  implementer = { "read", "write", "edit", "bash", "glob", "grep", "list", "index" },
  reviewer = { "read", "glob", "grep", "list", "index" },
  deployer = { "read", "bash", "glob", "grep", "list" },
}

function M.resolve(config, role)
  if type(config) ~= "table" or type(config.roles) ~= "table" then
    return nil, "config has no roles table"
  end
  if not M.is_known(role) then
    return nil, string.format("unknown role %q (known: %s)", tostring(role), table.concat(KNOWN, ", "))
  end
  local spec = config.roles[role]
  if type(spec) ~= "table" then
    return nil, string.format("role %q is not configured", role)
  end
  if type(spec.model) ~= "string" or spec.model == "" then
    return nil, string.format("role %q has no model", role)
  end
  if type(spec.thinking) ~= "string" or not THINKING_RANK[spec.thinking] then
    return nil, string.format("role %q has an unknown thinking level %q", role, tostring(spec.thinking))
  end
  local tools = spec.tools
  if type(tools) ~= "table" or #tools == 0 then
    tools = DEFAULT_TOOLS[role]
  end
  return {
    role = role,
    display_name = M.display_name(role),
    model_spec = spec.model,
    thinking = spec.thinking,
    tools = tools,
  }
end

-- Resolve every role at once, so a broken config fails at load rather than
-- when that role is first needed.
function M.resolve_all(config)
  local resolved = {}
  local problems = {}
  for _, role in ipairs(KNOWN) do
    local r, err = M.resolve(config, role)
    if r then
      resolved[role] = r
    else
      problems[#problems + 1] = err
    end
  end
  if #problems > 0 then
    return nil, table.concat(problems, "; ")
  end
  return resolved
end

-- Build the argument table maki.agent.session expects, with the prompt
-- already composed and the thinking clamped to the parent's ceiling.
function M.session_opts(config, role, prompts_dir, parent_thinking)
  local resolved, err = M.resolve(config, role)
  if not resolved then
    return nil, err
  end
  local prompt, perr = M.compose_prompt(prompts_dir, role)
  if not prompt then
    return nil, perr
  end
  return {
    name = "metronome-" .. role,
    model_spec = resolved.model_spec,
    thinking = M.clamp_thinking(parent_thinking, resolved.thinking),
    system = prompt,
    tools = resolved.tools,
  }
end

return M
