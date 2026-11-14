-- Config loading for Metronome.
--
-- maki's Lua host has no TOML decoder, so this parses the subset config.toml
-- actually uses: table headers, string/number/boolean values, arrays of
-- scalars, and comments. Anything outside that subset is refused with the
-- line number rather than silently misread — a config that half-loads is
-- worse than one that fails.
--
-- The host-side validator (tools/validate-config.py) is the fuller contract;
-- this loader enforces the same rules at runtime, and the tests keep the two
-- from drifting.

local M = {}

local KNOWN_ROLES = { "analyst", "deployer", "implementer", "qualifier", "reviewer" }

local THINKING = {
  off = true,
  minimal = true,
  low = true,
  medium = true,
  adaptive = true,
  high = true,
  xhigh = true,
  max = true,
}

local MODEL_PATTERN = "^[a-z0-9_%-]+/[a-z0-9_.%-]+$"

-- Parsing -------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cut a trailing comment that is not inside a quoted string.
local function strip_comment(line)
  local in_string = false
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == '"' then
      in_string = not in_string
    elseif c == "#" and not in_string then
      return line:sub(1, i - 1)
    end
  end
  return line
end

local function parse_scalar(raw, lineno)
  local value = trim(raw)
  if value == "" then
    error(string.format("line %d: missing value", lineno))
  end
  if value:sub(1, 1) == '"' then
    local inner = value:match('^"(.-)"%s*$')
    if not inner then
      error(string.format("line %d: unterminated string", lineno))
    end
    return inner
  end
  if value == "true" then
    return true
  end
  if value == "false" then
    return false
  end
  if value:sub(1, 1) == "[" then
    local inner = value:match("^%[(.-)%]%s*$")
    if not inner then
      error(string.format("line %d: unterminated array", lineno))
    end
    local list = {}
    for piece in inner:gmatch("[^,]+") do
      local p = trim(piece)
      if p ~= "" then
        list[#list + 1] = parse_scalar(p, lineno)
      end
    end
    return list
  end
  local number = tonumber(value)
  if number then
    return number
  end
  error(string.format("line %d: cannot read value %q", lineno, value))
end

-- Parse TOML text into a table. Raises on anything outside the subset, with
-- the line number, so a bad config names where it went wrong.
function M.parse(text)
  if type(text) ~= "string" then
    error("config text must be a string")
  end
  local root = {}
  local current = root
  local lineno = 0

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local clean = trim(strip_comment(line))
    if clean ~= "" then
      local header = clean:match("^%[(.-)%]$")
      if header then
        current = root
        for part in header:gmatch("[^%.]+") do
          local next_table = current[part]
          if next_table == nil then
            next_table = {}
            current[part] = next_table
          elseif type(next_table) ~= "table" then
            error(string.format("line %d: %q is already a value, not a table", lineno, part))
          end
          current = next_table
        end
      else
        local key, raw = clean:match("^([%w_%-%.]+)%s*=%s*(.*)$")
        if not key then
          error(string.format("line %d: cannot read %q", lineno, clean))
        end
        current[key] = parse_scalar(raw, lineno)
      end
    end
  end

  return root
end

-- Validation ----------------------------------------------------------------

local function validate_role(name, spec, problems)
  if type(spec) ~= "table" then
    problems[#problems + 1] = string.format("role %q is not a table", name)
    return
  end
  if type(spec.model) ~= "string" or not spec.model:match(MODEL_PATTERN) then
    problems[#problems + 1] = string.format("roles.%s.model: invalid spec %q", name, tostring(spec.model))
  end
  if type(spec.thinking) ~= "string" or not THINKING[spec.thinking] then
    problems[#problems + 1] = string.format("roles.%s.thinking: unknown level %q", name, tostring(spec.thinking))
  end
end

-- Check a parsed config and return it with defaults applied, or a list of
-- problems. Every problem names the field, because "invalid config" alone
-- sends the user hunting.
function M.validate(config)
  local problems = {}

  if type(config) ~= "table" then
    return nil, { "config is not a table" }
  end

  local project = config.project
  if type(project) ~= "table" then
    problems[#problems + 1] = "project section is missing"
  else
    if type(project.repo) ~= "string" or project.repo:sub(1, 1) ~= "/" then
      problems[#problems + 1] = "project.repo must be an absolute path"
    end
    if type(project.base_ref) ~= "string" or project.base_ref == "" then
      problems[#problems + 1] = "project.base_ref is missing"
    end
    if project.max_parallel ~= nil and (type(project.max_parallel) ~= "number" or project.max_parallel < 1) then
      problems[#problems + 1] = "project.max_parallel must be at least 1"
    end
  end

  local roles = config.roles
  if type(roles) ~= "table" then
    problems[#problems + 1] = "roles section is missing"
  else
    for _, name in ipairs(KNOWN_ROLES) do
      if roles[name] == nil then
        problems[#problems + 1] = string.format("roles.%s is missing", name)
      else
        validate_role(name, roles[name], problems)
      end
    end
  end

  if #problems > 0 then
    return nil, problems
  end

  -- Defaults, applied only once the config is known to be sound.
  config.project.max_parallel = config.project.max_parallel or 2
  config.git = config.git or {}
  config.git.branch_prefix = config.git.branch_prefix or "metronome/"
  config.git.commit_style = config.git.commit_style or "conventional"
  config.git.pr_draft = config.git.pr_draft or false

  config.checks = config.checks or {}
  config.checks.default = config.checks.default or {}
  config.checks.re_run_after_merge = config.checks.re_run_after_merge ~= false
  config.checks.timeout_secs = config.checks.timeout_secs or 600

  config.review = config.review or {}
  config.review.max_rounds = config.review.max_rounds or 3
  config.review.require_checks_green = config.review.require_checks_green ~= false
  config.review.protected_paths = config.review.protected_paths
    or { "review-rules.md", "AGENTS.md", ".metronome/", "deploy.md" }

  config.merge = config.merge or {}
  config.merge.auto_merge = config.merge.auto_merge or false
  config.merge.method = config.merge.method or "squash"
  config.merge.auto_rebase = config.merge.auto_rebase ~= false

  config.deploy = config.deploy or {}
  config.deploy.auto_deploy = config.deploy.auto_deploy or false
  config.deploy.confirm = config.deploy.confirm ~= false
  config.deploy.plan_file = config.deploy.plan_file or "deploy.md"

  config.quality = config.quality or {}
  config.quality.variants = config.quality.variants or 1
  config.quality.stall_minutes = config.quality.stall_minutes or 20

  config.limits = config.limits or {}
  config.limits.max_task_cost_usd = config.limits.max_task_cost_usd or 5.0
  config.limits.timeout_minutes = config.limits.timeout_minutes or 30
  config.limits.max_questions_per_round = config.limits.max_questions_per_round or 15

  return config, nil
end

-- Read and validate a config file.
function M.load(path)
  local text, err = maki.fs.read(path)
  if not text then
    return nil, { "cannot read " .. tostring(path) .. ": " .. tostring(err) }
  end
  local ok, parsed = pcall(M.parse, text)
  if not ok then
    return nil, { tostring(parsed) }
  end
  return M.validate(parsed)
end

return M
