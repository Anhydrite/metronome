-- Production runtime for the Metronome tools and commands.
--
-- tools.lua and commands.lua are thin adapters: they shape a call and forward
-- it to a runtime table. This module is that table. It owns the only stateful
-- decisions in the plugin: where the project state lives, which modules a
-- phase gets, and how a submit turns into a sequence of pipeline steps.
--
-- Two runners share one code path:
--   * the real runner opens a maki subagent session through runner.lua;
--   * a scripted runner, selected by METRONOME_E2E_SCRIPT, returns the same
--     shapes without a model. The tmux/GitHub end-to-end test uses it so the
--     orchestration, git, PR, merge and deploy are real while the model turns
--     stay deterministic.
--
-- Everything returns (value, err) or a result table, never raises into maki.

local M = {}

local fs = maki.fs
local json = maki.json

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function log(paths, message)
  if paths and paths.root then
    pcall(fs.append, fs.joinpath(paths.root, "runtime.log"),
      string.format("[%s] %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), tostring(message)))
  end
end

local function slug_of(path)
  local slug = tostring(path or "project"):gsub("[/\\]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = "project"
  end
  return slug
end

-- The branch a task is cut from and merges into.
--
-- A subtask of a multi-task intention carries `base_ref = <epic branch>`: its
-- worktree, its PR base, its merge target and its diff base are all the epic
-- branch, never the project base. Everything else falls back to the project
-- base, which is why the whole pipeline reads this one helper instead of
-- `cfg.project.base_ref` directly.
function M.task_base(task, cfg)
  if type(task) == "table" and is_non_empty(task.base_ref) then
    return task.base_ref
  end
  return cfg and cfg.project and cfg.project.base_ref or "main"
end

-- Sequencing defects ---------------------------------------------------------

-- The journal refuses a move that is not legal from the task's current status,
-- and names the cause with this prefix. A refusal like that, raised inside the
-- runtime, is a defect in the runtime's own sequencing: another driver moved
-- the task while this one was working. It is not a fault of the task, and it
-- must never be recorded as one.
local function is_illegal_transition(message)
  return tostring(message or ""):match("^%s*illegal transition") ~= nil
end

-- Statuses in which another pilot already owns the task: a review round, a fix
-- round, a check run, a pull request waiting on a human, a merge or a deploy.
local OWNED_STATUSES = {
  awaiting_answers = true,
  verifying = true,
  reviewing = true,
  changes_requested = true,
  pr_open = true,
  merging = true,
  merged = true,
  deploying = true,
  deployed = true,
}

-- Statuses that prove a review round's fix turn is no longer ours: the task was
-- resumed by another driver, shipped, or parked while the round was running.
local REVIEW_ROUND_LOST = {
  running = true,
  pr_open = true,
  merging = true,
  merged = true,
  deploying = true,
  deployed = true,
  failed = true,
  abandoned = true,
}

-- Paths ---------------------------------------------------------------------

function M.paths(opts)
  opts = type(opts) == "table" and opts or {}
  local repo = opts.repo or maki.uv.cwd()
  local root = opts.root
  if not root then
    local base = maki.env.state_dir()
    root = fs.joinpath(base, "metronome", slug_of(repo))
  end
  return {
    repo = repo,
    root = root,
    tasks = fs.joinpath(root, "tasks"),
    worktrees = fs.joinpath(root, "worktrees"),
    runs = fs.joinpath(root, "runs"),
    prompts = fs.joinpath(root, "prompts"),
    config = fs.joinpath(root, "config.toml"),
  }
end

-- Resolve the maki agent context for a runtime call.
--
-- tools.lua forwards the context as the second argument (`fn(input, ctx)`),
-- while a slash command has no context at all. The positional argument wins,
-- then `input.ctx`, then the focused session id (the form
-- `maki.agent.session` accepts without a ctx). A missing context must not
-- reach `maki.agent.session(nil, ...)`: that raises a LuaCtx conversion error
-- before the pipeline even starts.
function M.resolve_ctx(input, ctx)
  ctx = ctx or (type(input) == "table" and input.ctx) or nil
  if ctx == nil and maki.session and type(maki.session.current) == "function" then
    local ok, sid = pcall(maki.session.current)
    if ok and sid then
      ctx = { session = sid }
    end
  end
  return ctx
end

local DEFAULT_ROLES = {
  qualifier = { model = "ocgo/deepseek-v4.1-flash", thinking = "high" },
  analyst = { model = "ocgo/deepseek-v4.1-flash", thinking = "medium" },
  implementer = { model = "opencode-go/kimi-k3", thinking = "max" },
  reviewer = { model = "ocgo/deepseek-v4-pro", thinking = "high" },
  deployer = { model = "ocgo/deepseek-v4.1-flash", thinking = "medium" },
}

local ROLE_ORDER = { "qualifier", "analyst", "implementer", "reviewer", "deployer" }

local function toml_string(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function toml_array(values)
  local parts = {}
  for _, value in ipairs(values) do
    parts[#parts + 1] = toml_string(value)
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

-- The questions `/metronome init` asks before it writes anything. Every answer
-- has a default, so the user only overrides what they care about.
local function init_questions(repo, current)
  current = type(current) == "table" and current or {}
  local current_roles = type(current.roles) == "table" and current.roles or {}
  local checks = type(current.checks) == "table" and table.concat(current.checks, ", ") or "npm test"
  local questions = {
    { key = "repo", question = "repository path", default = current.repo or repo },
    { key = "base_ref", question = "base branch", default = current.base_ref or "main" },
    { key = "checks", question = "checks, comma separated", default = checks },
    { key = "max_parallel", question = "max parallel tasks", default = tostring(current.max_parallel or 1) },
    { key = "max_parallel_qualifiers", question = "max parallel qualifier sessions", default = tostring(current.max_parallel_qualifiers or 4) },
  }
  for _, role in ipairs(ROLE_ORDER) do
    local role_current = current_roles[role] or {}
    questions[#questions + 1] = {
      key = role .. "_model",
      question = role .. " model",
      default = role_current.model or DEFAULT_ROLES[role].model,
    }
    questions[#questions + 1] = {
      key = role .. "_thinking",
      question = role .. " thinking",
      default = role_current.thinking or DEFAULT_ROLES[role].thinking,
    }
  end
  questions[#questions + 1] = {
    key = "auto_merge",
    question = "merge PRs automatically (true/false)",
    default = tostring(current.auto_merge == true),
  }
  questions[#questions + 1] = {
    key = "auto_deploy",
    question = "deploy automatically (true/false)",
    default = tostring(current.auto_deploy == true),
  }
  return questions
end

local function truthy(value)
  return value == true or value == "true" or value == "yes" or value == "1" or value == "on"
end

local function split_checks(value)
  if type(value) == "table" then
    return value
  end
  if type(value) ~= "string" or trim(value) == "" then
    return { "npm test" }
  end
  local checks = {}
  for piece in value:gmatch("[^,]+") do
    local check = trim(piece)
    if check ~= "" then
      checks[#checks + 1] = check
    end
  end
  if #checks == 0 then
    checks[1] = "npm test"
  end
  return checks
end

-- Merge the answers with the defaults. `input.answers` is the normal shape;
-- a flat table of key=value pairs is accepted too.
-- `current` is the config already on disk, when there is one: an answer that
-- is not supplied keeps the current value instead of falling back to the
-- hardcoded default. That makes a model change safe: it does not reset the
-- checks, the base branch or the merge/deploy policy.
-- Flatten a nested answers table and dotted keys into one map, so
-- `{review={max_rounds=6}}` and `{["review.max_rounds"]=6}` mean the same
-- thing. Arrays are kept as values, not descended into.
local function flatten_answers(input, prefix, out)
  out = out or {}
  for key, value in pairs(input or {}) do
    local name = prefix and (prefix .. "." .. tostring(key)) or tostring(key)
    if type(value) == "table" and value[1] == nil and next(value) ~= nil then
      flatten_answers(value, name, out)
    else
      out[name] = value
    end
  end
  return out
end

local function pick(flat, current_section, key, default)
  local dotted = flat[key]
  if dotted ~= nil then
    return dotted
  end
  local leaf = key:match("([^.]+)$") or key
  if type(current_section) == "table" then
    if current_section[key] ~= nil then
      return current_section[key]
    end
    if current_section[leaf] ~= nil then
      return current_section[leaf]
    end
  end
  return default
end

local function as_number(value, default)
  local n = tonumber(value)
  if n == nil then
    return default
  end
  return n
end

-- Merge the answers with the defaults. `input.answers` is the normal shape;
-- a flat table of key=value pairs is accepted too, and a key may be nested or
-- dotted (`review.max_rounds`). `current` is the config already on disk, when
-- there is one: an answer that is not supplied keeps the current value
-- instead of falling back to the hardcoded default.
local function normalize_init(input, paths, current)
  current = type(current) == "table" and current or {}
  local current_roles = type(current.roles) == "table" and current.roles or {}
  local answers = type(input) == "table" and (input.answers or input) or {}
  local flat = flatten_answers(answers)

  local function value(key)
    if flat[key] ~= nil then
      return flat[key]
    end
    -- Accept the unqualified spelling too: `auto_merge` means
    -- `merge.auto_merge`, `max_rounds` means `review.max_rounds`.
    local leaf = key:match("([^.]+)$")
    if leaf and leaf ~= key and flat[leaf] ~= nil then
      return flat[leaf]
    end
    return nil
  end

  local function bool(key, current_value, default)
    local v = value(key)
    if v ~= nil then
      return truthy(v)
    end
    if current_value ~= nil then
      return current_value == true
    end
    return default
  end

  local checks
  if value("checks") ~= nil then
    checks = split_checks(value("checks"))
  elseif type(current.checks) == "table" then
    checks = current.checks
  else
    checks = { "npm test" }
  end

  local current_review = type(current.review) == "table" and current.review or {}
  local current_merge = type(current.merge) == "table" and current.merge or {}
  local current_deploy = type(current.deploy) == "table" and current.deploy or {}
  local current_quality = type(current.quality) == "table" and current.quality or {}
  local current_limits = type(current.limits) == "table" and current.limits or {}

  local deploy_confirm
  if value("deploy.confirm") ~= nil then
    deploy_confirm = truthy(value("deploy.confirm"))
  elseif value("deploy_confirm") ~= nil then
    deploy_confirm = truthy(value("deploy_confirm"))
  elseif current_deploy.confirm ~= nil then
    deploy_confirm = current_deploy.confirm == true
  elseif current.deploy_confirm ~= nil then
    deploy_confirm = current.deploy_confirm == true
  else
    deploy_confirm = true
  end

  local normalized = {
    repo = value("repo") or current.repo or paths.repo,
    base_ref = value("base_ref") or current.base_ref or "main",
    max_parallel = as_number(value("max_parallel"), current.max_parallel or 1),
    max_parallel_qualifiers = as_number(value("max_parallel_qualifiers"), current.max_parallel_qualifiers or 4),
    checks = checks,
    auto_merge = bool("merge.auto_merge", current_merge.auto_merge ~= nil and current_merge.auto_merge or current.auto_merge, false),
    auto_deploy = bool("deploy.auto_deploy", current_deploy.auto_deploy ~= nil and current_deploy.auto_deploy or current.auto_deploy, false),
    deploy_confirm = deploy_confirm,
    roles = {},
    review = {
      engine = pick(flat, current_review, "review.engine", "model"),
      no_mistakes_bin = pick(flat, current_review, "review.no_mistakes_bin", "no-mistakes"),
      max_rounds = as_number(pick(flat, current_review, "review.max_rounds", 3), 3),
      require_checks_green = pick(flat, current_review, "review.require_checks_green", true) == true
        or pick(flat, current_review, "review.require_checks_green", true) == "true",
      protected_paths = pick(flat, current_review, "review.protected_paths",
        { "review-rules.md", "AGENTS.md", ".metronome/", "deploy.md" }),
    },
    merge = {
      method = pick(flat, current_merge, "merge.method", "squash"),
      auto_rebase = pick(flat, current_merge, "merge.auto_rebase", true) == true
        or pick(flat, current_merge, "merge.auto_rebase", true) == "true",
    },
    deploy = {
      plan_file = pick(flat, current_deploy, "deploy.plan_file", "deploy.md"),
    },
    quality = {
      variants = as_number(pick(flat, current_quality, "quality.variants", 1), 1),
      stall_minutes = as_number(pick(flat, current_quality, "quality.stall_minutes", 20), 20),
    },
    limits = {
      max_task_cost_usd = as_number(pick(flat, current_limits, "limits.max_task_cost_usd", 5.0), 5.0),
      timeout_minutes = as_number(pick(flat, current_limits, "limits.timeout_minutes", 30), 30),
      max_questions_per_round = as_number(pick(flat, current_limits, "limits.max_questions_per_round", 15), 15),
    },
  }
  for _, role in ipairs(ROLE_ORDER) do
    local default = DEFAULT_ROLES[role]
    local role_current = current_roles[role] or {}
    normalized.roles[role] = {
      model = value(role .. "_model") or value("roles." .. role .. ".model")
        or role_current.model or default.model,
      thinking = value(role .. "_thinking") or value("roles." .. role .. ".thinking")
        or role_current.thinking or default.thinking,
    }
  end
  return normalized
end

local function render_config(answers)
  local review = type(answers.review) == "table" and answers.review or {}
  local merge = type(answers.merge) == "table" and answers.merge or {}
  local deploy = type(answers.deploy) == "table" and answers.deploy or {}
  local quality = type(answers.quality) == "table" and answers.quality or {}
  local limits = type(answers.limits) == "table" and answers.limits or {}
  local function s(v) return tostring(v) end
  local function b(v) return v == true and "true" or "false" end
  local lines = {
    "[project]",
    "repo = " .. toml_string(answers.repo),
    "base_ref = " .. toml_string(answers.base_ref),
    "max_parallel = " .. s(answers.max_parallel),
    "max_parallel_qualifiers = " .. s(answers.max_parallel_qualifiers),
    "",
    "[git]",
    'branch_prefix = "metronome/"',
    'commit_style = "conventional"',
    "pr_draft = false",
    "",
  }
  for _, role in ipairs(ROLE_ORDER) do
    lines[#lines + 1] = "[roles." .. role .. "]"
    lines[#lines + 1] = "model = " .. toml_string(answers.roles[role].model)
    lines[#lines + 1] = "thinking = " .. toml_string(answers.roles[role].thinking)
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "[checks]"
  lines[#lines + 1] = "default = " .. toml_array(answers.checks)
  lines[#lines + 1] = "re_run_after_merge = true"
  lines[#lines + 1] = "timeout_secs = 600"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[review]"
  lines[#lines + 1] = "engine = " .. toml_string(review.engine or "model")
  lines[#lines + 1] = "no_mistakes_bin = " .. toml_string(review.no_mistakes_bin or "no-mistakes")
  lines[#lines + 1] = "max_rounds = " .. s(review.max_rounds or 3)
  lines[#lines + 1] = "require_checks_green = " .. b(review.require_checks_green ~= false)
  lines[#lines + 1] = "protected_paths = " .. toml_array(review.protected_paths
    or { "review-rules.md", "AGENTS.md", ".metronome/", "deploy.md" })
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[merge]"
  lines[#lines + 1] = "auto_merge = " .. b(answers.auto_merge)
  lines[#lines + 1] = "method = " .. toml_string(merge.method or "squash")
  lines[#lines + 1] = "auto_rebase = " .. b(merge.auto_rebase ~= false)
  lines[#lines + 1] = "max_conflict_retries = " .. s(merge.max_conflict_retries or 2)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[deploy]"
  lines[#lines + 1] = "auto_deploy = " .. b(answers.auto_deploy)
  lines[#lines + 1] = "confirm = " .. b(answers.deploy_confirm)
  lines[#lines + 1] = "plan_file = " .. toml_string(deploy.plan_file or "deploy.md")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[quality]"
  lines[#lines + 1] = "variants = " .. s(quality.variants or 1)
  lines[#lines + 1] = "stall_minutes = " .. s(quality.stall_minutes or 20)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[limits]"
  lines[#lines + 1] = "max_task_cost_usd = " .. s(limits.max_task_cost_usd or 5.0)
  lines[#lines + 1] = "timeout_minutes = " .. s(limits.timeout_minutes or 30)
  lines[#lines + 1] = "max_questions_per_round = " .. s(limits.max_questions_per_round or 15)
  return table.concat(lines, "\n") .. "\n"
end

M.DEFAULT_ROLES = DEFAULT_ROLES
M.ROLE_ORDER = ROLE_ORDER
M.init_questions = init_questions
M.normalize_init = normalize_init
M.render_config = render_config

local DEFAULT_PROMPTS = {
  _global = "# Metronome global rules\n\nYou are one role in an autonomous delivery pipeline. Follow the task sheet, keep the diff inside the declared files, and answer in the requested format.\n",
  qualifier = "# Role — chef de pupitre (qualifier)\n\nTurn the intention into task sheets and blocking questions.\n",
  analyst = "# Role — harmoniste (analyst)\n\nCheck the task sheets against each other before any code is written.\n",
  implementer = "# Role — instrumentiste (implementer)\n\nMake the change on the task branch and leave the worktree committable.\n",
  reviewer = "# Role — critique (reviewer)\n\nReview the exact commit SHA and return findings.\n",
  deployer = "# Role — timbalier (deployer)\n\nRun the deployment plan from deploy.md.\n",
}

local function write_prompts(dir)
  fs.mkdir(dir, { parents = true })
  for name, text in pairs(DEFAULT_PROMPTS) do
    local path = fs.joinpath(dir, name .. ".md")
    if not fs.read(path) then
      fs.write(path, text)
    end
  end
end

-- Constructor ---------------------------------------------------------------

-- `deps` carries the pipeline modules. They are injected so the runtime can be
-- exercised without a model, a repository or a live session.
function M.new(deps)
  deps = type(deps) == "table" and deps or {}
  local required = {
    "config", "state", "roles", "runner", "git", "qualify", "questions",
    "analyze", "implement", "checks", "converge", "review", "merge",
    "deploy", "calibrate", "pipeline", "fence", "mode",
  }
  for _, name in ipairs(required) do
    if type(deps[name]) ~= "table" then
      return nil, "runtime is missing module: " .. name
    end
  end

  local runtime = {
    deps = deps,
    running = false,
    panel = nil,
  }

  local function p(opts)
    if type(deps.paths) == "function" then
      local injected = deps.paths(opts)
      if injected then
        return injected
      end
    end
    return M.paths(opts)
  end

  local function load_config(opts)
    local paths = p(opts)
    local cfg, errors = deps.config.load(paths.config)
    if not cfg then
      return nil, table.concat(errors or { "cannot load config" }, "; ")
    end
    -- The project is the repo the config names, never the directory the plugin
    -- happens to be loaded in. Branches, worktrees and pull requests belong to
    -- that repo: a Metronome session started in the plugin's own checkout must
    -- still work on the shop.
    local repo = cfg.project and cfg.project.repo
    if type(repo) == "string" and repo ~= "" and repo ~= paths.repo then
      paths = M.paths({ repo = repo, root = paths.root })
    end
    -- A bound project needs its role prompts on disk. `init` writes them, but a
    -- state directory that only carries a config (a copied project, a partial
    -- restore) would otherwise fail mid-run with a raw "missing prompt" error.
    -- The write is idempotent and never overwrites a prompt the user edited.
    if type(paths.prompts) == "string" and paths.prompts ~= "" then
      write_prompts(paths.prompts)
    end
    return cfg, nil, paths
  end

  -- Paths whose `repo` is the project's, for the calls that touch git. Falls
  -- back to the working directory when the project is not bound yet.
  local function project_paths(opts)
    local cfg, _, paths = load_config(opts)
    if paths then
      return paths, cfg
    end
    return p(opts), nil
  end

  -- The config already on disk, shaped like the init answers. An update keeps
  -- every value the caller does not override instead of resetting it.
  local function current_answers(paths)
    if not fs.read(paths.config) then
      return nil
    end
    local cfg, errors = deps.config.load(paths.config)
    if not cfg then
      return nil, table.concat(errors or { "invalid config" }, "; ")
    end
    return {
      repo = cfg.project and cfg.project.repo,
      base_ref = cfg.project and cfg.project.base_ref,
      max_parallel = cfg.project and cfg.project.max_parallel,
      checks = cfg.checks and cfg.checks.default,
      auto_merge = cfg.merge and cfg.merge.auto_merge,
      auto_deploy = cfg.deploy and cfg.deploy.auto_deploy,
      deploy_confirm = cfg.deploy and cfg.deploy.confirm,
      roles = cfg.roles,
      -- Keep the sections an update does not name, so changing a model never
      -- resets the review, merge, deploy, quality or limits policy.
      review = cfg.review,
      merge = cfg.merge,
      deploy = cfg.deploy,
      quality = cfg.quality,
      limits = cfg.limits,
    }
  end

  -- The preflight gate. `init` and `config` run it on the prospective answers
  -- before anything is written: a project bound with a missing checker, no git
  -- identity or no origin branch would only fail on the first task, far from
  -- the command that created it. Returns nil when the environment is green, or
  -- the refusal table (with the preflight verdict attached) to return as is.
  local function preflight_refusal(answers)
    local mod = deps.preflight
    if type(mod) ~= "table" or type(mod.run) ~= "function" then
      return {
        ok = false,
        error = "preflight is not wired: refusing to bind the project without an environment check",
      }
    end
    local result = mod.run({
      repo = answers.repo,
      base_ref = answers.base_ref,
      checks = answers.checks,
    })
    if type(result) ~= "table" then
      return { ok = false, error = "preflight returned no verdict: refusing to bind the project" }
    end
    if result.ok == true then
      return nil
    end
    local text = type(mod.format) == "function" and mod.format(result) or nil
    if type(text) ~= "string" or text == "" then
      text = result.message
    end
    if type(text) ~= "string" or text == "" then
      text = "preflight refused the binding"
    end
    return { ok = false, error = text, preflight = result }
  end

  local function session_opts(config, role, paths)
    return deps.roles.session_opts(config, role, paths.prompts, nil)
  end

  -- Scripted runner ---------------------------------------------------------

  local function load_script(paths)
    local path = fs.joinpath(paths.root, "e2e-script.json")
    if not fs.read(path) then
      return nil
    end
    local text, err = fs.read(path)
    if not text then
      return nil, "cannot read script " .. path .. ": " .. tostring(err)
    end
    local ok, decoded = pcall(json.decode, text)
    if not ok or type(decoded) ~= "table" then
      return nil, "cannot decode script " .. path
    end
    return decoded
  end

  local function scripted_runner(script, paths)
    local by_title = {}
    for _, task in ipairs(script.tasks or {}) do
      by_title[task.title] = task
    end

    return function(request)
      local role = request.role
      if role == "qualifier" then
        return { ok = true, text = json.encode({ tasks = script.tasks or {} }) }
      end
      if role == "analyst" then
        return { ok = true, text = '{"findings":[]}' }
      end
      if role == "implementer" then
        local loaded = deps.state.load(paths.root)
        local task = loaded and loaded.tasks and loaded.tasks[request.task_id]
        local spec = task and by_title[task.title] or nil
        local worktree = deps.implement.worktree_path(paths.root, request.task_id, {})
        for file, content in pairs((spec and spec.write) or {}) do
          local target = fs.joinpath(worktree, file)
          local dir = target:match("^(.*)/[^/]+$")
          if dir then
            fs.mkdir(dir, { parents = true })
          end
          fs.write(target, content)
        end
        return { ok = true, text = "wrote the declared files" }
      end
      if role == "reviewer" then
        return { ok = true, text = '{"findings":[]}' }
      end
      if role == "deployer" then
        return { ok = true, text = "deployed" }
      end
      return { ok = true, text = "noop" }
    end
  end

  -- Real runner -------------------------------------------------------------

  local function real_runner(opts)
    return function(request)
      local enter = deps.mode and deps.mode.enter_subagent
      local leave = deps.mode and deps.mode.leave_subagent
      if type(enter) == "function" then
        enter()
      end
      local ok, result = pcall(deps.runner.run, {
        role = request.role,
        task_id = request.task_id,
        phase = request.phase,
        prompt = request.prompt,
        system = request.system,
        model_spec = request.model_spec,
        thinking = request.thinking,
        tools = request.tools,
        state_root = opts.state_root or p(opts).runs,
        -- The request carries the ctx of the task being run. The runner was
        -- built once in `prepare`, before `background_ctx` turned the tool ctx
        -- into a `{ session = sid }` table, so reading only the captured
        -- `opts.ctx` would drop the session id and cancel the role session.
        ctx = request.ctx or opts.ctx,
        max_attempts = opts.max_attempts or 3,
        deadline_secs = opts.deadline_secs,
      })
      if type(leave) == "function" then
        leave()
      end
      if not ok then
        error(result)
      end
      return result
    end
  end

  -- One task through the whole pipeline -------------------------------------

  -- Two tasks merging at once would rebase onto the same base and race on the
  -- server. A merge is short (a rebase and a squash merge), so one permit is
  -- enough: implementation, checks and review still run in parallel.
  local merge_gate = (type(deps.join) == "function"
    and maki.async and type(maki.async.semaphore) == "function")
    and maki.async.semaphore(1) or nil

  local function with_merge_gate(fn)
    if not merge_gate then
      return fn()
    end
    local permit = merge_gate:acquire()
    local ok, result = pcall(fn)
    permit:release()
    if not ok then
      return nil, result
    end
    return result
  end

  -- Qualifier concurrency. Every submit spawns its own background job, so
  -- without a gate N submits would open N qualifier sessions at once. The cap
  -- is `project.max_parallel_qualifiers`; the semaphore is cached per limit so
  -- a config change never leaks permits.
  local qualify_gates = {}
  local function qualifier_gate(limit)
    if not (deps.async == true and maki.async and type(maki.async.semaphore) == "function") then
      return nil
    end
    limit = tonumber(limit) or 4
    if limit < 1 then
      limit = 1
    end
    if not qualify_gates[limit] then
      qualify_gates[limit] = maki.async.semaphore(limit)
    end
    return qualify_gates[limit]
  end

  -- Id allocation is a read-modify-write: `next_id` reads the max, `apply`
  -- creates the tasks. Two qualifiers finishing together would compute the
  -- same ids and one would fail on "task already exists". One permit
  -- serialises that short section; the model calls stay parallel.
  local id_gate = (deps.async == true and maki.async and type(maki.async.semaphore) == "function")
    and maki.async.semaphore(1) or nil

  local function with_id_gate(fn)
    if not id_gate then
      return fn()
    end
    local permit = id_gate:acquire()
    local ok, first, second = pcall(fn)
    permit:release()
    if not ok then
      return nil, first
    end
    return first, second
  end

  -- A qualification run needs its own artifact directory. `runs/<key>/...` is
  -- keyed by this id, so two concurrent qualifiers must not share "qualify".
  local qualify_seq = 0
  local function next_qualify_key()
    qualify_seq = qualify_seq + 1
    return string.format("qualify-%d-%d", os.time(), qualify_seq)
  end

  -- How many times a task may be redone on a fresh base. A base that keeps
  -- moving is a real situation (several PRs merging), so the bound is a count,
  -- not a lifetime flag: a task that repaired one conflict can still repair
  -- the next one. The bound is the project's (`merge.max_conflict_retries`,
  -- default 2), never a constant here: a project that wants a tighter or a
  -- looser repair budget must be able to say so.
  local DEFAULT_CONFLICT_RETRIES = 2

  local function conflict_retry_bound(cfg)
    local configured = cfg and cfg.merge and tonumber(cfg.merge.max_conflict_retries)
    if configured ~= nil then
      return configured
    end
    return DEFAULT_CONFLICT_RETRIES
  end

  local function conflict_repairs(task)
    local n = tonumber(task and task.conflict_retries)
    if n then
      return n
    end
    return (task and task.conflict_retried) and 1 or 0
  end

  -- The facts a conflict carries, in one shape. The journal note the runtime
  -- writes, the prompt the implementer reads and the escalation the human
  -- reads are all built from this table, so they cannot disagree about the
  -- files, the hunk or the base.
  local function conflict_file_list(result)
    local files = result and result.conflict_file_list
    if type(files) == "table" and #files > 0 then
      return files
    end
    local raw = result and (result.conflict_files or result.conflict) or nil
    if type(raw) == "table" then
      return raw
    end
    local out = {}
    if type(raw) == "string" then
      for piece in raw:gmatch("[^,]+") do
        local name = trim(piece)
        if name ~= "" then
          out[#out + 1] = name
        end
      end
    end
    return out
  end

  -- Two shapes reach this function: the `merge.run` result (`conflict_hunks`,
  -- `conflict_commit`, `rebase_command`) and the `merge.rebase` diagnostic
  -- (`hunks`, `commit`, `command`). Both describe the same conflict, so the
  -- aliases are normalised here rather than at every call site: a rebase that
  -- conflicts during implement must carry the same hunks and faulty commit as
  -- one that conflicts during merge, or the note and the implementer prompt
  -- would silently lose them.
  local function conflict_details(result, base)
    result = type(result) == "table" and result or {}
    local upstream = is_non_empty(result.upstream) and result.upstream
      or ("origin/" .. tostring(is_non_empty(base) and base or "main"))
    local hunks = type(result.conflict_hunks) == "table" and result.conflict_hunks
      or (type(result.hunks) == "table" and result.hunks or nil)
    local commit = is_non_empty(result.conflict_commit) and result.conflict_commit
      or (is_non_empty(result.commit) and result.commit or nil)
    local command = is_non_empty(result.rebase_command) and result.rebase_command
      or (is_non_empty(result.command) and result.command or nil)
    return {
      files = conflict_file_list(result),
      hunks = hunks,
      base = is_non_empty(result.base) and result.base or (is_non_empty(base) and base or nil),
      base_sha = is_non_empty(result.base_sha) and result.base_sha or nil,
      upstream = upstream,
      commit = commit,
      command = command or ("git rebase " .. upstream),
    }
  end

  -- The facts a note states, without claiming the task is dead: the conflict is
  -- being repaired, and the implementer will read the same lines.
  local function conflict_note(details)
    local files = #details.files > 0 and table.concat(details.files, ", ") or "unknown"
    local parts = {
      string.format("rebase conflict with %s will be redone on the fresh base",
        details.upstream or "origin/main"),
      "files: " .. files,
      "command: `" .. details.command .. "`",
    }
    if details.base_sha then
      parts[#parts + 1] = "base sha: " .. details.base_sha
    end
    if details.commit then
      parts[#parts + 1] = "commit: " .. details.commit
    end
    return table.concat(parts, "; ")
  end

  -- Beyond the bound the reader must get the means to act: the files, the base
  -- (with its SHA), the exact command and the commit git could not replay.
  local function conflict_escalation(details)
    local files = #details.files > 0 and table.concat(details.files, ", ") or "unknown"
    local parts = {
      string.format("rebase conflict on %s cannot be repaired automatically",
        details.upstream or "origin/main"),
      "files: " .. files,
      "command: `" .. details.command .. "`",
    }
    if details.base_sha then
      parts[#parts + 1] = "base sha: " .. details.base_sha
    end
    if details.commit then
      parts[#parts + 1] = "commit: " .. details.commit
    end
    return table.concat(parts, "; ")
  end

  -- Journal the conflict as a `note` event: files, hunks, base and the faulty
  -- commit, quoted as evidence. Never raises: a journal that cannot take the
  -- note must not stop the repair.
  local function journal_conflict(state, root_path, task_id, details, summary)
    if type(state) ~= "table" or type(state.append) ~= "function" then
      return
    end
    local lines = { summary or conflict_note(details) }
    for _, hunk in ipairs(details.hunks or {}) do
      if type(hunk) == "table" then
        lines[#lines + 1] = string.format("--- %s:%s\n%s",
          tostring(hunk.file or "unknown"), tostring(hunk.start or "?"), tostring(hunk.text or ""))
      end
    end
    pcall(state.append, root_path, {
      kind = "note",
      task_id = task_id,
      text = table.concat(lines, "\n"),
    })
  end

  -- An epic task owns the single PR from the epic branch to the project base.
  --
  -- It has no implementation, no checks and no review of its own: the subtasks
  -- already ran those on the epic branch, and the scheduler only starts the
  -- epic once every one of them is `merged`. So this path is: push the branch
  -- (it exists from qualification), open the PR, merge it, re-run the declared
  -- checks on the merged base, and only then deploy. Implement, converge and
  -- review are never called.
  local function run_epic(opts, task_id, paths, cfg, runner, session)
    local state = deps.state
    local loaded = state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[task_id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(task_id) }
    end
    local base = M.task_base(task, cfg)
    local branch = is_non_empty(task.branch) and task.branch or nil
    if not branch then
      return { ok = false, error = "epic task " .. task_id .. " has no branch" }
    end

    -- A resumed epic whose PR is already merged only has the post-merge
    -- verification and the deploy left: re-opening or re-merging the PR would
    -- be refused. This is the path a deploy that failed for a missing checks
    -- report takes on retry.
    local already_merged = type(task.pr) == "table" and task.pr.state == "merged"
    local pr = task.pr
    local merged = nil

    if not already_merged then
      local moved, merr = state.transition(paths.root, task_id, "running", { phase = "merge" })
      if not moved then
        return { ok = false, error = merr or "cannot start the epic" }
      end

      -- The epic branch lives on the remote: qualification pushed it, and
      -- every subtask merge landed there through GitHub. The local ref is
      -- therefore behind after a squash merge, and pushing it as-is is refused
      -- as non-fast-forward. Fetch, move the local ref to the remote tip, and
      -- push only when the remote does not have the branch yet.
      if deps.git and type(deps.git.fetch) == "function" then
        pcall(deps.git.fetch, paths.repo, "origin")
      end
      local remote_ref = "origin/" .. branch
      local remote_sha = type(deps.git.rev_parse) == "function"
        and deps.git.rev_parse(paths.repo, remote_ref) or nil
      if remote_sha then
        if type(deps.git.branch_reset) == "function" then
          local aligned, aerr = deps.git.branch_reset(paths.repo, branch, remote_ref)
          if not aligned then
            return { ok = false, error = "cannot align the epic branch: " .. tostring(aerr) }
          end
        end
      elseif type(deps.git.push_branch) == "function" then
        local pushed, perr = deps.git.push_branch(paths.repo, branch, { remote = "origin" })
        if not pushed then
          return { ok = false, error = "cannot push the epic branch: " .. tostring(perr) }
        end
      end

      local pr_err
      pr, pr_err = deps.git.pr_open(state, paths.root, task_id, {
        repo = paths.repo,
        worktree = paths.repo,
        base = base,
        head = branch,
        title = task.title,
        body = "Metronome epic " .. task_id,
        gh = "gh",
        attach_only = true,
      })
      if not pr then
        -- The gh reason (cause, command, detail) is the diagnosis: a generic
        -- "cannot open" sentence sends the reader to the transcript for
        -- nothing.
        return { ok = false, error = "cannot open the epic pull request: "
          .. tostring(pr_err or "unknown gh error") }
      end

      local opened, oerr = state.transition(paths.root, task_id, "pr_open", { phase = "merge" })
      if not opened then
        return { ok = false, error = oerr or "cannot mark the epic pr_open" }
      end

      -- `auto_merge` off means a human merges the epic PR; the pipeline stops
      -- here with the PR open, exactly like a normal task.
      if not (cfg.merge and cfg.merge.auto_merge) then
        return { ok = true, task_id = task_id, pr = pr, pr_open = true, epic = true }
      end

      -- The epic branch is never checked out, so the merge needs a worktree
      -- that holds it: rebasing from the project's own checkout would move
      -- whatever branch happens to be checked out there instead. Without a
      -- worktree the rebase is skipped and GitHub judges the merge.
      local epic_wt = fs.joinpath(paths.worktrees, task_id)
      local worktree = paths.repo
      local auto_rebase = cfg.merge.auto_rebase
      if type(deps.git.worktree_add) == "function" then
        local added = deps.git.worktree_add(paths.repo, epic_wt, branch, nil, { existing = true })
        if added then
          worktree = epic_wt
        else
          auto_rebase = false
        end
      else
        auto_rebase = false
      end

      local merge_err
      merged, merge_err = with_merge_gate(function()
        return deps.merge.run({
          task = task_id,
          -- The PR this run just read back from gh, never a PR supposed from
          -- the state loaded at the start of the run.
          pr = type(pr) == "table" and (pr.number or pr.url) or pr,
          worktree = worktree,
          repo = paths.repo,
          git = deps.git,
          state = state,
          root = paths.root,
          remote = "origin",
          base = base,
          checks = deps.checks,
          gh = "gh",
          method = cfg.merge.method,
          auto_rebase = auto_rebase,
          verify = cfg.checks.re_run_after_merge ~= false,
          commands = task.checks or cfg.checks.default,
        })
      end)
      if not merged then
        return { ok = false, error = tostring(merge_err or "epic merge failed") }
      end
      if not merged.ok then
        -- A red base or a refused merge is a real failure: there is no
        -- implementer to bounce back to, the subtasks are already merged.
        if worktree == epic_wt and type(deps.git.worktree_remove) == "function" then
          pcall(deps.git.worktree_remove, paths.repo, epic_wt, { force = true })
        end
        return merged
      end
    end

    -- The deploy guard reads `checks/<task>.json`, which the normal flow
    -- writes during its verify phase. An epic has no verify phase, so the
    -- post-merge result is written here; a resumed epic re-runs the checks on
    -- the merged base to produce it.
    local checks_result = merged and merged.checks or nil
    if already_merged then
      -- A retry walks the task back to `running` before dispatching it, but
      -- the deploy guard only deploys from `merged`. Walk it forward again
      -- through the epic's legal path; the PR is already merged, so no work
      -- is redone.
      local current = state.load(paths.root)
      local status = current and current.tasks and current.tasks[task_id]
        and current.tasks[task_id].status or nil
      if status ~= "merged" then
        for _, step in ipairs({ "pr_open", "merging", "merged" }) do
          local ok, serr = state.transition(paths.root, task_id, step, { phase = "merge" })
          if not ok then
            return { ok = false, error = serr or ("cannot restore the epic to merged") }
          end
        end
      end
      if type(deps.merge.verify_after_merge) ~= "function" then
        return { ok = false, error = "cannot verify the merged base" }
      end
      local cres, cerr = deps.merge.verify_after_merge({
        git = deps.git,
        checks = deps.checks,
        repo = paths.repo,
        root = paths.root,
        task_id = task_id,
        base = base,
        remote = "origin",
        commands = task.checks or cfg.checks.default,
      })
      if not cres then
        return { ok = false, error = "cannot verify the merged base: " .. tostring(cerr) }
      end
      if cres.ok == false then
        return { ok = false, error = "post-merge checks failed", checks = cres }
      end
      checks_result = cres
    end
    if checks_result and type(deps.checks.write_report) == "function" then
      deps.checks.write_report(paths.root, task_id, checks_result)
    end

    if cfg.deploy and cfg.deploy.auto_deploy then
      local deployed = deps.deploy.run({
        task = task_id,
        root = paths.root,
        state = state,
        repo = paths.repo,
        plan_path = fs.joinpath(paths.repo, cfg.deploy.plan_file or "deploy.md"),
        runner = runner,
        script = true,
        confirm = false,
        confirmed = true,
        session_opts = session.deployer,
        state_root = paths.runs,
        ctx = opts.ctx,
        checks = deps.checks,
      })
      if not deployed.ok then
        return {
          ok = false,
          error = "deploy failed: " .. tostring(deployed.error),
          task_id = task_id,
          pr = pr,
          merged = merged,
          deployed = deployed,
          epic = true,
        }
      end
      return { ok = true, task_id = task_id, pr = pr, merged = merged, deployed = deployed, epic = true }
    end

    return { ok = true, task_id = task_id, pr = pr, merged = merged, epic = true }
  end

  -- Typed-failure helpers, defined below the drain they are shared with.
  -- `run_task` already diagnoses the failures it can name (a fetch that never
  -- started), so the locals have to exist before it is defined.
  local recover_module
  local recover_opts
  local describe_failure
  local typed_failure
  local fetch_diagnosis
  local later
  local retry_attempts

  local function run_task(opts, task_id, paths, cfg, runner, session)
    local state = deps.state
    local loaded = state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[task_id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(task_id) }
    end

    -- One pilot per task. Another driver — a second dispatch, a late resume, a
    -- review round that outlived its turn — may have moved the task on while
    -- this one was starting. Re-read the journal here, at the entry point, and
    -- abandon quietly: running both would redo the same worktree twice and race
    -- the branch. Nothing was attempted, so the result is not a failure.
    -- An epic is exempt: its dispatch is a merge-and-deploy driver over the same
    -- PR, and a resumed epic legitimately restarts from its merged state.
    local entry_status = tostring(task.status or "unknown")
    if task.kind ~= "epic" and OWNED_STATUSES[entry_status] then
      local reason = "task already owned: status=" .. entry_status
      log(paths, "task " .. tostring(task_id) .. " not dispatched: " .. reason)
      return {
        ok = true,
        skipped = true,
        task_id = task_id,
        status = entry_status,
        reason = reason,
      }
    end

    -- An epic is a different shape of work: one PR, no implementation. The
    -- dispatch lives here so every caller (scheduler, retry, resume) gets the
    -- same behaviour.
    if task.kind == "epic" then
      return run_epic(opts, task_id, paths, cfg, runner, session)
    end

    -- Every base-dependent step below reads this, not cfg.project.base_ref: a
    -- subtask of an epic is cut from, reviewed against, merged into and
    -- diffed against the epic branch.
    local base = M.task_base(task, cfg)
    -- A subtask whose base is not the project base merges into the epic branch
    -- and stops at `merged`: it never deploys, the epic does.
    local epic_subtask = is_non_empty(task.base_ref) and task.base_ref ~= cfg.project.base_ref

    -- One implementation turn plus everything that must hold before a review:
    -- the rebase onto the fresh base, the declared checks and the convergence
    -- diff. A fix round runs exactly the same sequence, with the reviewer's
    -- findings as the prompt's work list, so a review never ends the task
    -- while rounds remain.
    -- Repairs are counted in the chain as well as in the journal: the base can
    -- move more than once while the task is redone, and `task` is the table
    -- loaded at the start of the run, so its counter never moves on its own.
    local repairs = conflict_repairs(task)
    local repair_bound = conflict_retry_bound(cfg)

    -- `conflict` is the facts of the conflict the previous turn left, if any:
    -- the implementer receives the files and hunks it must resolve, as data.
    local function implement_and_verify(feedback, conflict)
      local impl = deps.implement.run({
        task = task,
        repo = paths.repo,
        state = state,
        root = paths.root,
        git = deps.git,
        worktree_root = paths.worktrees,
        tasks_dir = paths.tasks,
        remote = "origin",
        base_ref = base,
        runner = runner,
        session_opts = session.implementer,
        state_root = paths.runs,
        ctx = opts.ctx,
        max_attempts = 1,
        deadline_secs = opts.deadline_secs,
        feedback = feedback,
        conflict = conflict,
      })
      if not impl.ok then
        return nil, impl
      end
      local worktree = impl.ctx.worktree

      -- The base can move while the implementer works (another task merges).
      -- Rebase onto the fresh origin/base before the checks and the converge
      -- diff, so the diff is measured against the base the PR will merge into.
      -- The rebase fetches, so a fix merged into master or into the epic branch
      -- is seen by a task already in flight. A conflict sends the task back to
      -- implementation on the new base.
      local diff_base = "origin/" .. base
      if deps.merge and type(deps.merge.rebase) == "function" then
        local rebased, rebase_err, rebase_diag = deps.merge.rebase({
          repo = paths.repo,
          worktree = worktree,
          remote = "origin",
          base = base,
          git = deps.git,
        })
        if not rebased then
          if type(rebase_diag) == "table" and rebase_diag.conflict then
            -- The base moved under the branch and the same lines changed.
            -- That is repairable without a human: move the branch back to the
            -- fresh base and redo the work there, with the conflict facts in
            -- the prompt. The bound is the project's; beyond it the conflict is
            -- a real failure and goes to the user.
            local details = conflict_details(rebase_diag, base)
            if repairs < repair_bound
              and type(deps.git.reset_hard) == "function" then
              -- `reset_hard` takes a sha, never a ref: resolve the fresh base
              -- first, or the reset is refused and the repair silently does
              -- nothing.
              local base_sha = type(deps.git.rev_parse) == "function"
                and deps.git.rev_parse(worktree, "origin/" .. base) or nil
              local reset = base_sha and deps.git.reset_hard(worktree, base_sha) or nil
              if reset then
                if base_sha then
                  details.base_sha = details.base_sha or base_sha
                end
                log(paths, "task " .. task_id .. " conflicted with the fresh base on "
                  .. tostring(rebase_diag.conflict) .. "; redoing it on the fresh base")
                repairs = repairs + 1
                -- The task is already running: the repair continues the turn,
                -- it is not a failure. Persist the counter and the phase so a
                -- reload keeps both.
                pcall(state.set_fields, paths.root, task_id, {
                  conflict_retried = true,
                  conflict_retries = repairs,
                  phase = "implement",
                })
                journal_conflict(state, paths.root, task_id, details,
                  "rebase conflict (repairable): " .. conflict_note(details))
                -- The reset rewrote the branch: lease the push so the PR shows
                -- the commit the next turn will build on.
                if type(deps.git.push) == "function" then
                  deps.git.push(worktree, impl.ctx.branch, { remote = "origin", force = true })
                end
                return implement_and_verify(feedback, details)
              end
            end
            return nil, {
              ok = false,
              conflict = true,
              phase = "implement",
              error = conflict_escalation(details),
            }
          end
          -- The rebase never started: it is the fetch that failed. A remote or
          -- credential problem is transient whatever git printed, so the task
          -- is retried instead of being condemned by a generic string.
          return nil, {
            ok = false,
            phase = "verify",
            error = "cannot refresh the base before the checks: " .. tostring(rebase_err),
            diagnosis = fetch_diagnosis(rebase_err),
          }
        end
        -- The rebase just fetched the remote and reports the exact ref it
        -- rebased onto: that fresh base is what the convergence diff must be
        -- read against, not the ref resolved before the fetch.
        if type(rebased) == "table" and is_non_empty(rebased.base) then
          diff_base = rebased.base
        end
        -- A rebase rewrites the branch, so the remote still holds the old
        -- commits: push the rewritten branch now, or the PR and the SHA the
        -- reviewer reads would point at two different commits. The push leases
        -- the branch, so a concurrent push is still refused rather than lost.
        if type(deps.git.push) == "function" then
          local pushed, push_err = deps.git.push(worktree, impl.ctx.branch, {
            remote = "origin",
            force = true,
          })
          if not pushed then
            return nil, {
              ok = false,
              phase = "verify",
              error = "push after rebase failed: " .. tostring(push_err),
              diagnosis = fetch_diagnosis(push_err),
            }
          end
        end
      end

      local checks = task.checks or cfg.checks.default
      local verified = deps.checks.verify({
        checks = checks,
        worktree = worktree,
        timeout_ms = (cfg.checks.timeout_secs or 600) * 1000,
        rollback = false,
        -- Scope the checks' XDG_STATE_HOME to this task: parallel tasks must
        -- not share the state their checks write to.
        root = paths.root,
        task_id = task_id,
      })
      if not verified or not verified.ok then
        return nil, {
          ok = false,
          phase = "verify",
          error = (verified and verified.error) or "checks failed",
          impl = impl,
        }
      end
      deps.checks.write_report(paths.root, task_id, verified, {})

      -- The worktree is cut from origin/<base>, so the diff must be read
      -- against the same ref, refreshed by the rebase above. The local base
      -- branch is not advanced by a GitHub merge.
      local sheet = deps.implement.read_sheet(paths.root, task, { tasks_dir = paths.tasks })
      local converged = deps.converge.run({
        task = task,
        worktree = worktree,
        base = diff_base,
        git = deps.git,
        root = paths.root,
        tasks_dir = paths.tasks,
        sheet = sheet,
        runner = runner,
        session_opts = session.implementer,
        state_root = paths.runs,
        ctx = opts.ctx,
      })
      if not converged.ok then
        return nil, converged
      end
      -- The review and the merge read their diff against the same fresh base.
      impl.diff_base = diff_base
      return impl
    end

    -- A retry after a review failure already has the findings on the task:
    -- hand them to the implementer instead of asking it to guess again.
    local initial_feedback = nil
    if type(task.review) == "table" and type(task.review.findings) == "table"
      and #task.review.findings > 0 then
      initial_feedback = task.review.findings
    end

    -- A merge conflict is repaired here, not by relaunching the merge: a
    -- relaunch replays the same commit on the same base and hits the same
    -- conflict, which is exactly the loop this replaces. The repair is a real
    -- implementation cycle: the task goes back to `running`/`implement` with
    -- the conflict facts, the implementer resolves and pushes, and the
    -- pipeline (implement -> verify -> review -> merge) runs again. It is
    -- bounded by `merge.max_conflict_retries` and counted in the persisted
    -- `conflict_retries`, so a reload cannot restart the budget.
    local pr
    local approved_sha
    local merged
    local conflict = nil

    while true do
      local impl, impl_err = implement_and_verify(initial_feedback, conflict)
      if not impl then
        return impl_err
      end
      -- The findings belonged to the first attempt; a repair pass carries the
      -- conflict facts instead.
      initial_feedback = nil

      local worktree = impl.ctx.worktree
      local checks = task.checks or cfg.checks.default
      local diff_base = impl.diff_base or ("origin/" .. base)

      state.transition(paths.root, task_id, "verifying", { phase = "verify" })
      state.transition(paths.root, task_id, "reviewing", { phase = "review" })

      -- Two review engines. `model` opens the PR first and runs the bounded
      -- reviewer loop. `no-mistakes` lets the local gate clean, push and open
      -- the PR itself, then merges it: no review/implement loop at all.
      local engine = (cfg.review and cfg.review.engine) or "model"
      local reviewed
      approved_sha = impl.sha

      if engine == "no-mistakes" then
        local nm = deps.no_mistakes
        if type(nm) ~= "table" or type(nm.run) ~= "function" then
          return { ok = false, error = "review.engine is no-mistakes but the module is not loaded" }
        end
        local timeout = (cfg.limits and cfg.limits.timeout_minutes and cfg.limits.timeout_minutes * 60000)
          or 1800000
        -- A cancelled gate run leaves its fix commits in the private
        -- `no-mistakes` mirror while the live branch is reset to the pre-run
        -- head. The next run refuses to reconcile that gap ("at-risk commits
        -- absent from live head"), so bring the live branch up to the mirror
        -- head first: the gate's work is never dropped. Only a fast-forward is
        -- allowed, so a local commit the mirror does not have is never lost.
        if type(deps.git.fetch) == "function" and type(deps.git.rev_parse) == "function"
          and type(deps.git.reset_hard) == "function" then
          pcall(deps.git.fetch, paths.repo, "no-mistakes")
          local mirror = deps.git.rev_parse(worktree, "no-mistakes/" .. impl.ctx.branch)
          local live = type(deps.git.head_sha) == "function" and deps.git.head_sha(worktree) or nil
          if mirror and live and mirror ~= live and type(deps.git.is_ancestor) == "function" then
            local ancestor = deps.git.is_ancestor(worktree, live, mirror)
            if ancestor then
              pcall(deps.git.reset_hard, worktree, mirror)
            end
          end
        end

        local gate, gerr = nm.run({
          worktree = worktree,
          intent = task.intent or task.title,
          base = base,
          bin = cfg.review and cfg.review.no_mistakes_bin,
          timeout_ms = timeout,
          -- Match the CLI's hold to the task timeout, so a gate that is still
          -- fixing is not mistaken for a failed gate.
          wait = string.format("%dm", math.max(10, math.floor(timeout / 60000))),
        })
        if not gate then
          return { ok = false, error = gerr or "no-mistakes could not run" }
        end
        if not gate.ok then
          -- The gate reports; the task fails. It never bounces back to the
          -- implementer, which is the loop this engine exists to remove.
          return { ok = false, error = gate.error, no_mistakes = gate }
        end
        reviewed = { ok = true, approved = true, no_mistakes = gate }
        approved_sha = (deps.git.head_sha and deps.git.head_sha(worktree)) or impl.sha
        -- no-mistakes pushed the branch and opened the PR itself; read it back
        -- and attach it to the task before the merge step.
        local pr_err
        pr, pr_err = deps.git.pr_view(impl.ctx.branch, {
          repo = paths.repo,
          worktree = worktree,
          gh = "gh",
          timeout_ms = 60000,
        })
        if not pr then
          return {
            ok = false,
            error = "no-mistakes passed but its pull request cannot be found: "
              .. tostring(pr_err or "unknown gh error"),
            no_mistakes = gate,
          }
        end
        deps.git.pr_attach(state, paths.root, task_id, pr)
      else
        -- Open the pull request before the review: the reviewer reads the exact
        -- SHA on a real PR, and a human can follow it while the review runs. The
        -- task stays in `reviewing` until the review approves it.
        --
        -- A repair re-enters this path with the PR already open: it is reused,
        -- never recreated. `git.pr_open` attaches to an existing PR (contract),
        -- so the runtime does not even call it a second time — a second PR would
        -- split the review from the merge.
        if not pr then
          local pr_err
          pr, pr_err = deps.git.pr_open(state, paths.root, task_id, {
            repo = paths.repo,
            worktree = worktree,
            base = base,
            head = impl.ctx.branch,
            title = task.title,
            body = "Metronome task " .. task_id,
            gh = "gh",
            attach_only = true,
          })
          if not pr then
            -- `pr_open` already refused to reuse a recorded PR that gh did not
            -- confirm, so this error carries gh's own reason (cause, command,
            -- detail). Keep it: a generic sentence is a blank diagnosis.
            return {
              ok = false,
              error = "cannot open the pull request: "
                .. tostring(pr_err or "unknown gh error"),
            }
          end
        end

        -- A review that asks for changes is not a failure: it is the next round's
        -- work. The loop re-implements with the findings, re-runs the checks and
        -- the convergence diff, then reviews again, up to `review.max_rounds`.
        -- Only an exhausted bound escalates, and only a real error (a dead
        -- reviewer, an invalid answer) ends the task before that.
        local function fix(result)
          local findings = type(result) == "table" and result.findings or nil
          -- The round was opened on a task in `reviewing`; by the time its
          -- verdict lands another pilot may have moved the task on. Re-read the
          -- journal before re-implementing: a fix turn on a task that is no
          -- longer ours would be a second pilot.
          local current_state = state.load(paths.root)
          local current = current_state and current_state.tasks
            and current_state.tasks[task_id] or nil
          local status = type(current) == "table" and tostring(current.status or "")
            or "unknown"
          if REVIEW_ROUND_LOST[status] then
            local text = "review fix turn discarded: task no longer reviewing (status="
              .. status .. ")"
            log(paths, "task " .. tostring(task_id) .. ": " .. text)
            if type(state.append) == "function" then
              pcall(state.append, paths.root, { kind = "note", task_id = task_id, text = text })
            end
            return { ok = true, stale = true, discarded = true, status = status }
          end
          local moved, merr = state.transition(paths.root, task_id, "running", { phase = "implement" })
          if not moved then
            if is_illegal_transition(merr) then
              local text = "review fix turn discarded: " .. tostring(merr)
              log(paths, "task " .. tostring(task_id) .. ": " .. text)
              if type(state.append) == "function" then
                pcall(state.append, paths.root, { kind = "note", task_id = task_id, text = text })
              end
              return { ok = true, stale = true, discarded = true, status = status }
            end
            return { ok = false, error = merr or "cannot resume after review" }
          end
          log(paths, string.format("task %s: review round %s requested changes, re-implementing",
            task_id, tostring(result and result.round or "?")))
          local again, err = implement_and_verify(findings)
          if not again then
            return { ok = false, error = (err and err.error) or "fix failed" }
          end
          state.transition(paths.root, task_id, "verifying", { phase = "verify" })
          state.transition(paths.root, task_id, "reviewing", { phase = "review" })
          return true
        end

        local review_opts = {
          task = task_id,
          worktree = worktree,
          base = diff_base,
          git = deps.git,
          state = state,
          root = paths.root,
          runner = runner,
          tasks_dir = paths.tasks,
          repo = paths.repo,
          state_root = paths.runs,
          ctx = opts.ctx,
          session_opts = session.reviewer,
          fence = deps.fence,
          max_rounds = (cfg.review and cfg.review.max_rounds) or 3,
          fix = fix,
        }
        if type(deps.review.loop) == "function" then
          reviewed = deps.review.loop(review_opts)
        else
          reviewed = deps.review.review(review_opts)
        end
        if type(reviewed) == "table" and (reviewed.discarded or reviewed.stale) then
          -- The verdict belonged to a round this task already left. The review
          -- module journaled it as a stale note and dropped it; the run must
          -- not turn that into a task failure.
          local text = "task " .. tostring(task_id)
            .. ": stale review verdict discarded, nothing is shipped"
          log(paths, text)
          return {
            ok = true,
            skipped = true,
            stale = true,
            task_id = task_id,
            pr = pr,
            reason = text,
          }
        end
        if not reviewed.ok or not reviewed.approved then
          local reason = (reviewed and reviewed.error) or "review not approved"
          if type(reviewed) == "table" and reviewed.escalated then
            reason = string.format("review escalated after %s round(s)", tostring(reviewed.round or "?"))
          end
          return { ok = false, error = reason, review = reviewed, pr = pr }
        end

        -- The SHA the reviewer approved is the one that ships, not the first
        -- round's: a fix round moved the branch.
        approved_sha = (reviewed and reviewed.sha) or impl.sha
      end

      -- The review passed on the exact SHA: move the task to `pr_open` now.
      state.transition(paths.root, task_id, "pr_open", { phase = "review" })

      -- `auto_merge` is the project's switch. Off means the task stops at
      -- `pr_open` with a PR a human can review and merge; on means the merger
      -- takes it the rest of the way (and redeploys when `auto_deploy` is set).
      if engine ~= "no-mistakes" and not (cfg.merge and cfg.merge.auto_merge) then
        return { ok = true, task_id = task_id, sha = approved_sha, pr = pr, pr_open = true }
      end

      local merge_err
      merged, merge_err = with_merge_gate(function()
        return deps.merge.run({
          task = task_id,
          -- The PR read back by `pr_open` in this run (reused, recreated or
          -- attached after no-mistakes), persisted before it was returned. The
          -- merge never reconstructs a PR supposed from the state loaded at the
          -- beginning of the run.
          pr = type(pr) == "table" and (pr.number or pr.url) or pr,
          worktree = worktree,
          repo = paths.repo,
          git = deps.git,
          state = state,
          root = paths.root,
          remote = "origin",
          base = base,
          checks = deps.checks,
          gh = "gh",
          method = cfg.merge.method,
          verify = cfg.checks.re_run_after_merge ~= false,
          commands = checks,
          -- A subtask merges into the epic branch, which is not a deployable
          -- base: recording it as deploy-pending would ship work that never
          -- reached the project base.
          deploy_pending = not epic_subtask,
        })
      end)
      if not merged then
        return { ok = false, error = tostring(merge_err or "merge failed") }
      end
      if merged.ok then
        break
      end

      -- A conflict with the base is repairable without a human: the task goes
      -- back to the implementer on the fresh base with the conflict facts, and
      -- the next turn resolves and pushes. This loop is the repair — the
      -- caller no longer relaunches the merge, which would replay the same
      -- commit on the same base. The bound counts real repairs, comes from the
      -- project's config, and is persisted with the counter.
      local details = merged.conflict and conflict_details(merged, base) or nil
      local repaired = false
      if details and repairs < repair_bound then
        local base_sha = type(deps.git.rev_parse) == "function"
          and deps.git.rev_parse(worktree, "origin/" .. base) or nil
        local reset = base_sha and type(deps.git.reset_hard) == "function"
          and deps.git.reset_hard(worktree, base_sha) or nil
        if reset then
          if base_sha then
            details.base_sha = details.base_sha or base_sha
          end
          log(paths, "task " .. task_id .. " hit a merge conflict on "
            .. tostring(merged.conflict_files) .. "; redoing it on the fresh base")
          repairs = repairs + 1
          -- `merging` has no edge back to `running`: the repair is a
          -- continuation of the turn, not a failure, so status, phase and
          -- counter are written together. A reload then resumes in implement
          -- with the conflict already journalled. The note itself is written
          -- once, by `merge.run` (the repairable branch it returns from), so
          -- the runtime does not duplicate it: one conflict, one note.
          pcall(state.set_fields, paths.root, task_id, {
            status = "running",
            phase = "implement",
            conflict_retried = true,
            conflict_retries = repairs,
          })
          -- The branch is back on the fresh base: the PR is the same PR, so the
          -- push leases it and no second PR is opened.
          if type(deps.git.push) == "function" then
            pcall(deps.git.push, worktree, impl.ctx.branch, { remote = "origin", force = true })
          end
          conflict = details
          repaired = true
        end
      end
      if not repaired then
        if details then
          -- Beyond the bound the human gets the means to act — the files, the
          -- base and the exact command — not git's raw "rebase failed".
          local message = conflict_escalation(details)
          journal_conflict(state, paths.root, task_id, details, message)
          return { ok = false, error = message, phase = "merge", task_id = task_id }
        end
        return merged
      end
    end

    -- A subtask of an epic stops at `merged`: its work is on the epic branch,
    -- not on the project base, so there is nothing to deploy yet. The epic
    -- task owns the single PR to the project base and the deploy that follows.
    if epic_subtask then
      log(paths, "task " .. task_id .. " merged into " .. tostring(base)
        .. "; the epic deploys, not this subtask")
      return {
        ok = true,
        task_id = task_id,
        sha = approved_sha,
        pr = pr,
        merged = merged,
        epic_subtask = true,
      }
    end

    -- The merger redeploys: once the PR is merged and the checks are green on
    -- the merged base, run the deploy plan without asking. `auto_deploy` is
    -- the project's switch; a project that wants a human gate keeps it off.
    if cfg.deploy and cfg.deploy.auto_deploy then
      local deployed = deps.deploy.run({
        task = task_id,
        root = paths.root,
        state = state,
        repo = paths.repo,
        plan_path = fs.joinpath(paths.repo, cfg.deploy.plan_file or "deploy.md"),
        runner = runner,
        script = true,
        confirm = false,
        confirmed = true,
        session_opts = session.deployer,
        state_root = paths.runs,
        ctx = opts.ctx,
        checks = deps.checks,
      })
      if not deployed.ok then
        return {
          ok = false,
          error = "deploy failed: " .. tostring(deployed.error),
          task_id = task_id,
          pr = pr,
          merged = merged,
          deployed = deployed,
        }
      end
      return { ok = true, task_id = task_id, sha = approved_sha, pr = pr, merged = merged, deployed = deployed }
    end

    return { ok = true, task_id = task_id, sha = approved_sha, pr = pr, merged = merged }
  end

  -- Drive every ready task --------------------------------------------------

  -- Build the runner and the per-role session options. The scripted runner is
  -- used by the e2e driver; the real one opens maki subagent sessions with the
  -- ctx that came from the tool call.
  local function prepare(opts, cfg, paths)
    local script, serr = load_script(paths)
    if serr then
      return nil, nil, nil, serr
    end
    local runner
    local session
    if script then
      runner = scripted_runner(script, paths)
      session = {
        qualifier = { system = "", model_spec = "e2e/model", thinking = "low", tools = {} },
        analyst = { system = "", model_spec = "e2e/model", thinking = "low", tools = {} },
        implementer = { system = "", model_spec = "e2e/model", thinking = "low", tools = {} },
        reviewer = { system = "", model_spec = "e2e/model", thinking = "low", tools = {} },
        deployer = { system = "", model_spec = "e2e/model", thinking = "low", tools = {} },
      }
    else
      runner = real_runner(opts)
      session = {}
      for _, role in ipairs({ "qualifier", "analyst", "implementer", "reviewer", "deployer" }) do
        local sopts, oerr = session_opts(cfg, role, paths)
        if not sopts then
          return nil, nil, nil, oerr
        end
        session[role] = sopts
      end
    end
    return runner, session, script
  end

  -- Run `fn` off the caller's turn. `deps.spawn` is the test seam; in maki a
  -- background task is what lets submit return before qualification ends.
  local function spawn(fn)
    if type(deps.spawn) == "function" then
      return deps.spawn(fn)
    end
    -- `maki.async.spawn` lives as long as the plugin; `maki.async.run` is tied
    -- to the caller's task and is cancelled when the tool handler returns, so
    -- the role session it opened dies at once. Use spawn.
    if maki.async and type(maki.async.spawn) == "function" then
      return maki.async.spawn(fn)
    end
    if maki.async and type(maki.async.run) == "function" then
      return maki.async.run(fn)
    end
    return fn()
  end

  -- Run `fn` after `ms` milliseconds, off the caller's turn. The host seam is
  -- `deps.defer` (tests), then `maki.defer_fn`; nil means no timer is available
  -- and the caller falls back to an immediate, still bounded, action.
  later = function(fn, ms)
    local defer = type(deps.defer) == "function" and deps.defer
      or (type(maki.defer_fn) == "function" and maki.defer_fn)
      or nil
    if not defer then
      return nil
    end
    local ok, handle = pcall(defer, fn, ms)
    if not ok then
      return nil
    end
    return handle or true
  end

  -- The typed failure policy: classify, record and decide. `deps.recover` is
  -- the seam; the module is loaded once when the wiring leaves it out, so a
  -- caller that only injects the pipeline modules still gets typed failures.
  local cached_recover
  recover_module = function()
    if type(deps.recover) == "table" then
      return deps.recover
    end
    if cached_recover ~= nil then
      return cached_recover or nil
    end
    local ok, mod = pcall(require, "metronome.recover")
    if ok and type(mod) == "table" then
      cached_recover = mod
      return mod
    end
    cached_recover = false
    return nil
  end

  -- The retry bounds for this project: the optional `[recover]` section first,
  -- recover's defaults otherwise. `auto_retry = false` keeps the escalation to
  -- a human even for a transient cause, for a project that does not want the
  -- scheduler spending a budget on a durably broken environment.
  recover_opts = function(cfg)
    local section = type(cfg) == "table" and type(cfg.recover) == "table" and cfg.recover or nil
    local out = {}
    if section then
      out.max_attempts = tonumber(section.max_attempts)
      out.backoff_base_secs = tonumber(section.backoff_base_secs)
      out.backoff_max_secs = tonumber(section.backoff_max_secs)
      out.factor = tonumber(section.factor)
      out.auto_retry = section.auto_retry ~= false
    else
      out.auto_retry = true
    end
    return out
  end

  -- A single bounded line, so a git message with newlines or a runaway
  -- transcript excerpt never bloats the persisted reason, the journal or the
  -- status projection. Mirrors `recover.one_line` for the fallback path below.
  local function one_line(value, max)
    local text = tostring(value or ""):gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    max = tonumber(max) or 160
    if #text > max then
      text = text:sub(1, max) .. "…"
    end
    return text
  end

  -- One line that names the cause, the remedy and what happens next, so a log
  -- line or a notification is actionable without reading the transcript.
  -- `recover.describe` is the authority: it normalises the message and bounds
  -- it. The local formatting only runs when that module is not wired.
  describe_failure = function(failure, decision)
    failure = type(failure) == "table" and failure or {}
    decision = type(decision) == "table" and decision or {}
    local recover = recover_module()
    if recover and type(recover.describe) == "function" then
      local ok, line = pcall(recover.describe, failure)
      if ok and type(line) == "string" and line ~= "" then
        -- `describe` recomputes the decision with the module's defaults; the
        -- runtime's decision may differ (project bounds, `auto_retry = false`),
        -- so name what will really happen when the two disagree.
        if type(decision.action) == "string" then
          local eff_ok, eff = pcall(recover.decide, failure)
          if eff_ok and type(eff) == "table" and eff.action ~= decision.action then
            local effective = decision.action == "auto_retry"
              and "automatic retry" or decision.action
            line = line .. " — effective: " .. effective
          end
        end
        return line
      end
    end
    local action
    if decision.action == "auto_retry" then
      action = string.format("automatic retry in %ds", tonumber(decision.delay_secs) or 0)
    elseif decision.action == "none" then
      action = "redo the step, nothing was lost"
    else
      action = "human intervention required"
    end
    local message = one_line(failure.message, 160)
    if message == "" then
      message = "(no message)"
    end
    local remedy = one_line(failure.remedy, 160)
    if remedy == "" then
      remedy = "inspect the transcript"
    end
    return string.format("%s: %s — remedy: %s — %s (attempt %s/%s)",
      tostring(failure.cause or "unknown"),
      message,
      remedy,
      action,
      tostring(failure.attempts or 0),
      tostring(decision.max_attempts or "?"))
  end

  -- A step may hand back its own diagnosis: a fetch failure is a network or
  -- credentials problem whatever git printed, and a red gate is a code problem.
  -- That diagnosis wins over the textual classification, while the record keeps
  -- the attempt accounting and the backoff deadline the policy computed.
  typed_failure = function(failure, diagnosis, opts)
    if type(failure) ~= "table" or type(diagnosis) ~= "table" then
      return failure
    end
    failure.cause = diagnosis.cause or failure.cause
    failure.message = diagnosis.message or failure.message
    failure.remedy = diagnosis.remedy or failure.remedy
    failure.transient = diagnosis.transient == true
    failure.retryable = diagnosis.retryable == true
    failure.remediable = diagnosis.remediable ~= false
    local recover = recover_module()
    local at = tonumber(failure.at) or os.time()
    if failure.transient then
      local backoff = recover and type(recover.backoff_secs) == "function"
        and recover.backoff_secs(failure.attempts, opts) or 0
      failure.next_retry_at = at + backoff
    else
      -- A permanent cause schedules nothing: only a human can unblock it.
      failure.next_retry_at = at
    end
    return failure
  end

  -- A rebase that fails before it starts is a fetch failure. Whatever git
  -- printed, the cause is the remote or the credentials, which a retry or a
  -- login can fix: classify it, and fall back to `network`/transient rather
  -- than a generic permanent string.
  fetch_diagnosis = function(err)
    local recover = recover_module()
    local diagnosis = recover and type(recover.classify) == "function"
      and recover.classify(err) or nil
    if type(diagnosis) == "table" then
      local cause = diagnosis.cause
      if cause == "network" or cause == "auth" or cause == "timeout"
        or cause == "killed" or cause == "quota" or cause == "session_dead"
        or cause == "binary_missing" then
        return diagnosis
      end
    end
    return {
      cause = "network",
      message = "cannot fetch the base from origin: " .. tostring(err or "no output"),
      remedy = "check the network, the remote and the credentials (gh auth status), then retry.",
      transient = true,
      retryable = true,
      remediable = true,
    }
  end

  -- A task that will not be merged must not leave an open PR behind: the list
  -- fills with pull requests nobody will ever look at. The branch stays, so a
  -- retry can still resume from its checkpoints. A transient failure never
  -- reaches this: the branch and the PR are what its retry resumes from.
  local function close_open_pr(paths, task_id)
    local loaded = deps.state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[task_id]
    local pr = task and task.pr
    if type(pr) ~= "table" or pr.state ~= "open" then
      return false
    end
    if type(deps.git.pr_close) ~= "function" then
      return false
    end
    local ok = pcall(deps.git.pr_close, pr.number or pr.url, { gh = "gh" })
    if ok then
      pcall(deps.state.set_fields, paths.root, task_id, { pr = { number = pr.number, url = pr.url, state = "closed" } })
    end
    return ok
  end

  -- Scheduler state. Declared here, before `after_questions`, so the drain and
  -- a task finishing in its own spawn share the same upvalues.
  local scheduler_running = false
  local scheduler_dirty = false
  local scheduler_job = nil
  local scheduler_extra = {}

  -- One handle per task in flight. Stopping a task means cancelling its spawn,
  -- not only moving its status: the session it opened has to die too.
  local task_handles = {}

  -- Filled in with the drain helpers below. A task dispatched by the scheduler
  -- runs through exactly the same failure policy as a retry or a resume, so the
  -- scheduler only needs the runner here, not a second copy of the policy.
  local run_and_handle
  local schedule_retry

  -- A task finished, a retry or a resume job completed: a slot may have freed
  -- a dependent or moved a task on, so trigger another drain. Only in the async
  -- path, where the current drain returned long ago; setting the flag in the
  -- synchronous path would make its drain loop forever. Shared by
  -- `dispatch_one` and `run_pending`'s extra jobs so a successful retry never
  -- leaves the workflow stopped.
  local function redrain()
    if deps.async then
      scheduler_dirty = true
      spawn(function()
        pcall(runtime.run_pending)
      end)
    end
  end

  -- A quarantined task must leave quarantine without a new submit: the gate
  -- re-analyses every `qualifying` sheet (cheaply, through its fingerprint
  -- cache) but `after_questions` only runs when the scheduler is dirty, and
  -- once the rest of the queue has drained nothing dirties it any more. So a
  -- pass that leaves quarantine behind arms one more pass later, with a bounded
  -- backoff so a permanently blocked sheet costs a gate pass every few minutes
  -- instead of a spin. The timer is a one-shot host callback, not a coroutine
  -- suspended for the life of the plugin.
  local QUARANTINE_REPOLL_MS = 30000
  local QUARANTINE_REPOLL_MAX_MS = 300000
  local quarantine_passes = 0
  local quarantine_repoll_armed = false

  -- Does any task still carry a non-empty quarantine? Read errors are treated
  -- as "nothing to re-poll": a state that cannot be loaded must not arm a timer
  -- that would fail the same way forever.
  local function has_quarantined_tasks(paths)
    local called, loaded = pcall(deps.state.load, paths.root)
    if not called or type(loaded) ~= "table" or type(loaded.tasks) ~= "table" then
      return false
    end
    for _, task in pairs(loaded.tasks) do
      if type(task) == "table" and type(task.quarantine) == "table"
        and next(task.quarantine) ~= nil then
        return true
      end
    end
    return false
  end

  -- Arm the next re-analysis pass. Only the async path needs it: the scripted
  -- e2e path is synchronous and driven by its own drain.
  local function arm_quarantine_pass()
    if not deps.async or quarantine_repoll_armed then
      return
    end
    local delay = math.min(QUARANTINE_REPOLL_MS * (2 ^ quarantine_passes), QUARANTINE_REPOLL_MAX_MS)
    if quarantine_passes < 8 then
      quarantine_passes = quarantine_passes + 1
    end
    local armed = later(function()
      quarantine_repoll_armed = false
      scheduler_dirty = true
      pcall(runtime.run_pending)
    end, delay)
    if armed ~= nil then
      quarantine_repoll_armed = true
    end
  end

  -- Quarantine the tasks an analysis-gate failure names, or the whole analysed
  -- batch when it names none. The gate is not the only way a task is set aside:
  -- a gate that raises, or reports an error/blocked verdict, must still isolate
  -- the offending sheets and leave the rest of the queue free to drain. The
  -- returned ids are the ones actually marked, so the caller can log and report
  -- them without a second read of the journal.
  local function isolate_gate_failure(paths, gate, message)
    -- This branch exists to survive a broken analysis. A state that cannot be
    -- read must not raise out of it either: the caller still has to drain.
    local called, loaded = pcall(deps.state.load, paths.root)
    if not called then
      return {}
    end
    local all = type(loaded) == "table" and type(loaded.tasks) == "table" and loaded.tasks or {}
    local batch, in_batch = {}, {}
    for id, task in pairs(all) do
      if type(task) == "table" and task.status == "qualifying" then
        id = tostring(id)
        batch[#batch + 1] = id
        in_batch[id] = true
      end
    end
    table.sort(batch)
    if #batch == 0 then
      return {}
    end

    local named, seen = {}, {}
    local function name(id)
      id = tostring(id)
      if in_batch[id] and not seen[id] then
        seen[id] = true
        named[#named + 1] = id
      end
    end
    if type(gate) == "table" then
      if type(gate.quarantined) == "table" then
        for _, id in ipairs(gate.quarantined) do
          name(id)
        end
      end
      for _, finding in ipairs(type(gate.findings) == "table" and gate.findings or {}) do
        if type(finding) == "table" and type(finding.tasks) == "table" then
          for _, id in ipairs(finding.tasks) do
            name(id)
          end
        end
      end
    end
    if #named == 0 and message ~= "" then
      -- An unattributable failure: the raw message may still name a task.
      for _, id in ipairs(batch) do
        if message:find(id, 1, true) then
          name(id)
        end
      end
    end
    local targets = #named > 0 and named or batch

    local rule = "analysis_gate_error"
    local quarantined = {}
    for _, id in ipairs(targets) do
      local payload = {
        reason = "analysis_gate_error",
        rules = { rule },
        findings = {
          { severity = "blocking", rule = rule,
            message = message ~= "" and message or "analysis gate failed" },
        },
        since = os.time(),
      }
      local ok, wrote = pcall(deps.state.set_fields, paths.root, id, { quarantine = payload })
      if ok and wrote then
        quarantined[#quarantined + 1] = id
      end
    end
    return quarantined
  end

  -- Slots ------------------------------------------------------------------

  -- The statuses that hold a slot. Mirrors `pipeline.ACTIVE`; it is only a
  -- fallback for a caller that injected a pipeline module without `slots()`.
  local ACTIVE_STATUSES = {
    running = true,
    verifying = true,
    reviewing = true,
    merging = true,
    deploying = true,
  }

  -- The statuses `pipeline.resume` can walk back to `running`. Mirrors its
  -- local `RESUME_PHASE`; only a fallback for the compare-and-set the resume
  -- does before parking a task, so a task that reached a status the resume
  -- cannot revive (`merged`, `queued`, ...) is never parked from it.
  local RESUME_STATUSES = {
    running = true,
    stalled = true,
    verifying = true,
    reviewing = true,
    merging = true,
    deploying = true,
    failed = true,
  }

  -- The requeue reason written when no slot is missing: the task is handed
  -- back to the queue because a retry or a resume must not start it on its own
  -- authority, not because the pipeline is full.
  local REQUEUE_FOR_DISPATCH = "requeued for dispatch"

  -- The project's cap, read exactly like the drain reads it, so a retry, a
  -- resume, the status view and `pipeline.tick` all charge the same budget.
  local function max_parallel_of(cfg)
    local value = tonumber(type(cfg) == "table" and cfg.project and cfg.project.max_parallel)
      or tonumber(type(cfg) == "table" and cfg.max_parallel) or 1
    if value < 1 then
      value = 1
    end
    return value
  end

  -- One wording for "no free slot", shared with `pipeline` so a tick skip, a
  -- retry requeue and a resume requeue all say the same thing.
  local function wait_slot_reason()
    local text = type(deps.pipeline) == "table" and deps.pipeline.WAIT_SLOT or nil
    if is_non_empty(text) then
      return text
    end
    return "waiting for a free slot"
  end

  -- Normalise a projection to a list, for the fallback accounting below.
  local function task_list(tasks)
    local list = {}
    if type(tasks) ~= "table" then
      return list
    end
    if tasks[1] ~= nil then
      for _, task in ipairs(tasks) do
        if type(task) == "table" and type(task.id) == "string" then
          list[#list + 1] = task
        end
      end
      return list
    end
    local ids = {}
    for id, task in pairs(tasks) do
      if type(task) == "table" and type(task.id) == "string" then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      list[#list + 1] = tasks[id]
    end
    return list
  end

  -- The slot accounting a retry, a resume and the status view all use, so none
  -- of them can read a different budget from the one `tick` enforces.
  -- `exclude` names one task left out of the count: a task whose pilot has not
  -- noticed yet must not be charged twice against the same budget.
  local function slot_counts(tasks, max_parallel, exclude)
    local pipeline = type(deps.pipeline) == "table" and deps.pipeline or nil
    if pipeline and type(pipeline.slots) == "function" then
      local called, in_flight, cap, free = pcall(pipeline.slots, tasks, {
        max_parallel = max_parallel,
        exclude = exclude,
      })
      if called and tonumber(cap) then
        return tonumber(in_flight) or 0, tonumber(cap), tonumber(free) or 0
      end
    end
    local cap = tonumber(max_parallel) or 1
    if cap < 1 then
      cap = 1
    end
    local in_flight = 0
    for _, task in ipairs(task_list(tasks)) do
      -- Mirror `pipeline.slots`: a parked `slot_wait` task holds no slot, even
      -- when its original status is an active one.
      if ACTIVE_STATUSES[task.status] and not task.slot_wait
        and (exclude == nil or task.id ~= exclude) then
        in_flight = in_flight + 1
      end
    end
    local free = cap - in_flight
    if free < 0 then
      free = 0
    end
    return in_flight, cap, free
  end

  -- Persist a slot wait: `slot_wait = true`, its timestamp, and the named
  -- reason in the journal. The task keeps its status and phase — a slot wait is
  -- not a failure and never touches `failure_reason`. The field and the note
  -- land in one append, so a reader never sees the flag without its reason.
  --
  -- A caller-injected state without `append` (tests, a scripted driver) still
  -- gets the field through `set_fields`; the reason then lives in the returned
  -- result and the status view rather than the journal.
  local function mark_slot_wait(paths, task_id, reason, now)
    now = now or os.date("!%Y-%m-%dT%H:%M:%SZ")
    if type(deps.state.append) == "function" then
      local ok, err = deps.state.append(paths.root, {
        {
          kind = "field",
          task_id = task_id,
          fields = { slot_wait = true, slot_wait_since = now },
        },
        { kind = "note", task_id = task_id, text = reason },
      })
      if not ok then
        return nil, err
      end
      return true
    end
    if type(deps.state.set_fields) == "function" then
      local ok, err = deps.state.set_fields(paths.root, task_id, {
        slot_wait = true,
        slot_wait_since = now,
      })
      if not ok then
        return nil, err
      end
      return true
    end
    return nil, "the state module cannot persist a slot wait"
  end

  -- Why a task is not running, in words a human can act on. Computed from the
  -- live projection, never persisted: the journal keeps the reason in a note
  -- and this view recomputes it, so the status stays truthful after a reload.
  -- An unmet dependency is named first — it would hold the task even with an
  -- empty pipeline — then the slot wait. A task carrying the persisted
  -- `slot_wait` flag is waiting by construction, whatever its status; a plain
  -- `ready` task waits only when the cap leaves it no slot. Returns the reason
  -- and, for a slot wait, its structure.
  local function wait_reason_of(task, projection, max_parallel)
    if type(task) ~= "table" or (not task.slot_wait and task.status ~= "ready") then
      return nil, nil
    end
    local pipeline = type(deps.pipeline) == "table" and deps.pipeline or nil
    if pipeline and type(pipeline.dependencies_met) == "function" then
      local called, met, why = pcall(pipeline.dependencies_met, task, projection, {
        max_parallel = max_parallel,
        recover = recover_module(),
      })
      if called and met == false and is_non_empty(why) then
        return why, nil
      end
    end
    local in_flight, cap, free = slot_counts(projection, max_parallel, task.id)
    -- A free slot means the drain can dispatch the task right away. A
    -- `slot_wait` flag set while a slot is available is a hand-off to that
    -- drain, not a wait — reporting it as `0 in flight, max_parallel 1` would
    -- contradict itself. The journal still keeps the exact reason ("requeued
    -- for dispatch"); the status only names a wait when the cap is actually
    -- full, which is when a human wonders why nothing started.
    if free > 0 then
      return nil, nil
    end
    local reason = wait_slot_reason()
    return string.format("%s (%d in flight, max_parallel %d)", reason, in_flight, cap), {
      reason = reason,
      in_flight = in_flight,
      max_parallel = cap,
    }
  end

  -- The part of a run that follows qualification: the analysis gate, the
  -- scheduler loop and the optional deploy. `submit` reaches it after applying
  -- the qualified tasks; `answer` reaches it after the pending questions are
  -- answered, so answering resumes the pipeline instead of leaving the tasks
  -- stuck in `qualifying` forever.
  --
  -- A blocking finding never stops this function. The gate quarantines its
  -- tasks and every pass still drains whatever is ready; a gate that raises or
  -- reports an error/blocked verdict is caught, its tasks are quarantined and
  -- the drain runs anyway. Every quarantine is logged with its named rules, so
  -- a freeze is never silent.
  local function after_questions(opts, paths, cfg, runner, session)
    local gate_called, gate, gerr = pcall(deps.analyze.gate, deps.state, paths.root, {
      tasks_dir = paths.tasks,
      repo = paths.repo,
      ref = "origin/" .. tostring(cfg.project.base_ref),
      git = deps.git,
    })
    if not gate_called then
      gerr = gate
      gate = nil
    end

    local quarantined = {}
    local findings = type(gate) == "table" and type(gate.findings) == "table"
      and gate.findings or {}
    if not gate_called or type(gate) ~= "table" or gate.ok ~= true then
      local message = tostring(gerr
        or (type(gate) == "table" and (gate.error or gate.verdict))
        or "analysis gate failed")
      -- The isolation work itself must never raise out of the recovery branch:
      -- a state or journal that fails here would escape `after_questions` and
      -- skip the drain, which is the opposite of the contract.
      local isolated, marked = pcall(isolate_gate_failure, paths, gate, message)
      if not isolated then
        log(paths, "analysis gate failure could not be isolated: " .. tostring(marked))
        marked = {}
      end
      quarantined = marked or {}
      -- Log the ids *and* the rule actually stored in their quarantine, so the
      -- error path is as readable as the blocked one.
      local parts = {}
      for _, id in ipairs(quarantined) do
        parts[#parts + 1] = tostring(id) .. " (analysis_gate_error)"
      end
      log(paths, "analysis gate failed (" .. message .. "); quarantined "
        .. (#parts > 0 and table.concat(parts, "; ") or "none")
        .. "; draining ready tasks anyway")
    elseif type(gate.quarantined) == "table" and #gate.quarantined > 0 then
      local blocked = type(gate.blocked) == "table" and gate.blocked or {}
      local parts = {}
      for _, raw_id in ipairs(gate.quarantined) do
        local id = tostring(raw_id)
        quarantined[#quarantined + 1] = id
        local info = blocked[id]
        local rules = type(info) == "table" and type(info.rules) == "table" and info.rules or {}
        local label
        if #rules > 0 then
          label = table.concat(rules, ", ")
        elseif type(info) == "table" and info.reason ~= nil then
          label = tostring(info.reason)
        else
          label = "analysis_blocked"
        end
        parts[#parts + 1] = id .. " (" .. label .. ")"
      end
      log(paths, "analysis quarantined " .. table.concat(parts, "; "))
    end

    local results = {}
    local deployed = false

    -- `max_parallel` is the project's cap, not a hardcoded one: a queue of
    -- independent asks must not take one full pipeline each, end to end. Read
    -- through the shared helper so a retry or a resume counts the same budget.
    local max_parallel = max_parallel_of(cfg)

    -- Each selected task runs in its own plugin-lifetime spawn. A batch held
    -- by `async.join` lives in the drain's scope, and maki kills the live jobs
    -- of a scope when it ends: the sessions died mid-review. A spawn outlives
    -- the drain, and a finished task re-triggers the drain to refill the slots.
    --
    -- No task ever runs on the scheduler's turn: `dispatch_one` only spawns.
    -- That is what makes the drain unblockable — a slow, stuck or crashing task
    -- leaves the loop free to start the next one.
    local function dispatch_one(task)
      local handle = spawn(function()
        -- `run_and_handle` already guards the failure policy; this guard also
        -- covers anything it returns or raises outside it, so `results` and
        -- `task_handles` are always settled and the re-drain always fires.
        local called, result = pcall(
          run_and_handle, opts, paths, cfg, runner, session, task.id)
        if not called then
          result = { ok = false, error = tostring(result) }
          log(paths, "task " .. tostring(task.id)
            .. " crashed the drain: " .. tostring(result.error))
        end
        results[#results + 1] = result
        task_handles[task.id] = nil
        redrain()
      end)
      if handle ~= nil then
        task_handles[task.id] = handle
      end
    end

    -- `schedule_retry` is the single authority for automatic retries: it owns
    -- the attempt streak and the `auto_retry` opt-out, neither of which the
    -- tick's `retry_ready` can see. If the tick also picked a failed task, the
    -- backoff timer and this drain could dispatch the same worktree twice, and
    -- the tick would use its own default bound instead of the project's. A zero
    -- bound makes `retry_ready` select nothing; the drain only starts `ready`
    -- tasks here, and a failed task is resumed by its own scheduled job.
    for _ = 1, 32 do
      local tick = deps.pipeline.tick({
        state = deps.state,
        root = paths.root,
        max_parallel = max_parallel,
        stall = false,
        apply = true,
        dispatch = dispatch_one,
        max_attempts = 0,
        recover = recover_module(),
      })
      if not tick.ok then
        return { ok = false, error = tick.error, results = results,
          quarantined = quarantined, findings = findings }
      end
      if #tick.started == 0 then
        break
      end
    end

    -- An async drain returns while its tasks are still running: the pending
    -- check and the final deploy belong to the synchronous path (the scripted
    -- e2e driver), where every task has already finished by now.
    if deps.async then
      return { ok = true, results = results, background = true,
        quarantined = quarantined, findings = findings }
    end

    local loaded = deps.state.load(paths.root)
    local last = nil
    local pending = {}
    for _, task in pairs(loaded and loaded.tasks or {}) do
      if task.status == "merged" then
        -- Only a task that merged into the project base is deployable here. A
        -- subtask merged into an epic branch waits for the epic.
        if M.task_base(task, cfg) == cfg.project.base_ref then
          last = task
        end
      elseif task.status ~= "deployed" and task.status ~= "abandoned"
        and not (type(task.quarantine) == "table" and next(task.quarantine) ~= nil) then
        -- A quarantined task stays `qualifying` on purpose: a blocking finding
        -- parks it without stopping the workflow, so it is not an unfinished
        -- task for the scripted drain.
        pending[#pending + 1] = task.id
      end
    end
    if #pending > 0 then
      return {
        ok = false,
        error = "tasks did not finish: " .. table.concat(pending, ", "),
        results = results,
        quarantined = quarantined,
        findings = findings,
      }
    end
    if last then
      local deployed_result = deps.deploy.run({
        task = last.id,
        root = paths.root,
        state = deps.state,
        repo = paths.repo,
        plan_path = fs.joinpath(paths.repo, cfg.deploy.plan_file or "deploy.md"),
        runner = runner,
        script = true,
        confirm = false,
        confirmed = true,
        session_opts = session.deployer,
        state_root = paths.runs,
        ctx = opts.ctx,
        checks = deps.checks,
      })
      deployed = deployed_result.ok or false
      results[#results + 1] = deployed_result
    end

    return { ok = true, results = results, deployed = deployed,
      quarantined = quarantined, findings = findings }
  end

  -- Background scheduler -----------------------------------------------------
  --
  -- The pipeline must not block the chat: a submit returns as soon as the
  -- tasks are qualified. A top-level spawn loop (started by init.lua) polls
  -- `has_pending` and calls `run_pending`, so role sessions are opened from a
  -- true background task, not from a tool handler or an autocmd callback.
  local function ctx_session_id(ctx)
    if ctx == nil then
      return nil
    end
    -- A LuaCtx is userdata: index it through the method, never as a field.
    local ok, sid = pcall(function()
      return ctx:session_id()
    end)
    pcall(function()
      maki.log.info("metronome ctx_session_id ok=" .. tostring(ok)
        .. " sid=" .. tostring(sid))
    end)
    if ok and type(sid) == "string" and sid ~= "" then
      return sid
    end
    ok, sid = pcall(function()
      return ctx.session_id
    end)
    if ok and type(sid) == "string" and sid ~= "" then
      return sid
    end
    return nil
  end

  local function background_ctx(ctx)
    if type(ctx) == "table" then
      -- Already a background context (`{ session = sid }`) or a caller-built
      -- table (tests): keep it, never swap in whatever session is focused when
      -- the scheduler drains the queue.
      return ctx
    end
    local sid = ctx_session_id(ctx)
    if not sid and maki.session and type(maki.session.current) == "function" then
      local ok, current = pcall(maki.session.current)
      if ok then
        sid = current
      end
    end
    if type(sid) == "string" and sid ~= "" then
      return { session = sid }
    end
    pcall(function()
      maki.log.info("metronome background_ctx in=" .. type(ctx) .. " sid=nil")
    end)
    return ctx
  end

  -- A background qualification cannot block on a tool result, so it pushes the
  -- questions back into the chat: the agent relays them with the native
  -- `question` tool and answers through `metronome_answer`.
  -- The instruction the agent receives when a round is waiting: ask it with
  -- the native `question` tool, then hand the answers back. The panel and the
  -- background qualifier use the same text, so a question looks the same
  -- wherever it comes from.
  local function questions_prompt(questions)
    local lines = {
      "Metronome a qualifié une intention et a besoin de réponses.",
      "Utilise l'outil `question` pour poser ces questions à l'utilisateur, puis appelle `metronome_answer` avec les réponses (la clé est entre parenthèses).",
    }
    for _, question in ipairs(questions) do
      lines[#lines + 1] = string.format("- (%s) %s", tostring(question.id), tostring(question.text))
    end
    return table.concat(lines, "\n")
  end

  local function ask_in_chat(ctx, questions)
    if not (maki.session and type(maki.session.prompt) == "function") then
      return false
    end
    local sid = type(ctx) == "table" and ctx.session or ctx_session_id(ctx)
    local ok, sent = pcall(maki.session.prompt, questions_prompt(questions), { session = sid })
    return ok and sent ~= nil
  end

  -- A failure must reach the user, not only runtime.log: a task that fails
  -- while the user is away would otherwise sit in `failed` forever with nobody
  -- told. `notify` with `wake = true` starts a turn when the chat is idle; the
  -- prompt is the fallback when notify is unavailable.
  local function notify_failure(ctx, task_id, reason)
    local sid = type(ctx) == "table" and ctx.session or ctx_session_id(ctx)
    if not sid then
      return false
    end
    local text = string.format(
      "Metronome: task %s failed: %s. The worktree, branch, checkpoints and transcript are intact. Call metronome_status for the detail, then metronome_retry (or /reload) to resume it.",
      tostring(task_id), tostring(reason or "unknown error"))
    if maki.session and type(maki.session.notify) == "function" then
      local ok, sent = pcall(maki.session.notify, text, { session = sid, wake = true })
      if ok and sent then
        return true
      end
    end
    if maki.session and type(maki.session.prompt) == "function" then
      local ok, sent = pcall(maki.session.prompt, text, { session = sid })
      return ok and sent ~= nil
    end
    return false
  end

  local function schedule_job(opts, paths, cfg, runner, session)
    scheduler_job = {
      opts = opts,
      paths = paths,
      cfg = cfg,
      runner = runner,
      session = session,
    }
    scheduler_dirty = true
    -- Spawn a drain task only when there is work, and let it end when the
    -- queue is empty. A perpetual `sleep` loop keeps a coroutine suspended for
    -- the whole life of the plugin, and maki/GC can panic on that state
    -- ("Luau VM is suspended while GC is running"). A one-shot task per burst
    -- of work has no idle suspended coroutine.
    if not scheduler_running then
      spawn(function()
        pcall(runtime.run_pending)
      end)
    end
  end

  -- Failure policy -----------------------------------------------------------

  -- Attempts already spent on each task's current failure streak. The journal
  -- zeroes `failure.attempts` when a task moves back to `running` (a human
  -- retry must get a fresh budget), so an automatic retry has to remember its
  -- own count across that move: without it the bound would never be reached and
  -- a transient failure would loop forever.
  retry_attempts = {}

  -- The failure text the result itself carries. A result with no `error` is not
  -- a task without a cause: a conflict names its files, base and command, an
  -- escalated review names its rounds, and the last journaled note names what
  -- the step was doing. Build the message from that, in that order, so a failure
  -- is never journaled as a mute "no error details".
  --
  -- Returns nil when the result really carries nothing: that is a defect of the
  -- runtime (see `handle_failure`), not a failure of the task.
  local function synthesize_failure(result, task, phase)
    result = type(result) == "table" and result or {}
    phase = is_non_empty(phase) and phase or "unknown phase"

    local function text(value)
      if type(value) ~= "string" then
        return nil
      end
      local line = one_line(value, 300)
      return line ~= "" and line or nil
    end

    local failure = type(result.failure) == "table" and result.failure or nil
    local direct = text(result.error) or text(result.reason)
      or text(failure and failure.message)
    if direct then
      return direct
    end

    -- The conflict facts, in the shape the journal note already uses: the files
    -- the branch could not replay, the base it was replayed on and the command.
    local files = result.conflict_files or result.conflict
    if type(files) == "table" then
      local names = {}
      for _, name in ipairs(files) do
        names[#names + 1] = tostring(name)
      end
      files = table.concat(names, ", ")
    end
    if is_non_empty(files) then
      local base = is_non_empty(result.conflict_base) and result.conflict_base
        or (is_non_empty(result.base) and result.base
        or ("origin/" .. tostring(is_non_empty(result.base_ref) and result.base_ref or "main")))
      local command = is_non_empty(result.rebase_command) and result.rebase_command
        or (is_non_empty(result.command) and result.command or ("git rebase " .. base))
      return string.format("conflict in phase %s: files %s, base %s, command %s",
        phase, files, base, command)
    end

    if result.escalated then
      local review = type(result.review) == "table" and result.review or nil
      local round = tonumber(review and review.round) or tonumber(result.round)
      return string.format("review escalated after %s round(s)",
        round and tostring(round) or "?")
    end

    -- Nothing typed: the last journaled note is what the step was doing when it
    -- gave up, and it is more informative than any generic string.
    local notes = type(task) == "table" and task.notes or nil
    if type(notes) == "table" then
      for i = #notes, 1, -1 do
        local note = text(notes[i])
        if note then
          return note
        end
      end
    end
    return nil
  end

  -- Persist a typed failure and decide what happens next. Nothing is
  -- destroyed: the worktree, the branch, the checkpoints and the run directory
  -- stay exactly where the failure found them, and the pull request is left
  -- open so a retry resumes the same work instead of redoing it from scratch.
  --
  -- A transient cause is retried without waking a human: `schedule_retry`
  -- enqueues a spawn after the policy's backoff, bounded by `max_attempts`.
  -- Only a cause a retry cannot fix (auth, an unknown cause, a conflict, red
  -- checks, an exhausted budget) escalates, with a text that names both the
  -- cause and the remedy.
  local function handle_failure(opts, paths, cfg, runner, session, task_id, err, result)
    local recover = recover_module()
    local loaded = deps.state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[task_id]
    local prior = task and task.failure
    local phase = (type(result) == "table" and result.phase)
      or (type(prior) == "table" and prior.phase)
      or (task and task.phase)
      or "implement"
    local diagnosis = type(result) == "table" and result.diagnosis or nil

    -- `err` is only usable when it is text: `run_and_handle` falls back to the
    -- result table itself, and `tostring` on it yields "table: 0x…", which would
    -- be journaled as the reason. Synthesize from the result instead.
    local raw = type(err) == "string" and one_line(err, 300) or ""
    local message = raw ~= "" and raw or synthesize_failure(result, task, phase)
    local empty_failure = message == nil
    if empty_failure then
      -- A result nothing can be said about is a runtime defect, and the journal
      -- must say so: a silent task failure hides the bug that produced it.
      message = "runtime returned an empty failure in phase " .. tostring(phase)
      local defect = "runtime defect: " .. message
      log(paths, "task " .. tostring(task_id) .. ": " .. defect)
      if type(deps.state.append) == "function" then
        pcall(deps.state.append, paths.root, {
          kind = "note",
          task_id = task_id,
          text = defect,
        })
      end
    end

    -- A transition the journal refused inside the runtime is a defect in the
    -- runtime's sequencing, not a fault of the task: another pilot already moved
    -- the task on. Failing the task for it would condemn work that is very
    -- likely in progress elsewhere. Journal it as a note, leave the status and
    -- the failure fields alone, and hand the caller a non-failing result.
    if is_illegal_transition(raw) then
      local text = "illegal transition reconciled: " .. raw
      log(paths, "task " .. tostring(task_id) .. ": " .. text)
      if type(deps.state.append) == "function" then
        pcall(deps.state.append, paths.root, {
          kind = "note",
          task_id = task_id,
          text = text,
        })
      end
      return {
        ok = true,
        reconciled = true,
        reason = message,
        phase = phase,
        decision = { action = "none", delay_secs = 0, max_attempts = 1, phase = phase },
      }
    end

    -- The context the classifier needs to describe an empty error: the phase,
    -- the task and the status it was in, the reason the result already carries
    -- (the synthesized message otherwise) and the last journaled note. Without
    -- it, a typed classifier can only answer "no error details".
    local result_reason = type(result) == "table" and result.reason or nil
    local notes = type(task) == "table" and type(task.notes) == "table" and task.notes or nil
    local last_note = notes and notes[#notes] or nil

    local ropts = recover_opts(cfg)
    ropts.phase = phase
    ropts.task_id = task_id
    ropts.status = type(task) == "table" and task.status or nil
    ropts.reason = is_non_empty(result_reason) and result_reason or message
    ropts.note = is_non_empty(last_note) and last_note or nil
    ropts.now = type(opts) == "table" and tonumber(opts.now) or nil

    -- Count the attempt from the streak, not from the task: the `running`
    -- transition on the way in has just zeroed the persisted counter.
    local streak = retry_attempts[task_id]
    if streak == nil then
      streak = tonumber(type(prior) == "table" and prior.attempts) or 0
    end
    local attempt_prior = { attempts = streak, phase = phase }

    local failure
    local decision
    if recover and type(recover.record) == "function" then
      failure = recover.record(message, attempt_prior, ropts)
      failure = typed_failure(failure, diagnosis, ropts)
      if type(recover.decide) == "function" then
        decision = recover.decide(failure, ropts)
      end
    end
    if type(failure) ~= "table" then
      -- Without the policy module the task still gets a readable record, so the
      -- journal and the panel never lose the reason it stopped.
      failure = {
        cause = "unknown",
        message = message:gsub("%s+", " "):sub(1, 300),
        remedy = "inspect the transcript and the worktree, then retry.",
        transient = false,
        attempts = streak + 1,
        at = os.time(),
        phase = phase,
      }
    end
    if type(decision) ~= "table" then
      decision = { action = "human", delay_secs = 0, max_attempts = 1, phase = phase }
    end
    -- One `failed` transition per turn. A module may already have written it —
    -- `review.escalate`, a merge that gave up — and that module is the
    -- authority: a second transition would add a reasonless event and split the
    -- diagnosis between two journal lines. Re-read the projection and, when the
    -- task is already failed, adopt the reason it persisted so the journal, the
    -- log and `failure_reason` carry exactly the same string.
    local current = deps.state.load(paths.root)
    local now = current and current.tasks and current.tasks[task_id]
    local already_failed = type(now) == "table" and now.status == "failed"
    local reason
    if already_failed then
      -- The typed diagnosis is persisted in both branches: it does not move the
      -- task, and a module-initiated failure that writes neither a reason nor a
      -- failure record would otherwise leave `task.failure` missing, which is
      -- what the panel and a resume (`state.failure_of`) read.
      if is_non_empty(now.failure_reason) then
        reason = now.failure_reason
        pcall(deps.state.set_fields, paths.root, task_id, { failure = failure })
      else
        -- The module wrote the transition without a reason (`review.escalate`
        -- and `merge` both do). The journal event stays as the module wrote it,
        -- but persist the synthesized reason beside it so the projection, the
        -- log and the panel agree instead of showing a mute `failed`.
        reason = describe_failure(failure, decision)
        pcall(deps.state.set_fields, paths.root, task_id, {
          failure = failure,
          failure_reason = reason,
        })
      end
    else
      reason = describe_failure(failure, decision)
      pcall(deps.state.set_fields, paths.root, task_id, { failure = failure })
      if type(deps.state.transition) == "function" then
        local moved, merr = deps.state.transition(paths.root, task_id, "failed", {
          reason = reason,
          failure = failure,
          phase = phase,
        })
        if not moved then
          log(paths, "cannot mark task " .. tostring(task_id) .. " failed: " .. tostring(merr))
        end
      end
    end
    log(paths, "task " .. tostring(task_id) .. " failed: " .. reason)

    -- `none` is a benign cause ("nothing to commit"): redo the step, bounded
    -- like any other, instead of waking a human for a tree that is already at
    -- the requested state.
    local retry = decision.action == "auto_retry"
    if decision.action == "none" then
      local attempts = tonumber(failure.attempts) or 0
      local cap = tonumber(decision.max_attempts) or 1
      retry = attempts < cap
      if retry then
        decision.delay_secs = 0
      end
    end

    if retry and ropts.auto_retry ~= false and type(schedule_retry) == "function" then
      schedule_retry(opts, paths, cfg, runner, session, task_id, failure, decision)
      return { ok = false, failure = failure, decision = decision, retrying = true, reason = reason }
    end
    notify_failure(type(opts) == "table" and opts.ctx or nil, task_id, reason)
    return { ok = false, failure = failure, decision = decision, retrying = false, reason = reason }
  end

  -- The failure policy itself must never take a spawn down. A crash inside
  -- classification or persistence would feed no result, skip the re-drain and
  -- leave the task unhandled — the exact "drain stops" case this runtime is
  -- built to rule out. So every call goes through this guard.
  local function apply_failure(opts, paths, cfg, runner, session, task_id, err, result)
    local ok, handled = pcall(
      handle_failure, opts, paths, cfg, runner, session, task_id, err, result)
    if ok and type(handled) == "table" then
      return handled
    end
    local message = tostring(handled)
    log(paths, "task " .. tostring(task_id) .. ": failure policy crashed: " .. message)
    return {
      ok = false,
      error = message,
      reason = message,
      retrying = false,
      failure = {
        cause = "unknown",
        message = message,
        remedy = "inspect the transcript and the task state, then retry.",
        transient = false,
        attempts = 1,
        at = os.time(),
      },
      decision = { action = "human", delay_secs = 0, max_attempts = 1 },
    }
  end

  -- Enqueue one bounded re-dispatch of a task that failed transiently. The
  -- backoff comes from the policy; the retry itself is a plain scheduler job,
  -- so `run_pending` spawns it like any other dispatch and never blocks on it.
  schedule_retry = function(opts, paths, cfg, runner, session, task_id, failure, decision)
    local delay = tonumber(decision.delay_secs) or 0
    local phase = (type(failure) == "table" and failure.phase)
      or (type(decision) == "table" and decision.phase)
      or "implement"
    -- Remember the attempt across the `running` move that settles the journal.
    local attempt = tonumber(type(failure) == "table" and failure.attempts) or 1
    retry_attempts[task_id] = attempt
    local cause = tostring(type(failure) == "table" and failure.cause or "transient")
    local function job()
      -- One dispatch per failure: if a human retry, a `/reload` resume or an
      -- earlier scheduled job already moved the task back to `running`, this
      -- job has nothing to do. Without this guard, `running -> running` is a
      -- legal no-op and the same worktree would get two concurrent run_tasks.
      local loaded = deps.state.load(paths.root)
      local current = loaded and loaded.tasks and loaded.tasks[task_id]
      if current and current.status ~= "failed" then
        log(paths, "automatic retry of " .. tostring(task_id)
          .. " skipped: the task is no longer failed")
        return nil
      end
      -- A human retry parks a task as `failed` + `slot_wait` while the drain
      -- waits for a slot, so the status guard alone would let this delayed job
      -- through: it would move the task to `running` and spawn it directly,
      -- past `max_parallel`, while another task still holds the slot. The
      -- persisted wait means the drain owns the dispatch: this job must stand
      -- down, not race it.
      if current and current.slot_wait then
        log(paths, "automatic retry of " .. tostring(task_id)
          .. " skipped: the task is parked waiting for a free slot")
        return nil
      end
      -- `max_parallel` is the only bound, and this job is a second dispatch
      -- authority beside the drain's `tick`. Nothing above consults the cap, so
      -- without this check a deferred retry fires while another task holds the
      -- only slot and spawns beside it — the exact parallel-checks collision
      -- this change removes. When no slot is free the task is parked like a
      -- human retry (`slot_wait`, its reason, its timestamp; status and phase
      -- untouched) and the drain — which sees `slot_wait` as a candidate and
      -- moves the task to `running` through a legal path — dispatches it once a
      -- slot frees. The count is read and the `failed -> running` move made in
      -- one uninterrupted job step, so two jobs cannot both take the last slot.
      local tasks_now = loaded and loaded.tasks or {}
      local in_flight, cap, free = slot_counts(tasks_now, max_parallel_of(cfg), task_id)
      if free <= 0 then
        local reason = wait_slot_reason()
        local marked, werr = mark_slot_wait(paths, task_id, reason)
        if not marked then
          log(paths, "automatic retry of " .. tostring(task_id)
            .. " cannot be queued: " .. tostring(werr))
          return nil
        end
        log(paths, string.format(
          "task %s: automatic retry parked (%s: %d in flight, max_parallel %d)",
          tostring(task_id), reason, in_flight, cap))
        -- The persisted wait is the dispatch ticket: arm the drain, the single
        -- authority that starts a parked task.
        schedule_job(opts, paths, cfg, runner, session)
        return nil
      end
      -- An automatic retry calls `run_and_handle` from this scheduler job, not
      -- through `dispatch_one`, so it owns no spawn handle. Register one anyway:
      -- a mid-session resume reads `task_handles` to tell a live task from an
      -- interrupted one, and a live retry mistaken for interrupted would be
      -- parked `slot_wait`, dropped out of the in-flight count and re-dispatched
      -- on the same worktree — the duplicate-run/collision class this fixes.
      -- The marker carries no `cancel`: it only proves the task is live.
      local marker = { automatic_retry = true }
      task_handles[task_id] = marker
      -- The legal `failed -> running` edge is the resume: it also settles the
      -- attempt deadline so the next failure counts from this attempt. The
      -- dispatch also clears any residual wait atomically with the move.
      local moved, merr = deps.state.transition(paths.root, task_id, "running", {
        phase = phase,
        fields = { slot_wait = false },
      })
      if not moved then
        if task_handles[task_id] == marker then
          task_handles[task_id] = nil
        end
        log(paths, "automatic retry of " .. tostring(task_id) .. " refused: " .. tostring(merr))
        return nil
      end
      log(paths, string.format("task %s: automatic retry (attempt %s/%s) after a %s failure",
        tostring(task_id), tostring(attempt),
        tostring(type(decision) == "table" and decision.max_attempts or "?"), cause))
      local ran, result = pcall(run_and_handle, opts, paths, cfg, runner, session, task_id)
      if task_handles[task_id] == marker then
        task_handles[task_id] = nil
      end
      if not ran then
        -- `run_and_handle` guards its own failures; re-raise anything it let
        -- through so `run_pending` logs it instead of losing it.
        error(result, 0)
      end
      return result
    end

    local function enqueue()
      scheduler_extra[#scheduler_extra + 1] = job
      schedule_job(opts, paths, cfg, runner, session)
      return true
    end

    if delay > 0 then
      local armed = later(enqueue, delay * 1000)
      if armed then
        log(paths, string.format("task %s: retry scheduled in %ds", tostring(task_id), delay))
        return true
      end
    end
    return enqueue()
  end

  -- The typed failure record returned by `handle_failure` is what the
  -- background record (and `results`) must expose: consumers there need the
  -- diagnosis and the resume action, not only the raw step error. The step's
  -- own fields (`ok`, `error`, `phase`, ...) are kept so existing callers that
  -- read them keep working.
  local function with_failure(result, handled)
    if type(handled) ~= "table" then
      return result
    end
    local out = type(result) == "table" and result or { ok = false }
    if handled.reconciled then
      -- The runtime reconciled its own defect: the dispatch is not a task
      -- failure, so the step's error must not survive on the result.
      out.ok = true
      out.reconciled = true
      out.error = nil
      out.failure = nil
      out.reason = handled.reason or out.reason
      return out
    end
    out.ok = false
    out.failure = handled.failure or out.failure
    out.decision = handled.decision or out.decision
    out.retrying = handled.retrying
    out.reason = handled.reason or out.reason
    if out.error == nil then
      out.error = handled.reason or handled.error
    end
    return out
  end

  -- One dispatch of one task with the failure policy attached. Every entry
  -- point — the scheduler, a human retry, a resume after reload, an automatic
  -- retry — goes through here, so a failure is always typed, always persisted
  -- and always either retried or escalated.
  run_and_handle = function(opts, paths, cfg, runner, session, task_id)
    local ok, result = pcall(run_task, opts, task_id, paths, cfg, runner, session)
    if not ok then
      -- A crash is a failure like any other: nothing raised here reaches the
      -- drain, and the task keeps the artefacts a retry resumes from.
      local failed = { ok = false, error = tostring(result) }
      failed = with_failure(failed,
        apply_failure(opts, paths, cfg, runner, session, task_id, failed.error, failed))
      runtime.last_background = failed
      return failed
    end
    -- A conflict is no longer relaunched here: replaying `run_task` would call
    -- the merge again on the same base and hit the same conflict, which is the
    -- loop this replaces. The repair is `run_task`'s own bounded cycle (back to
    -- implement with the conflict facts), so whatever it returns is final.
    if type(result) ~= "table" then
      result = { ok = false, error = tostring(result) }
    end
    if result.ok then
      -- The streak is over: the next failure, if any, starts from attempt one.
      retry_attempts[task_id] = nil
      runtime.last_background = result
      return result
    end
    local err = result.error or result.reason or result
    result = with_failure(result,
      apply_failure(opts, paths, cfg, runner, session, task_id, err, result))
    runtime.last_background = result
    return result
  end

  function runtime.has_pending()
    return (scheduler_dirty or #scheduler_extra > 0) and not scheduler_running
  end

  function runtime.run_pending()
    if scheduler_running or not scheduler_job then
      return
    end
    scheduler_running = true
    local job = scheduler_job
    -- Set when the last pass left a task quarantined: a clean pass must be
    -- reached without a new submit, so one more pass is armed once the drain has
    -- released `scheduler_running` (arming from inside it would be a no-op).
    local requeue_quarantine = false
    local ok, err = pcall(function()
      while #scheduler_extra > 0 or scheduler_dirty do
        while #scheduler_extra > 0 do
          local extra = table.remove(scheduler_extra, 1)
          -- A retry or a resume is a run_task like any other: it runs in its
          -- own spawn, so a queue of them can never hold the drain. The loop
          -- keeps draining while the tasks are still in flight. The job's
          -- completion re-drains like a dispatched task does: in production the
          -- spawn is asynchronous, so `run_pending` has long returned and
          -- nothing else would notice that the task moved and freed a slot.
          spawn(function()
            local called, result = pcall(extra)
            if not called then
              log(job.paths, "retry job error: " .. tostring(result))
            end
            redrain()
            return result
          end)
        end
        if scheduler_dirty then
          scheduler_dirty = false
          runtime.last_background = after_questions(
            job.opts, job.paths, job.cfg, job.runner, job.session)
          if has_quarantined_tasks(job.paths) then
            requeue_quarantine = true
          else
            -- The queue is clean again: the next quarantine starts its backoff
            -- from the short delay.
            quarantine_passes = 0
          end
        end
      end
    end)
    scheduler_running = false
    if not ok then
      log(job.paths, "background scheduler error: " .. tostring(err))
    end
    -- Re-analyse a still-quarantined batch until a pass finds it clean, with no
    -- new submit needed: the fingerprint cache makes an unchanged pass free.
    if requeue_quarantine then
      arm_quarantine_pass()
    end
  end

  local function drive(opts)
    local cfg, cerr, paths = load_config(opts)
    if not cfg then
      return { ok = false, error = cerr }
    end

    local runner, session, script, perr = prepare(opts, cfg, paths)
    if not runner then
      return { ok = false, error = perr }
    end

    -- Fast lane. A short, unambiguous intention does not need a qualifier
    -- session: the qualifier's only jobs here would be to restate the ask and
    -- invent files/checks, and both are guesses the implementer can make
    -- better once it has the worktree. Create one task with no declared files
    -- (the implementer picks the minimal set) and the project's default checks,
    -- then let the normal scheduler run implement -> checks -> converge ->
    -- review -> PR -> merge. `analyze` is skipped for free: its gate only
    -- selects `qualifying` tasks, and this task goes straight to `ready`.
    local function short_intention(text)
      if type(text) ~= "string" then
        return false
      end
      local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed == "" or trimmed:find("?", 1, true) then
        return false
      end
      -- More than one sentence is a sign the ask needs decomposing.
      if trimmed:find("%.%s+%S") then
        return false
      end
      local words = 0
      for _ in trimmed:gmatch("%S+") do
        words = words + 1
      end
      return words <= 25
    end

    -- Both lanes read `origin/<base>`, never the local checkout: the fast lane
    -- to infer the files the intention names, the qualifier to describe the
    -- tree the worktree will be cut from. Fetch once, here.
    if deps.git and type(deps.git.fetch) == "function" then
      deps.git.fetch(paths.repo, "origin")
    end
    local base_ref_name = "origin/" .. tostring(cfg.project.base_ref)

    -- One intention that qualifies into several tasks must not merge them
    -- straight into the project base. They land on an epic branch instead, and
    -- a single epic task owns the PR from that branch to the base. The branch
    -- is created from the fresh base and pushed before the tasks exist, so
    -- every subtask worktree can be cut from it. `branch_create` reuses an
    -- existing branch rather than resetting it: a resumed submit must not lose
    -- the subtasks already merged into the epic.
    local function ensure_epic_branch(first_id, intention)
      local git = deps.git
      if type(git) ~= "table" or type(git.branch_create) ~= "function"
        or type(git.push_branch) ~= "function" then
        return nil, "the git module cannot create the epic branch"
      end
      -- Name the branch after the request, not after the checkout directory:
      -- `metronome/epic/refonte-du-login-002c` reads like the work it holds.
      local slug = type(deps.implement.slug) == "function"
        and deps.implement.slug(intention, 40) or ""
      if slug == "" then
        slug = "epic"
      end
      local suffix = tostring(first_id):match("([0-9a-f]+)$") or tostring(first_id)
      local name = string.format("metronome/epic/%s-%s", slug, suffix)
      local created, cerr = git.branch_create(paths.repo, name, base_ref_name)
      if not created then
        return nil, "cannot create the epic branch: " .. tostring(cerr)
      end
      local pushed, perr = git.push_branch(paths.repo, name)
      if not pushed then
        return nil, "cannot push the epic branch: " .. tostring(perr)
      end
      return { branch = name, base = cfg.project.base_ref }
    end

    -- `fast = false` explicitly forces the qualifier, which is what the
    -- contract tests use; `fast = true` forces the fast lane; nil lets the
    -- short-intention heuristic decide.
    if opts.fast == true or (opts.fast ~= false and short_intention(opts.intention)) then
      local date = os.date("!%Y%m%d")
      local default_checks = (cfg.checks and cfg.checks.default) or {}
      -- The fast lane has no sheet, but the intention may name a file. Reading
      -- that name back is deterministic, and a declared file is what lets the
      -- scheduler prove two tasks disjoint: without it the task runs alone.
      local declared = {}
      if type(deps.qualify.infer_files) == "function"
        and deps.git and type(deps.git.ls_tree) == "function" then
        local listed = deps.git.ls_tree(paths.repo, base_ref_name)
        if type(listed) == "table" then
          declared = deps.qualify.infer_files(opts.intention, listed)
        end
      end
      local applied, apply_err = with_id_gate(function()
        local first_id = deps.qualify.next_id(deps.state.load(paths.root), date)
        local first_hex = tonumber(first_id:match("([0-9a-f]+)$") or "", 16) or 1
        return deps.qualify.apply(deps.state, paths.root, {
          ok = true,
          tasks = { {
            title = opts.intention,
            intent = opts.intention,
            origin = opts.intention,
            files = declared,
            checks = default_checks,
          } },
        }, {
          tasks_dir = paths.tasks,
          id_factory = function(index)
            return string.format("T-%s-%04x", date, first_hex + index - 1)
          end,
        })
      end)
      if not applied then
        return { ok = false, error = apply_err }
      end
      schedule_job({ ctx = background_ctx(opts.ctx) }, paths, cfg, runner, session)
      return { ok = true, background = true, fast = true, tasks = applied.tasks }
    end

    local gate = qualifier_gate(cfg.project and cfg.project.max_parallel_qualifiers)
    local permit = gate and gate:acquire() or nil
    local run_ok, qualified = pcall(deps.qualify.run, {
      intention = opts.intention,
      runner = runner,
      session_opts = session.qualifier,
      repo = paths.repo,
      ref = base_ref_name,
      git = deps.git,
      task_id = next_qualify_key(),
      validate = false,
      state_root = paths.runs,
      ctx = opts.ctx,
    })
    if permit then
      permit:release()
    end
    if not run_ok then
      return { ok = false, error = tostring(qualified) }
    end
    if not qualified.ok then
      return qualified
    end

    local date = os.date("!%Y%m%d")
    local applied, apply_err = with_id_gate(function()
      local first_id = deps.qualify.next_id(deps.state.load(paths.root), date)
      local first_hex = tonumber(first_id:match("([0-9a-f]+)$"), 16) or 1
      -- Several tasks from one intention: they go through an epic branch. A
      -- single task keeps the old behaviour and merges into the project base.
      local epic = nil
      if #(qualified.tasks or {}) > 1 then
        local eerr
        epic, eerr = ensure_epic_branch(first_id, opts.intention)
        if not epic then
          return nil, eerr
        end
      end
      return deps.qualify.apply(deps.state, paths.root, qualified, {
        tasks_dir = paths.tasks,
        id_factory = function(index)
          return string.format("T-%s-%04x", date, first_hex + index - 1)
        end,
        epic = epic,
      })
    end)
    if not applied then
      return { ok = false, error = apply_err }
    end

    -- The qualifier names dependencies by id, « T<n> » batch position, bare
    -- batch position or task title; the state stores ids. Remap every applied
    -- task, scripted or real, so the analysis gate does not see a position or
    -- a title where it expects an id. Resolution precedence is: exact id of an
    -- applied task, then « T<n> », then a bare index, then the title. Unknown
    -- references stay verbatim so the gate blocks them.
    local applied_list = applied.tasks or {}
    local ids_by_title = {}
    local ids_by_index = {}
    local ids_by_t = {}
    for index, task in ipairs(applied_list) do
      ids_by_title[task.title] = task.id
      ids_by_index[tostring(index)] = task.id
      ids_by_t["T" .. index] = task.id
    end
    local applied_id = {}
    for _, task in ipairs(applied_list) do
      applied_id[task.id] = true
    end
    for _, task in ipairs(applied_list) do
      local depends = task.depends_on
      if type(depends) == "table" and #depends > 0 then
        local ids = {}
        for _, dep in ipairs(depends) do
          if applied_id[dep] then
            ids[#ids + 1] = dep
          else
            ids[#ids + 1] = ids_by_t[dep] or ids_by_index[dep] or ids_by_title[dep] or dep
          end
        end
        local changed = #ids ~= #depends
        if not changed then
          for i, dep in ipairs(depends) do
            if ids[i] ~= dep then
              changed = true
              break
            end
          end
        end
        if changed then
          deps.state.set_fields(paths.root, task.id, { depends_on = ids })
        end
      end
    end

    local round = deps.questions.round(deps.state, paths.root)
    -- Only the questions raised by the tasks this submit just qualified block
    -- it. A question still open on an older task must not stop a new, clean
    -- intention from starting: the user asked to enqueue demands at any time.
    local applied_ids = {}
    for _, task in ipairs(applied.tasks or {}) do
      applied_ids[task.id] = true
    end
    local own = {}
    for _, question in ipairs((round and round.questions) or {}) do
      for _, source in ipairs(question.sources or {}) do
        if applied_ids[source.task_id] then
          own[#own + 1] = question
          break
        end
      end
    end
    if #own > 0 then
      local answers = (script and script.answers) or opts.answers or {}
      if next(answers) ~= nil then
        deps.questions.answer(deps.state, paths.root, answers, {
          tasks_dir = paths.tasks,
          qualify = deps.qualify,
        })
      else
        return { ok = true, waiting_questions = own, tasks = applied.tasks }
      end
    end

    if script then
      -- The scripted e2e driver expects the whole run to finish before submit
      -- returns; only a real run goes to the background.
      return after_questions(opts, paths, cfg, runner, session)
    end
    schedule_job({ ctx = background_ctx(opts.ctx) }, paths, cfg, runner, session)
    return { ok = true, background = true, tasks = applied.tasks }
  end

  -- Public runtime methods --------------------------------------------------

  -- Bind a project. Without answers the call only returns the questions and
  -- writes nothing: the user must answer (`key=value`) or accept every default
  -- (`--defaults`). This is what stops `/metronome on` from guessing the
  -- models, the checks or the merge/deploy policy.
  function runtime.init(input)
    local paths = p()
    local current, current_err = current_answers(paths)
    if current_err then
      return { ok = false, error = "existing config is invalid: " .. current_err }
    end
    local asking = type(input) ~= "table"
      or input.ask
      or (not input.defaults and input.answers == nil and next(input) == nil)
    if asking then
      return {
        ok = false,
        error = "init needs answers: run /metronome init --defaults, or answer with /metronome init key=value ...",
        questions = init_questions(paths.repo, current),
        root = paths.root,
      }
    end

    local answers = normalize_init(input, paths, current)
    local refusal = preflight_refusal(answers)
    if refusal then
      return refusal
    end
    fs.mkdir(paths.root, { parents = true })
    fs.mkdir(paths.tasks, { parents = true })
    fs.mkdir(paths.worktrees, { parents = true })
    fs.mkdir(paths.runs, { parents = true })
    write_prompts(paths.prompts)
    fs.write(paths.config, render_config(answers))
    local cfg, errors = deps.config.load(paths.config)
    if not cfg then
      return { ok = false, error = table.concat(errors or { "invalid config" }, "; ") }
    end
    return {
      ok = true,
      root = paths.root,
      repo = paths.repo,
      config = paths.config,
      answers = answers,
      message = "Metronome bound to " .. paths.repo,
    }
  end

  function runtime.submit(input, ctx)
    local paths = p()
    if not fs.read(paths.config) then
      return { ok = false, error = "project is not bound; run /metronome init first" }
    end
    -- `complexity` is the caller's judgement, not a guess: `fast` skips the
    -- qualifier, `full` always qualifies, `auto` (or absent) lets the wording
    -- decide. `fast` stays accepted for the older callers and tests.
    local complexity = input.complexity
    local fast = input.fast
    if complexity == "fast" then
      fast = true
    elseif complexity == "full" then
      fast = false
    elseif complexity ~= nil and complexity ~= "auto" then
      return { ok = false, error = "unknown complexity: " .. tostring(complexity) }
    end
    local opts = {
      intention = input.intention,
      answers = input.answers,
      fast = fast,
      -- Qualify through a background ctx too: the qualifier is a role session,
      -- and a role session opened with the tool's LuaCtx is cancelled with the
      -- turn. `{ session = sid }` opens it as a background session instead.
      ctx = background_ctx(M.resolve_ctx(input, ctx)),
    }
    -- Default: wait for qualification and answer with the created tasks, so
    -- the agent never has to sleep-poll. The pipeline after qualification still
    -- runs in the background. `wait = false` returns at once with queued=true.
    if input.wait == false then
      local function job()
        local result
        local ok, err = pcall(function()
          result = drive(opts)
        end)
        if not ok then
          log(paths, "submit error: " .. tostring(err))
          result = { ok = false, error = tostring(err) }
        end
        runtime.last_submit = result
        if type(result) == "table" and type(result.waiting_questions) == "table"
          and #result.waiting_questions > 0 then
          ask_in_chat(opts.ctx, result.waiting_questions)
        end
        return result
      end
      spawn(job)
      return { ok = true, background = true, queued = true, intention = opts.intention }
    end

    local result
    local ok, err = pcall(function()
      result = drive(opts)
    end)
    if not ok then
      log(paths, "submit error: " .. tostring(err))
      return { ok = false, error = tostring(err) }
    end
    runtime.last_submit = result
    return result
  end

  -- The last stable sha a retry resumes from. The state module is the
  -- authority; the local copy only keeps `metronome_status` readable for a
  -- caller that injects a minimal state seam.
  local function status_checkpoint(task)
    if type(deps.state) == "table" and type(deps.state.checkpoint_of) == "function" then
      local ok, sha = pcall(deps.state.checkpoint_of, task)
      if ok and type(sha) == "string" and sha ~= "" then
        return sha
      end
    end
    local checkpoints = type(task) == "table" and task.checkpoints or nil
    local last = type(checkpoints) == "table" and checkpoints[#checkpoints] or nil
    if type(last) == "table" then
      last = last.sha
    end
    if type(last) == "string" and last ~= "" then
      return last
    end
    return nil
  end

  -- The transcript is the evidence a human reads after a failure: the run
  -- directory the runner wrote, or the newest `runs/<id>/<phase>/<attempt>`.
  -- Neither is guaranteed to exist (a task failed before its first turn), so a
  -- missing tree is nil, never an error.
  local function status_transcript(paths, task)
    local run_dir = type(task) == "table" and task.run_dir or nil
    if type(run_dir) == "string" and run_dir ~= "" then
      return run_dir
    end
    local base = fs.joinpath(paths.runs, tostring(task.id or ""))
    local phases = fs.dir(base)
    if not phases then
      return nil
    end
    local best, best_attempt, best_phase
    for _, phase in ipairs(phases) do
      local name = phase.name or phase[1]
      local kind = phase.kind or phase[2]
      if type(name) == "string" and kind == "directory" and name:sub(1, 1) ~= "." then
        local attempts = fs.dir(fs.joinpath(base, name))
        for _, attempt in ipairs(attempts or {}) do
          local aname = attempt.name or attempt[1]
          local akind = attempt.kind or attempt[2]
          local n = tonumber(aname)
          if akind == "directory" and n ~= nil then
            if best_attempt == nil or n > best_attempt
              or (n == best_attempt and name > (best_phase or "")) then
              best = fs.joinpath(base, name, aname)
              best_attempt = n
              best_phase = name
            end
          end
        end
      end
    end
    return best
  end

  -- The typed last error: the structured `failure` when the task carries one,
  -- otherwise the legacy `failure_reason` string that older journals wrote.
  -- Mapping the string through the classifier keeps the cause and the remedy
  -- readable, but the action stays `manual`: a legacy journal has no attempt
  -- accounting, so only a human can decide to resume it.
  local function status_last_error(task)
    local failure = type(task) == "table" and task.failure or nil
    if type(failure) == "table" and (failure.cause ~= nil or failure.message ~= nil) then
      return {
        cause = failure.cause or "unknown",
        message = failure.message,
        remedy = failure.remedy,
        transient = failure.transient == true,
        at = failure.at,
      }, failure
    end
    local reason = type(task) == "table" and task.failure_reason or nil
    if is_non_empty(reason) then
      local recover = recover_module()
      local diagnosis
      if recover and type(recover.classify) == "function" then
        local ok, classified = pcall(recover.classify, reason)
        if ok and type(classified) == "table" then
          diagnosis = classified
        end
      end
      return {
        cause = (diagnosis and diagnosis.cause) or "unknown",
        message = one_line(reason, 300),
        remedy = (diagnosis and diagnosis.remedy)
          or "inspect the transcript and the worktree, then retry with metronome_retry.",
        transient = diagnosis and diagnosis.transient == true or false,
        at = type(task) == "table" and task.failed_at or nil,
      }, nil
    end
    return nil, nil
  end

  -- The retry bounds the project configured, without loading the whole config
  -- path: `status` must stay a read-only projection and never rewrite prompts.
  local function status_recover_opts(paths)
    if type(deps.config) == "table" and type(deps.config.load) == "function" then
      local ok, cfg = pcall(deps.config.load, paths.config)
      if ok and type(cfg) == "table" then
        return recover_opts(cfg)
      end
    end
    return recover_opts(nil)
  end

  -- The project config, read the same way, for the numbers the status view
  -- reports (the slot cap). A project without a readable config falls back to
  -- the scheduler's own default.
  local function status_config(paths)
    if type(deps.config) == "table" and type(deps.config.load) == "function" then
      local ok, cfg = pcall(deps.config.load, paths.config)
      if ok and type(cfg) == "table" then
        return cfg
      end
    end
    return nil
  end

  local RETRY_TOOL = "metronome_retry"

  -- The bound the status reports when the project config left it at the
  -- policy's default. Step sheets are read by a human, so the number must be
  -- the one the scheduler would really use.
  local function retry_bound(opts)
    local configured = tonumber(type(opts) == "table" and opts.max_attempts)
    if configured then
      return configured
    end
    local recover = recover_module()
    return tonumber(recover and recover.DEFAULTS and recover.DEFAULTS.max_attempts) or 3
  end

  -- What a user can do next, in the vocabulary the panel and the agent share.
  -- `action` is the policy's own (`auto_retry`, `human`, `none`); a legacy
  -- journal without a structured failure yields `manual`.
  local function status_retry_action(task, opts)
    local last, failure = status_last_error(task)
    if not last then
      return { action = "none", attempts = 0, max_attempts = retry_bound(opts), tool = RETRY_TOOL }
    end
    if not failure then
      return {
        action = "manual",
        attempts = 0,
        max_attempts = retry_bound(opts),
        next_retry_at = nil,
        tool = RETRY_TOOL,
      }
    end
    local recover = recover_module()
    local decision
    if recover and type(recover.decide) == "function" then
      local ok, decided = pcall(recover.decide, failure, opts)
      if ok and type(decided) == "table" then
        decision = decided
      end
    end
    local action = decision and decision.action
      or (failure.transient and "auto_retry" or "human")
    -- `auto_retry = false` is the project saying a transient cause still needs
    -- a human; report that, not a retry the scheduler will not perform.
    if action == "auto_retry" and opts.auto_retry == false then
      action = "human"
    end
    return {
      action = action,
      attempts = tonumber(failure.attempts) or 0,
      max_attempts = (decision and tonumber(decision.max_attempts))
        or retry_bound(opts),
      next_retry_at = failure.next_retry_at,
      cause = failure.cause,
      tool = RETRY_TOOL,
    }
  end

  -- A normalised view of one task for the status tools. The raw fields are
  -- copied untouched, so an existing caller keeps reading them; the enriched
  -- fields are what the panel and the agent need to resume the task.
  --
  -- The two wait fields are a documented pair, not two spellings of one value:
  --   * `slot_wait_flag` — the persisted task flag (`true` while the task is
  --     parked, `nil` otherwise). This is the stable name for the boolean; the
  --     raw task data is copied into the view, but `view.slot_wait` is *not* it.
  --   * `slot_wait` — the live structured wait, `{ reason, in_flight,
  --     max_parallel }`, or `nil` when the cap leaves the task no reason to
  --     wait. A parked task whose slot is already free is a hand-off to the
  --     drain: `slot_wait_flag` is still `true` but `slot_wait` is `nil`, since
  --     reporting "0 in flight, max_parallel N" as a wait would contradict
  --     itself. A consumer that only needs "is it parked?" must read
  --     `slot_wait_flag`; one that wants to explain a wait reads `wait_reason`
  --     (dependency first, then the slot) or `slot_wait.reason`.
  local function status_view(paths, task, opts, projection, max_parallel)
    local view = {}
    for key, value in pairs(task) do
      view[key] = value
    end
    view.checkpoint = status_checkpoint(task)
    view.branch = type(task.branch) == "string" and task.branch ~= "" and task.branch or nil
    view.worktree = (type(task.worktree) == "string" and task.worktree ~= "" and task.worktree)
      or fs.joinpath(paths.worktrees, tostring(task.id or ""))
    view.transcript = status_transcript(paths, task)
    -- Why a queued task is not running, named for a human: an unmet dependency
    -- first, then the slot wait. Computed from the live projection, so no task
    -- field is persisted and the journal schema is untouched.
    local wait_reason, slot_wait = wait_reason_of(task, projection, max_parallel)
    -- The persisted boolean is raw task data: the structured wait below only
    -- reports a wait when the cap is actually full, so keep the raw flag
    -- readable under its own key. A parked task whose drain is still pending has
    -- `slot_wait = true` but no unmet cap — a caller must still be able to tell
    -- it apart from a task that is not waiting at all.
    view.slot_wait_flag = task.slot_wait and true or nil
    view.wait_reason = wait_reason
    view.slot_wait = slot_wait
    local last_error = status_last_error(task)
    view.last_error = last_error
    local retry = status_retry_action(task, opts)
    view.retry_action = retry
    -- Both spellings are exposed: the documented projection reads
    -- `retry_action`, older notes called the block `retry_actions`.
    local retry_alias = {}
    for key, value in pairs(retry) do
      retry_alias[key] = value
    end
    view.retry_actions = retry_alias
    -- The review budget is part of what a human needs to see: a task escalated
    -- at its last round shows 0 remaining, and the same task after a relaunch
    -- shows the full budget again. The raw `review` object is left untouched.
    local review = type(task.review) == "table" and task.review or nil
    if review then
      local round = tonumber(review.round)
      local max_rounds = tonumber(review.max_rounds)
      view.review_round = round
      view.review_max_rounds = max_rounds
      if round and max_rounds then
        view.review_rounds_remaining = math.max(0, math.floor(max_rounds) - math.floor(round))
      else
        view.review_rounds_remaining = nil
      end
    end
    return view
  end

  function runtime.status(input)
    local paths = p()
    local loaded, err = deps.state.load(paths.root)
    if not loaded then
      return { ok = false, error = err or "cannot load state" }
    end
    local opts = status_recover_opts(paths)
    -- The cap a queued task is waiting on: read from the config the way the
    -- drain reads it, so the status never contradicts the scheduler.
    local max_parallel = max_parallel_of(status_config(paths))
    local projection = loaded.tasks or {}
    if is_non_empty(input and input.id) then
      local task = loaded.tasks and loaded.tasks[input.id]
      if not task then
        return { ok = false, error = "unknown task: " .. input.id }
      end
      return { ok = true, task = status_view(paths, task, opts, projection, max_parallel) }
    end
    local tasks = {}
    local quarantined = {}
    for id, task in pairs(loaded.tasks or {}) do
      if type(task) == "table" then
        tasks[id] = status_view(paths, task, opts, projection, max_parallel)
        -- A top-level, sorted summary of what the analyzer set aside, so a
        -- freeze reads at a glance: the task id and its named rules. The raw
        -- quarantine object stays in the per-task view above.
        local q = task.quarantine
        if type(q) == "table" and next(q) ~= nil then
          local reasons = {}
          if type(q.rules) == "table" then
            for _, rule in ipairs(q.rules) do
              if is_non_empty(rule) then
                reasons[#reasons + 1] = trim(rule)
              end
            end
          end
          if #reasons == 0 and is_non_empty(q.reason) then
            reasons[1] = trim(q.reason)
          end
          table.sort(reasons)
          quarantined[#quarantined + 1] = { id = tostring(id), reasons = reasons }
        end
      else
        tasks[id] = task
      end
    end
    table.sort(quarantined, function(a, b)
      return tostring(a.id) < tostring(b.id)
    end)
    -- A ready task the scheduler would not start is otherwise invisible in the
    -- panel: name why it waits, next to the quarantine summary.
    local waiting = {}
    if deps.pipeline and type(deps.pipeline.ready_reasons) == "function" then
      local called, reasons = pcall(deps.pipeline.ready_reasons, loaded.tasks, {
        max_parallel = max_parallel,
      })
      if called and type(reasons) == "table" then
        waiting = reasons
        for _, entry in ipairs(waiting) do
          local view = tasks[entry.id]
          if type(view) == "table" then
            view.waiting_reason = entry.reason
          end
        end
      end
    end
    return { ok = true, tasks = tasks, events = loaded.events, quarantined = quarantined,
      waiting = waiting }
  end

  function runtime.answer(input, ctx)
    input = type(input) == "table" and input or {}
    local paths = p()
    local applied, err = deps.questions.answer(deps.state, paths.root, input.answers or {}, {
      tasks_dir = paths.tasks,
      qualify = deps.qualify,
    })
    if not applied then
      return { ok = false, error = err }
    end

    -- Answering is what unblocks the tasks: resume the pipeline here instead
    -- of leaving them in `qualifying` until the next submit.
    local cfg, cerr = load_config(nil)
    if not cfg then
      return { ok = false, error = cerr, applied = applied }
    end
    local opts = { ctx = M.resolve_ctx(input, ctx) }
    local runner, session, _, perr = prepare(opts, cfg, paths)
    if not runner then
      return { ok = false, error = perr, applied = applied }
    end
    schedule_job({ ctx = background_ctx(opts.ctx) }, paths, cfg, runner, session)
    return { ok = true, background = true, applied = applied }
  end

  -- Grant a relaunched review-escalated task a fresh review budget. The reset
  -- happens before the task crosses back to `running`, keeps the last round's
  -- findings as the implementer's feedback, and is journaled — the field patch
  -- plus a note naming the old round and the granted budget — so the relaunch
  -- stays auditable. Any other failure cause leaves the counter alone.
  local function reset_review_budget(paths, task)
    local recover = recover_module()
    if not recover or type(recover.review_budget_reset) ~= "function" then
      return nil
    end
    local ok, reset = pcall(recover.review_budget_reset, task)
    if not ok or type(reset) ~= "table" then
      return nil
    end
    -- Re-read immediately before the write: the budget belongs only to a task
    -- this pilot still owns, failed at the moment it is granted. Another actor
    -- may have moved it since the projection was read, and resetting the round
    -- of a task being reviewed elsewhere would be a phantom budget grant.
    local loaded = type(deps.state.load) == "function" and deps.state.load(paths.root) or nil
    local current = type(loaded) == "table" and loaded.tasks and loaded.tasks[task.id] or nil
    if not current or current.status ~= task.status then
      return nil, "task moved before its review budget could be reset"
    end
    local stored, serr = deps.state.set_fields(paths.root, task.id, { review = reset.review })
    if not stored then
      return nil, serr or "cannot reset the review round budget"
    end
    if type(deps.state.append) == "function" then
      local appended, aerr = pcall(deps.state.append, paths.root, {
        kind = "note",
        task_id = task.id,
        text = reset.note,
      })
      if not appended then
        return nil, aerr or "cannot journal the review round reset"
      end
    end
    return reset
  end

  function runtime.retry(input, ctx)
    input = type(input) == "table" and input or {}
    local paths = project_paths()
    local loaded = deps.state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[input.id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(input.id) }
    end
    if task.status ~= "failed" and task.status ~= "stalled" and task.status ~= "abandoned" then
      return { ok = false, error = "task is not failed, stalled or abandoned" }
    end
    -- A task escalated by its review keeps `review.round` at the budget, so a
    -- relaunch would escalate on its first round with no review run at all
    -- (T-20261122-0043). The budget is granted in the same gesture as the move
    -- back to `running`, before the task crosses over.
    local prior_review = type(task.review) == "table" and task.review or nil
    local review_reset, reset_err = reset_review_budget(paths, task)
    if reset_err then
      return { ok = false, error = reset_err }
    end
    -- The transition to `running` belongs to the drain, which is the single
    -- dispatch authority: a retry only parks the task with `slot_wait` and keeps
    -- its original status and phase. The review budget is still granted here,
    -- in the same gesture, so the first review of the relaunch gets a full
    -- budget; if parking fails it is rolled back below.
    -- A human retry is a fresh start: the attempt budget starts again from
    -- zero, so the automatic policy can act on the next failure instead of
    -- seeing a budget the user just reset as already spent.
    retry_attempts[input.id] = nil
    local prior = type(task.failure) == "table" and task.failure or nil
    if prior and type(deps.state.set_fields) == "function" then
      local reset = {}
      for key, value in pairs(prior) do
        reset[key] = value
      end
      reset.attempts = 0
      reset.next_retry_at = nil
      pcall(deps.state.set_fields, paths.root, input.id, { failure = reset })
    end

    local cfg, cerr = load_config(nil)
    if not cfg then
      return { ok = false, error = cerr }
    end
    local opts = { ctx = M.resolve_ctx(input, ctx) }
    local runner, session, _, perr = prepare(opts, cfg, paths)
    if not runner then
      return { ok = false, error = perr }
    end
    local bg = { ctx = background_ctx(opts.ctx) }
    pcall(function()
      maki.log.info("metronome retry bg in=" .. type(opts.ctx) .. " out=" .. type(bg.ctx))
    end)

    -- A retry is a restart, not just a status move — but it never starts the
    -- task on its own authority. `max_parallel` is the only bound, and only
    -- the drain enforces it: the task is parked with the persisted `slot_wait`
    -- flag (keeping its original status and phase, so a task interrupted in
    -- `reviewing` stays `reviewing`) and `pipeline.tick` dispatches it when a
    -- slot is free. The tick moves a task to `running` before spawning it, so
    -- admission is atomic by construction: two simultaneous retries cannot both
    -- take the last slot, because the second one sees the first already in
    -- flight.
    local max_parallel = max_parallel_of(cfg)
    local current = deps.state.load(paths.root)
    local in_flight, cap, free = slot_counts(current and current.tasks or {},
      max_parallel, input.id)
    local waiting = free <= 0
    local reason = waiting and wait_slot_reason() or REQUEUE_FOR_DISPATCH
    local marked, merr = mark_slot_wait(paths, input.id, reason)
    if not marked then
      -- The task was never parked, so it will not be relaunched: undo the
      -- review budget grant rather than leave a grant that never corresponded
      -- to a relaunch, and journal the rollback.
      if review_reset and prior_review then
        pcall(deps.state.set_fields, paths.root, input.id, { review = prior_review })
        if type(deps.state.append) == "function" then
          pcall(deps.state.append, paths.root, {
            kind = "note",
            task_id = input.id,
            text = "review budget reset rolled back: the task was never parked for dispatch",
          })
        end
      end
      return { ok = false, error = merr }
    end
    log(paths, string.format("task %s: queued for dispatch (%s)", tostring(input.id), reason))
    -- Arm the drain: `pipeline.tick` is the single dispatch authority, so even
    -- a retry that hangs cannot hold it, and no worktree is run twice.
    schedule_job(bg, paths, cfg, runner, session)
    local after = deps.state.load(paths.root)
    local queued = after and after.tasks and after.tasks[input.id] or nil
    return {
      ok = true,
      background = true,
      requeued = true,
      waiting = waiting or nil,
      wait_reason = waiting and reason or nil,
      slot_wait = waiting and {
        reason = reason,
        in_flight = in_flight,
        max_parallel = cap,
      } or nil,
      task = queued,
    }
  end

  -- Statuses a task can be stopped from: it is doing something, and stopping it
  -- is a decision, not a cleanup.
  local STOPPABLE = {
    running = true,
    verifying = true,
    reviewing = true,
    merging = true,
    deploying = true,
  }

  -- A dead task leaves two kinds of GitHub debris: the PR the pipeline
  -- attached to the task, which `close_open_pr` closes, and a PR the gate
  -- opened without ever attaching it, which is only visible by branch name.
  -- Prune is the reconciler that closes the second kind and deletes both
  -- branches. It runs after every abandon/stop, best effort: the task is
  -- already dead, and a GitHub failure must not turn that decision into an
  -- error.
  local function prune_dead_task()
    local called, result = pcall(runtime.prune, {})
    if not called then
      return { ok = false, error = tostring(result) }
    end
    return result
  end

  -- Stop an in-flight task: cancel its spawn (which ends the role session it
  -- opened) and park it as `abandoned` with a reason the journal keeps. A
  -- stopped task is restartable with `retry`.
  function runtime.stop(input)
    input = type(input) == "table" and input or {}
    local paths = project_paths()
    local loaded = deps.state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[input.id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(input.id) }
    end
    if not STOPPABLE[task.status] then
      return { ok = false, error = "task is not running: " .. tostring(task.status) }
    end
    local handle = task_handles[input.id]
    if handle and type(handle.cancel) == "function" then
      pcall(handle.cancel, handle)
    end
    task_handles[input.id] = nil
    close_open_pr(paths, input.id)
    local moved, err = deps.state.transition(paths.root, input.id, "abandoned", {
      reason = "stopped by the user",
    })
    if not moved then
      return { ok = false, error = err }
    end
    return { ok = true, task = moved, stopped = true, prune = prune_dead_task() }
  end

  function runtime.abandon(input)
    local paths = project_paths()
    close_open_pr(paths, input.id)
    local moved, err = deps.state.transition(paths.root, input.id, "abandoned", { reason = "abandoned by the user" })
    if not moved then
      return { ok = false, error = err }
    end
    return { ok = true, task = moved, prune = prune_dead_task() }
  end

  function runtime.delete(input)
    local paths = project_paths()
    if type(deps.state.delete) ~= "function" then
      return { ok = false, error = "state.delete is not wired" }
    end
    local loaded = deps.state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[input.id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(input.id) }
    end
    -- Archive first: the snapshot must exist even if the journal is pruned
    -- later, and it must not depend on the slow network cleanup below.
    local archived = nil
    if type(deps.state.archive) == "function" then
      local sheet = nil
      if is_non_empty(paths.tasks) then
        sheet = fs.read(fs.joinpath(paths.tasks, task.id .. ".md"))
      end
      local path = deps.state.archive(paths.root, task, { sheet = sheet })
      archived = path
    end
    -- Hide the task now. The panel reads the projection, so it updates as
    -- soon as this returns, without waiting for GitHub.
    local ok, err = deps.state.delete(paths.root, input.id)
    if not ok then
      return { ok = false, error = err }
    end
    -- The slow part is the network: closing the PR and deleting the remote
    -- branch. It runs off the caller's turn; if it fails, the journal already
    -- says the task is gone and `prune` repairs the leftover.
    local branch = type(task.branch) == "string" and task.branch or nil
    local pr = type(task.pr) == "table" and task.pr or nil
    spawn(function()
      if pr and pr.state == "open" and type(deps.git.pr_close) == "function" then
        pcall(deps.git.pr_close, pr.number or pr.url, { gh = "gh" })
      end
      if is_non_empty(branch) and type(deps.git.delete_branch) == "function" then
        pcall(deps.git.delete_branch, paths.repo, branch, { remote = "origin" })
      end
    end)
    return { ok = true, deleted = input.id, archived = archived }
  end

  -- The archive a delete leaves behind: a self-contained snapshot per task,
  -- readable without replaying the journal.
  function runtime.archive(input)
    local paths = project_paths()
    if type(deps.state.archived) ~= "function" then
      return { ok = false, error = "state.archived is not wired" }
    end
    local list = deps.state.archived(paths.root)
    return { ok = true, archived = list, count = #list }
  end

  -- Reconcile GitHub with the journal: an open PR or a remote branch whose
  -- task is not alive is an orphan. Prevention (closing on failure/stop) only
  -- covers what happens after it ships; this repairs what is already there.
  --
  -- Live means the task can still reach a merge: ready, qualifying,
  -- awaiting_answers, running, verifying, reviewing, changes_requested,
  -- pr_open, merging, deploying. A failed, abandoned or deleted task is not.
  local LIVE = {
    ready = true,
    qualifying = true,
    awaiting_answers = true,
    running = true,
    verifying = true,
    reviewing = true,
    changes_requested = true,
    pr_open = true,
    merging = true,
    deploying = true,
  }

  function runtime.prune(_input)
    local paths = project_paths()
    local cfg, cerr = load_config(nil)
    if not cfg then
      return { ok = false, error = cerr }
    end
    if type(deps.git.list_open_prs) ~= "function"
      or type(deps.git.list_branches) ~= "function" then
      return { ok = false, error = "git module cannot list PRs or branches" }
    end

    local loaded = deps.state.load(paths.root) or { tasks = {} }
    local live_branches = {}
    for _, task in pairs(loaded.tasks or {}) do
      if LIVE[task.status] and type(task.branch) == "string" then
        live_branches[task.branch] = task.id
      end
    end

    local prefix = (cfg.git and cfg.git.branch_prefix) or "metronome/"
    local closed, deleted, kept, errors = {}, {}, {}, {}

    local prs, perr = deps.git.list_open_prs({ repo = paths.repo, gh = "gh" })
    if not prs then
      return { ok = false, error = perr }
    end
    local pr_branches = {}
    for _, pr in ipairs(prs) do
      local head = tostring(pr.head or "")
      if head:sub(1, #prefix) == prefix then
        pr_branches[head] = true
        if live_branches[head] then
          kept[#kept + 1] = { number = pr.number, branch = head, task = live_branches[head] }
        else
          local ok = pcall(deps.git.pr_close, pr.number, { gh = "gh", worktree = paths.repo })
          if ok then
            closed[#closed + 1] = { number = pr.number, branch = head }
            -- A closed PR leaves a branch nobody will read: drop it too.
            if type(deps.git.delete_branch) == "function" then
              pcall(deps.git.delete_branch, paths.repo, head, { remote = "origin" })
              deleted[#deleted + 1] = head
            end
          else
            errors[#errors + 1] = { number = pr.number, error = "close failed" }
          end
        end
      end
    end

    local branches, berr = deps.git.list_branches(paths.repo, "origin", { pattern = prefix .. "*" })
    if not branches then
      return { ok = false, error = berr, closed = closed, kept = kept }
    end
    for _, branch in ipairs(branches) do
      if not live_branches[branch] and not pr_branches[branch] then
        local ok = pcall(deps.git.delete_branch, paths.repo, branch, { remote = "origin" })
        if ok then
          deleted[#deleted + 1] = branch
        else
          errors[#errors + 1] = { branch = branch, error = "delete failed" }
        end
      end
    end

    return {
      ok = #errors == 0,
      closed = closed,
      deleted = deleted,
      kept = kept,
      errors = errors,
    }
  end

  function runtime.calibrate(input)
    local paths = project_paths()
    local result, err = deps.calibrate.run({
      repo = paths.repo,
      root = paths.root,
      dry_run = input and input.dry_run,
    })
    if not result then
      return { ok = false, error = err }
    end
    return { ok = true, result = result }
  end

  -- Read the config, or update it. `input.answers` (or a flat key=value table)
  -- is merged with the config on disk, so changing one model does not reset
  -- the checks or the merge/deploy policy. The agent uses this to configure
  -- Metronome itself while the mode guard blocks write/edit/bash.
  function runtime.config(input)
    local paths = project_paths()
    local current, current_err = current_answers(paths)
    if current_err then
      return { ok = false, error = "existing config is invalid: " .. current_err }
    end
    local answers = type(input) == "table" and (input.answers or input) or nil
    local updating = type(answers) == "table" and next(answers) ~= nil
    if updating then
      local normalized = normalize_init(input, paths, current)
      -- The base branch is where every task branch starts and what every PR
      -- merges into: a typo must fail here, not on the first task.
      if type(deps.git.list_branches) == "function" and normalized.base_ref then
        local branches = deps.git.list_branches(paths.repo, "origin", { pattern = normalized.base_ref })
        if branches and #branches == 0 then
          return {
            ok = false,
            error = "base branch not found on origin: " .. tostring(normalized.base_ref),
          }
        end
      end
      local refusal = preflight_refusal(normalized)
      if refusal then
        return refusal
      end
      fs.mkdir(paths.root, { parents = true })
      fs.write(paths.config, render_config(normalized))
      local cfg, errors = deps.config.load(paths.config)
      if not cfg then
        return { ok = false, error = table.concat(errors or { "invalid config" }, "; ") }
      end
      return {
        ok = true,
        path = paths.config,
        root = paths.root,
        repo = paths.repo,
        answers = normalized,
        updated = true,
      }
    end
    return {
      ok = true,
      path = paths.config,
      root = paths.root,
      repo = paths.repo,
      answers = current,
      llm_output = fs.read(paths.config),
    }
  end

  -- The panel's `a`: push the pending round into the chat exactly as a
  -- background qualification would, so the agent comes back to the user with
  -- the native question prompt instead of the panel printing text nobody can
  -- answer.
  function runtime.ask_questions(_input, ctx)
    local paths = p()
    local round = deps.questions.round(deps.state, paths.root)
    local questions = (round and round.questions) or {}
    if #questions == 0 then
      return { ok = false, error = "no pending questions" }
    end
    local sid = type(ctx) == "table" and ctx.session or ctx_session_id(ctx)
    if not sid and maki.session and type(maki.session.current) == "function" then
      local ok, current = pcall(maki.session.current)
      if ok then
        sid = current
      end
    end
    if not sid then
      return { ok = false, error = "no session to ask in" }
    end
    if not ask_in_chat({ session = sid }, questions) then
      return { ok = false, error = "cannot reach the chat session" }
    end
    return { ok = true, asked = #questions, session = sid }
  end

  function runtime.panel(input)
    local paths = p()
    local render = deps.ui_render
    local panel_mod = deps.ui_panel
    if not render or not panel_mod then
      return { ok = false, error = "panel modules are not loaded" }
    end
    if not runtime.panel_handle then
      local made, err = panel_mod.new({
        render = render,
        state = deps.state,
        root = paths.root,
        runtime = runtime,
        ask = function()
          return runtime.ask_questions({}, nil)
        end,
      })
      if not made then
        return { ok = false, error = err }
      end
      runtime.panel_handle = made
    end
    local action = (input and input.action) or "toggle"
    if action == "open" then
      local ok, err = panel_mod.open(runtime.panel_handle)
      if not ok then
        return { ok = false, error = err }
      end
    elseif action == "close" then
      panel_mod.close(runtime.panel_handle)
    else
      local ok, err = panel_mod.toggle(runtime.panel_handle)
      if ok == nil then
        return { ok = false, error = err }
      end
    end
    return { ok = true, open = runtime.panel_handle.open }
  end

  function runtime.resume(_input)
    local paths = project_paths()
    if not fs.read(paths.config) then
      return { ok = true, resumed = {}, errors = {} }
    end
    local cfg, cerr = load_config(nil)
    if not cfg then
      return { ok = false, error = cerr }
    end
    local opts = { ctx = background_ctx(nil) }
    local runner, session, _, perr = prepare(opts, cfg, paths)
    if not runner then
      return { ok = false, error = perr }
    end

    -- Select the interrupted tasks, then park each one for the drain. A resume
    -- never walks a task to `running` on its own authority and never spawns it:
    -- a reload that started every interrupted task at once is exactly the
    -- `max_parallel` bypass this fixes. `pipeline.tick` is the single dispatch
    -- authority; it sees the persisted `slot_wait` flag as a candidate once a
    -- slot is free and clears the flag in the same transition. The task keeps
    -- its original status and phase, so a task interrupted in `reviewing` stays
    -- `reviewing` while it waits and a `/reload` replays the wait.
    local max_parallel = max_parallel_of(cfg)
    local selected, err = deps.pipeline.resume(deps.state, paths.root, {
      apply = false,
      -- The same policy and bounds the drain uses, so a resume never retries
      -- past the budget the project set.
      recover = recover_module(),
      max_attempts = recover_opts(cfg).max_attempts,
    })
    if not selected then
      return { ok = false, error = err }
    end
    local requeued, refused, live, skipped = {}, {}, {}, {}
    for _, entry in ipairs(selected.resumed or {}) do
      local id = type(entry) == "table" and entry.id or nil
      -- The status the entry was selected from. Every entry `pipeline.resume`
      -- returns carries it; it is what the compare-and-set below re-checks.
      local expected = type(entry) == "table" and entry.from or nil
      if id and task_handles[id] ~= nil then
        -- A resume can run mid-session, while tasks are still live. A task that
        -- still holds a spawn handle is not interrupted: parking it as
        -- `slot_wait` would drop it out of the in-flight count, let the drain
        -- re-dispatch the same worktree a second time and admit another task
        -- into its slot — the `max_parallel` bypass this change removes.
        entry.live = true
        live[#live + 1] = id
        log(paths, string.format("task %s: still live, resume leaves it alone", tostring(id)))
      elseif id then
        local current = deps.state.load(paths.root)
        local task = current and current.tasks and current.tasks[id] or nil
        -- Compare-and-set, the guard the `apply = true` path always had: the
        -- selection was read once, before this loop, and a resume can run
        -- mid-session while a late verdict, a scheduler tick or a second resume
        -- moves the task. Parking it from a status it no longer holds would
        -- dispatch a `failed` task the retryability filter excluded (a run that
        -- just failed non-retryably and lost its handle) or leave a `merged`
        -- task parked forever, which `tick` never dispatches. Skip such an
        -- entry instead of marking it.
        local lost = not task
          or (expected ~= nil and task.status ~= expected)
          or not RESUME_STATUSES[task.status]
        if lost then
          entry.skipped = true
          if not task then
            entry.reason = "status unreadable while resuming"
          elseif expected ~= nil and task.status ~= expected then
            entry.reason = string.format("status already moved to %s", tostring(task.status))
          else
            entry.reason = string.format("status %s is not resumable", tostring(task.status))
          end
          skipped[#skipped + 1] = { id = id, skipped = true, reason = entry.reason }
          log(paths, string.format("task %s: resume skips it (%s)",
            tostring(id), entry.reason))
        else
          local in_flight, cap, free = slot_counts(
            current and current.tasks or {}, max_parallel, id)
          local waiting = free <= 0
          local reason = waiting and wait_slot_reason() or REQUEUE_FOR_DISPATCH
          local marked, merr = mark_slot_wait(paths, id, reason)
          if marked then
            entry.requeued = true
            entry.waiting = waiting or nil
            entry.wait_reason = reason
            entry.slot_wait = waiting and {
              reason = reason,
              in_flight = in_flight,
              max_parallel = cap,
            } or nil
            requeued[#requeued + 1] = entry
            if waiting then
              refused[#refused + 1] = id
            end
            log(paths, string.format("task %s: queued on resume (%s)", tostring(id), reason))
          else
            log(paths, string.format("task %s: cannot queue on resume: %s",
              tostring(id), tostring(merr)))
          end
        end
      end
    end
    -- Always drain after a resume, even when no task was active: a task that
    -- was queued (`ready`) when the host died has no session to revive, and
    -- without a drain it would wait for the next submit to be noticed.
    schedule_job(opts, paths, cfg, runner, session)
    return {
      ok = true,
      resumed = selected.resumed,
      errors = selected.errors,
      requeued = requeued,
      waiting = refused,
      live = live,
      skipped = skipped,
    }
  end

  function runtime.feedback(input)
    local paths = project_paths()
    local result, err = deps.calibrate.feedback(paths.root, input)
    if not result then
      return { ok = false, error = err }
    end
    -- The feedback is ingested: drive the tasks it concerns now, instead of
    -- waiting for a new submission. A workflow must never stay stopped after a
    -- human did something. Ingestion already happened, so a drain that cannot
    -- start is reported as `ok = true, background = false, error = ...`: the
    -- human's intervention is not lost, only the immediate drain is missing.
    local cfg, cerr = load_config(nil)
    if not cfg then
      return { ok = true, background = false, error = cerr, result = result }
    end
    local opts = { ctx = background_ctx(nil) }
    local runner, session, _, perr = prepare(opts, cfg, paths)
    if not runner then
      return { ok = true, background = false, error = perr, result = result }
    end
    schedule_job(opts, paths, cfg, runner, session)
    return { ok = true, result = result, background = true }
  end

  -- Natural-language routing mode. `input.value` is "on" or "off"; without a
  -- value the call only reports the current flag. Turning the mode on refuses
  -- an unbound project: the user must run `/metronome init` first, so the
  -- models, checks and merge/deploy policy are chosen, not guessed.
  local function current_session_id()
    if maki.session and type(maki.session.current) == "function" then
      local ok, sid = pcall(maki.session.current)
      if ok and type(sid) == "string" and sid ~= "" then
        return sid
      end
    end
    return nil
  end

  function runtime.mode(input)
    local paths = p()
    local value = type(input) == "table" and input.value or nil
    if value == "on" or value == "off" then
      if value == "on" and not fs.read(paths.config) then
        return { ok = false, error = "project is not bound; run /metronome init first" }
      end
      fs.mkdir(paths.root, { parents = true })
      local written, err = deps.mode.set(paths.root, value, current_session_id())
      if written == nil then
        return { ok = false, error = err }
      end
    end
    return {
      ok = true,
      mode = deps.mode.enabled(paths.root) and "on" or "off",
      root = paths.root,
    }
  end

  function runtime.mode_enabled(opts)
    local paths = p(opts)
    return deps.mode.enabled(paths.root)
  end

  function runtime.main_session()
    local paths = p()
    return deps.mode.main_session(paths.root)
  end

  -- The `/metronome on` and `/metronome off` subcommands dispatch by name, so
  -- the runtime exposes one method per subcommand.
  function runtime.on(_input)
    return runtime.mode({ value = "on" })
  end

  function runtime.off(_input)
    return runtime.mode({ value = "off" })
  end

  function runtime.start_pending()
    runtime.run_pending()
  end

  return runtime
end

return M
