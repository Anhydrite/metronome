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
    checks = checks,
    auto_merge = bool("merge.auto_merge", current_merge.auto_merge ~= nil and current_merge.auto_merge or current.auto_merge, false),
    auto_deploy = bool("deploy.auto_deploy", current_deploy.auto_deploy ~= nil and current_deploy.auto_deploy or current.auto_deploy, false),
    deploy_confirm = deploy_confirm,
    roles = {},
    review = {
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
  lines[#lines + 1] = "max_rounds = " .. s(review.max_rounds or 3)
  lines[#lines + 1] = "require_checks_green = " .. b(review.require_checks_green ~= false)
  lines[#lines + 1] = "protected_paths = " .. toml_array(review.protected_paths
    or { "review-rules.md", "AGENTS.md", ".metronome/", "deploy.md" })
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[merge]"
  lines[#lines + 1] = "auto_merge = " .. b(answers.auto_merge)
  lines[#lines + 1] = "method = " .. toml_string(merge.method or "squash")
  lines[#lines + 1] = "auto_rebase = " .. b(merge.auto_rebase ~= false)
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

  -- How many times a task may be redone on a fresh base. A base that keeps
  -- moving is a real situation (several PRs merging), so the bound is a count,
  -- not a lifetime flag: a task that repaired one conflict can still repair
  -- the next one.
  local MAX_CONFLICT_REPAIRS = 3

  local function conflict_repairs(task)
    local n = tonumber(task and task.conflict_retries)
    if n then
      return n
    end
    return (task and task.conflict_retried) and 1 or 0
  end

  local function run_task(opts, task_id, paths, cfg, runner, session)
    local state = deps.state
    local loaded = state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[task_id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(task_id) }
    end

    -- One implementation turn plus everything that must hold before a review:
    -- the rebase onto the fresh base, the declared checks and the convergence
    -- diff. A fix round runs exactly the same sequence, with the reviewer's
    -- findings as the prompt's work list, so a review never ends the task
    -- while rounds remain.
    local function implement_and_verify(feedback, repaired)
      local impl = deps.implement.run({
        task = task,
        repo = paths.repo,
        state = state,
        root = paths.root,
        git = deps.git,
        worktree_root = paths.worktrees,
        tasks_dir = paths.tasks,
        remote = "origin",
        base_ref = cfg.project.base_ref,
        runner = runner,
        session_opts = session.implementer,
        state_root = paths.runs,
        ctx = opts.ctx,
        max_attempts = 1,
        deadline_secs = opts.deadline_secs,
        feedback = feedback,
      })
      if not impl.ok then
        return nil, impl
      end
      local worktree = impl.ctx.worktree

      -- The base can move while the implementer works (another task merges).
      -- Rebase onto the fresh origin/base before the checks and the converge
      -- diff, so the diff is measured against the base the PR will merge into.
      -- A conflict sends the task back to implementation on the new base.
      if deps.merge and type(deps.merge.rebase) == "function" then
        local rebased, rebase_err, rebase_diag = deps.merge.rebase({
          repo = paths.repo,
          worktree = worktree,
          remote = "origin",
          base = cfg.project.base_ref,
          git = deps.git,
        })
        if not rebased then
          if type(rebase_diag) == "table" and rebase_diag.conflict then
            -- The base moved under the branch and the same lines changed.
            -- That is repairable without a human: move the branch back to the
            -- fresh base and redo the work there, once. A second conflict is
            -- a real failure and goes to the user.
            if not repaired and conflict_repairs(task) < MAX_CONFLICT_REPAIRS
              and type(deps.git.reset_hard) == "function" then
              -- `reset_hard` takes a sha, never a ref: resolve the fresh base
              -- first, or the reset is refused and the repair silently does
              -- nothing.
              local base_sha = type(deps.git.rev_parse) == "function"
                and deps.git.rev_parse(worktree, "origin/" .. cfg.project.base_ref) or nil
              local reset = base_sha and deps.git.reset_hard(worktree, base_sha) or nil
              if reset then
                log(paths, "task " .. task_id .. " conflicted with the fresh base on "
                  .. tostring(rebase_diag.conflict) .. "; redoing it on the fresh base")
                pcall(state.set_fields, paths.root, task_id, {
                  conflict_retried = true,
                  conflict_retries = conflict_repairs(task) + 1,
                })
                pcall(state.transition, paths.root, task_id, "failed", {
                  reason = "rebase conflict on the fresh base, redoing it: "
                    .. tostring(rebase_err),
                })
                pcall(state.transition, paths.root, task_id, "running", { phase = "implement" })
                -- The reset rewrote the branch: lease the push so the PR shows
                -- the commit the next turn will build on.
                if type(deps.git.push) == "function" then
                  deps.git.push(worktree, impl.ctx.branch, { remote = "origin", force = true })
                end
                return implement_and_verify(feedback, true)
              end
            end
            return nil, {
              ok = false,
              conflict = true,
              error = "rebase onto fresh base conflicted: " .. tostring(rebase_err),
            }
          end
          return nil, { ok = false, error = "rebase before checks failed: " .. tostring(rebase_err) }
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
            return nil, { ok = false, error = "push after rebase failed: " .. tostring(push_err) }
          end
        end
      end

      local checks = task.checks or cfg.checks.default
      local verified = deps.checks.verify({
        checks = checks,
        worktree = worktree,
        timeout_ms = (cfg.checks.timeout_secs or 600) * 1000,
        rollback = false,
      })
      if not verified or not verified.ok then
        return nil, { ok = false, error = (verified and verified.error) or "checks failed", impl = impl }
      end
      deps.checks.write_report(paths.root, task_id, verified, {})

      -- The worktree is cut from origin/<base>, so the diff must be read
      -- against the same ref. The local base branch is not advanced by a
      -- GitHub merge.
      local diff_base = "origin/" .. cfg.project.base_ref
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
      return impl
    end

    -- A retry after a review failure already has the findings on the task:
    -- hand them to the implementer instead of asking it to guess again.
    local initial_feedback = nil
    if type(task.review) == "table" and type(task.review.findings) == "table"
      and #task.review.findings > 0 then
      initial_feedback = task.review.findings
    end

    local impl, impl_err = implement_and_verify(initial_feedback)
    if not impl then
      return impl_err
    end

    local worktree = impl.ctx.worktree
    local checks = task.checks or cfg.checks.default
    local diff_base = "origin/" .. cfg.project.base_ref

    state.transition(paths.root, task_id, "verifying", { phase = "verify" })
    state.transition(paths.root, task_id, "reviewing", { phase = "review" })

    -- Open the pull request before the review: the reviewer reads the exact
    -- SHA on a real PR, and a human can follow it while the review runs. The
    -- task stays in `reviewing` until the review approves it.
    local pr = deps.git.pr_open(state, paths.root, task_id, {
      repo = paths.repo,
      worktree = worktree,
      base = cfg.project.base_ref,
      head = impl.ctx.branch,
      title = task.title,
      body = "Metronome task " .. task_id,
      gh = "gh",
      attach_only = true,
    })
    if not pr then
      return { ok = false, error = "cannot open the pull request" }
    end

    -- A review that asks for changes is not a failure: it is the next round's
    -- work. The loop re-implements with the findings, re-runs the checks and
    -- the convergence diff, then reviews again, up to `review.max_rounds`.
    -- Only an exhausted bound escalates, and only a real error (a dead
    -- reviewer, an invalid answer) ends the task before that.
    local function fix(result)
      local findings = type(result) == "table" and result.findings or nil
      local moved, merr = state.transition(paths.root, task_id, "running", { phase = "implement" })
      if not moved then
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
    local reviewed
    if type(deps.review.loop) == "function" then
      reviewed = deps.review.loop(review_opts)
    else
      reviewed = deps.review.review(review_opts)
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
    local approved_sha = (reviewed and reviewed.sha) or impl.sha

    -- The review passed on the exact SHA: move the task to `pr_open` now.
    state.transition(paths.root, task_id, "pr_open", { phase = "review" })

    -- `auto_merge` is the project's switch. Off means the task stops at
    -- `pr_open` with a PR a human can review and merge; on means the merger
    -- takes it the rest of the way (and redeploys when `auto_deploy` is set).
    if not (cfg.merge and cfg.merge.auto_merge) then
      return { ok = true, task_id = task_id, sha = approved_sha, pr = pr, pr_open = true }
    end

    local merged, merge_err = with_merge_gate(function()
      return deps.merge.run({
        task = task_id,
        worktree = worktree,
        repo = paths.repo,
        git = deps.git,
        state = state,
        root = paths.root,
        remote = "origin",
        base = cfg.project.base_ref,
        checks = deps.checks,
        gh = "gh",
        method = cfg.merge.method,
        verify = cfg.checks.re_run_after_merge ~= false,
        commands = checks,
      })
    end)
    if not merged then
      return { ok = false, error = tostring(merge_err or "merge failed") }
    end
    if not merged.ok then
      -- A conflict with the base is repairable without a human: move the
      -- branch back to the fresh base and let the implementer redo the work
      -- there. One repair only; a second conflict is a real failure.
      if merged.conflict and conflict_repairs(task) < MAX_CONFLICT_REPAIRS then
        local base_sha = deps.git.rev_parse
          and deps.git.rev_parse(worktree, "origin/" .. cfg.project.base_ref) or nil
        local reset = base_sha and deps.git.reset_hard
          and deps.git.reset_hard(worktree, base_sha) or nil
        if reset then
          log(paths, "task " .. task_id .. " hit a merge conflict on "
            .. tostring(merged.conflict_files) .. "; redoing it on the fresh base")
          pcall(deps.state.set_fields, paths.root, task_id, {
            conflict_retried = true,
            conflict_retries = conflict_repairs(task) + 1,
          })
          pcall(deps.state.transition, paths.root, task_id, "failed",
            { reason = "merge conflict: " .. tostring(merged.conflict_files) })
          pcall(deps.state.transition, paths.root, task_id, "running", { phase = "implement" })
          return { ok = false, conflict = true, error = merged.error, task_id = task_id }
        end
      end
      return merged
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

  -- A task that will not be merged must not leave an open PR behind: the list
  -- fills with pull requests nobody will ever look at. The branch stays, so a
  -- retry can still resume from its checkpoints.
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

  -- The part of a run that follows qualification: the analysis gate, the
  -- scheduler loop and the optional deploy. `submit` reaches it after applying
  -- the qualified tasks; `answer` reaches it after the pending questions are
  -- answered, so answering resumes the pipeline instead of leaving the tasks
  -- stuck in `qualifying` forever.
  local function after_questions(opts, paths, cfg, runner, session)
    local gate, gerr = deps.analyze.gate(deps.state, paths.root, {
      tasks_dir = paths.tasks,
      repo = paths.repo,
      ref = "origin/" .. tostring(cfg.project.base_ref),
      git = deps.git,
    })
    if not gate or not gate.ok then
      return { ok = false, error = gerr or (gate and gate.verdict) or "analysis gate failed" }
    end

    local results = {}
    local deployed = false

    -- `max_parallel` is the project's cap, not a hardcoded one: a queue of
    -- independent asks must not take one full pipeline each, end to end.
    local max_parallel = tonumber(cfg.project and cfg.project.max_parallel)
      or tonumber(cfg.max_parallel) or 1
    if max_parallel < 1 then
      max_parallel = 1
    end

    -- Each selected task runs in its own plugin-lifetime spawn. A batch held
    -- by `async.join` lives in the drain's scope, and maki kills the live jobs
    -- of a scope when it ends: the sessions died mid-review. A spawn outlives
    -- the drain, and a finished task re-triggers the drain to refill the slots.
    local function dispatch_one(task)
      local fn = function()
        local result = run_task(opts, task.id, paths, cfg, runner, session)
        if type(result) == "table" and result.conflict then
          -- The branch is back on the fresh base: redo the work once.
          result = run_task(opts, task.id, paths, cfg, runner, session)
        end
        results[#results + 1] = result
        if not result.ok then
          local reason = tostring(result.error or "task failed")
          log(paths, "task " .. task.id .. " failed: " .. reason)
          pcall(deps.state.transition, paths.root, task.id, "failed", { reason = reason })
          close_open_pr(paths, task.id)
          notify_failure(opts.ctx, task.id, reason)
        end
        -- A slot just freed: another ready task may start now. Only in the
        -- async path, where the drain returned long ago; setting the flag in
        -- the synchronous path would make its drain loop forever.
        if deps.async then
          scheduler_dirty = true
          spawn(function()
            pcall(runtime.run_pending)
          end)
        end
      end
      if deps.async then
        task_handles[task.id] = spawn(function()
          fn()
          task_handles[task.id] = nil
        end)
      else
        fn()
      end
    end

    for _ = 1, 32 do
      local tick = deps.pipeline.tick({
        state = deps.state,
        root = paths.root,
        max_parallel = max_parallel,
        stall = false,
        apply = true,
        dispatch = dispatch_one,
      })
      if not tick.ok then
        return { ok = false, error = tick.error, results = results }
      end
      if #tick.started == 0 then
        break
      end
    end

    -- An async drain returns while its tasks are still running: the pending
    -- check and the final deploy belong to the synchronous path (the scripted
    -- e2e driver), where every task has already finished by now.
    if deps.async then
      return { ok = true, results = results, background = true }
    end

    local loaded = deps.state.load(paths.root)
    local last = nil
    local pending = {}
    for _, task in pairs(loaded and loaded.tasks or {}) do
      if task.status == "merged" then
        last = task
      elseif task.status ~= "deployed" and task.status ~= "abandoned" then
        pending[#pending + 1] = task.id
      end
    end
    if #pending > 0 then
      return {
        ok = false,
        error = "tasks did not finish: " .. table.concat(pending, ", "),
        results = results,
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

    return { ok = true, results = results, deployed = deployed }
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
      "Metronome: task %s failed: %s. Call metronome_status for the detail, then metronome_retry to restart it.",
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

  function runtime.has_pending()
    return (scheduler_dirty or #scheduler_extra > 0) and not scheduler_running
  end

  function runtime.run_pending()
    if scheduler_running or not scheduler_job then
      return
    end
    scheduler_running = true
    local job = scheduler_job
    local ok, err = pcall(function()
      while #scheduler_extra > 0 or scheduler_dirty do
        while #scheduler_extra > 0 do
          local fn = table.remove(scheduler_extra, 1)
          fn()
        end
        if scheduler_dirty then
          scheduler_dirty = false
          runtime.last_background = after_questions(
            job.opts, job.paths, job.cfg, job.runner, job.session)
        end
      end
    end)
    scheduler_running = false
    if not ok then
      log(job.paths, "background scheduler error: " .. tostring(err))
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

    -- `fast = false` explicitly forces the qualifier, which is what the
    -- contract tests use; `fast = true` forces the fast lane; nil lets the
    -- short-intention heuristic decide.
    if opts.fast == true or (opts.fast ~= false and short_intention(opts.intention)) then
      local date = os.date("!%Y%m%d")
      local first_id = deps.qualify.next_id(deps.state.load(paths.root), date)
      local first_hex = tonumber(first_id:match("([0-9a-f]+)$") or "", 16) or 1
      local default_checks = (cfg.checks and cfg.checks.default) or {}
      local applied, apply_err = deps.qualify.apply(deps.state, paths.root, {
        ok = true,
        tasks = { {
          title = opts.intention,
          intent = opts.intention,
          origin = opts.intention,
          files = {},
          checks = default_checks,
        } },
      }, {
        tasks_dir = paths.tasks,
        id_factory = function(index)
          return string.format("T-%s-%04x", date, first_hex + index - 1)
        end,
      })
      if not applied then
        return { ok = false, error = apply_err }
      end
      schedule_job({ ctx = background_ctx(opts.ctx) }, paths, cfg, runner, session)
      return { ok = true, background = true, fast = true, tasks = applied.tasks }
    end

    -- The qualifier must describe the tree the worktree will be cut from, so it
    -- reads `origin/<base>` from git rather than the local checkout. Fetch first
    -- so that ref is as fresh as the worktree will be; a fetch that fails (no
    -- network, no remote) leaves the last known ref, which is still the truth
    -- the pipeline would merge into, and the qualifier's own git reads will say
    -- so if the ref does not exist at all.
    if deps.git and type(deps.git.fetch) == "function" then
      deps.git.fetch(paths.repo, "origin")
    end
    local qualify_ref = "origin/" .. tostring(cfg.project.base_ref)

    local qualified = deps.qualify.run({
      intention = opts.intention,
      runner = runner,
      session_opts = session.qualifier,
      repo = paths.repo,
      ref = qualify_ref,
      git = deps.git,
      task_id = "qualify",
      validate = false,
      state_root = paths.runs,
      ctx = opts.ctx,
    })
    if not qualified.ok then
      return qualified
    end

    local date = os.date("!%Y%m%d")
    local first_id = deps.qualify.next_id(deps.state.load(paths.root), date)
    local first_hex = tonumber(first_id:match("([0-9a-f]+)$"), 16) or 1
    local applied, apply_err = deps.qualify.apply(deps.state, paths.root, qualified, {
      tasks_dir = paths.tasks,
      id_factory = function(index)
        return string.format("T-%s-%04x", date, first_hex + index - 1)
      end,
    })
    if not applied then
      return { ok = false, error = apply_err }
    end

    -- The qualifier names dependencies by task title; the state stores ids.
    -- Remap every applied task, scripted or real, so the analysis gate does not
    -- see a title where it expects an id.
    local ids_by_title = {}
    for _, task in ipairs(applied.tasks or {}) do
      ids_by_title[task.title] = task.id
    end
    for _, task in ipairs(applied.tasks or {}) do
      local depends = task.depends_on
      if type(depends) == "table" and #depends > 0 then
        local ids = {}
        for _, dep in ipairs(depends) do
          ids[#ids + 1] = ids_by_title[dep] or dep
        end
        deps.state.set_fields(paths.root, task.id, { depends_on = ids })
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
        deps.questions.answer(deps.state, paths.root, answers)
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

  function runtime.status(input)
    local paths = p()
    local loaded, err = deps.state.load(paths.root)
    if not loaded then
      return { ok = false, error = err or "cannot load state" }
    end
    if is_non_empty(input and input.id) then
      local task = loaded.tasks and loaded.tasks[input.id]
      if not task then
        return { ok = false, error = "unknown task: " .. input.id }
      end
      return { ok = true, task = task }
    end
    return { ok = true, tasks = loaded.tasks, events = loaded.events }
  end

  function runtime.answer(input, ctx)
    input = type(input) == "table" and input or {}
    local paths = p()
    local applied, err = deps.questions.answer(deps.state, paths.root, input.answers or {})
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
    local moved, err = deps.state.transition(paths.root, input.id, "running", { phase = "implement" })
    if not moved then
      return { ok = false, error = err }
    end

    -- A retry is a restart, not just a status move: re-dispatch the task from
    -- its last checkpoint so the user does not have to submit it again.
    local cfg, cerr = load_config(nil)
    if not cfg then
      return { ok = false, error = cerr, task = moved }
    end
    local opts = { ctx = M.resolve_ctx(input, ctx) }
    local runner, session, _, perr = prepare(opts, cfg, paths)
    if not runner then
      return { ok = false, error = perr, task = moved }
    end
    local bg = { ctx = background_ctx(opts.ctx) }
    pcall(function()
      maki.log.info("metronome retry bg in=" .. type(opts.ctx) .. " out=" .. type(bg.ctx))
    end)
    scheduler_extra[#scheduler_extra + 1] = function()
      local ok, result = pcall(run_task, bg, input.id, paths, cfg, runner, session)
      if not ok then
        log(paths, "retry error: " .. tostring(result))
        pcall(deps.state.transition, paths.root, input.id, "failed", {
          reason = tostring(result),
        })
        notify_failure(bg.ctx, input.id, tostring(result))
        return
      end
      if not result.ok then
        local reason = tostring(result.error or "task failed")
        pcall(deps.state.transition, paths.root, input.id, "failed", { reason = reason })
        notify_failure(bg.ctx, input.id, reason)
      end
      runtime.last_background = result
    end
    schedule_job(bg, paths, cfg, runner, session)
    return { ok = true, background = true, task = moved }
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
    return { ok = true, task = moved, stopped = true }
  end

  function runtime.abandon(input)
    local paths = project_paths()
    close_open_pr(paths, input.id)
    local moved, err = deps.state.transition(paths.root, input.id, "abandoned", { reason = "abandoned by the user" })
    if not moved then
      return { ok = false, error = err }
    end
    return { ok = true, task = moved }
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

    -- Walk each interrupted task back to `running` through legal transitions,
    -- then re-dispatch it from its last checkpoint. Without the dispatch the
    -- task only changes status and nothing drives it.
    local resumed, err = deps.pipeline.resume(deps.state, paths.root, {
      apply = true,
      dispatch = function(task)
        scheduler_extra[#scheduler_extra + 1] = function()
          local ok, result = pcall(run_task, opts, task.id, paths, cfg, runner, session)
          if not ok or not (type(result) == "table" and result.ok) then
            local reason = (not ok and tostring(result))
              or (type(result) == "table" and result.error)
              or "resume failed"
            pcall(deps.state.transition, paths.root, task.id, "failed", { reason = tostring(reason) })
            notify_failure(opts.ctx, task.id, reason)
          end
          runtime.last_background = result
        end
      end,
    })
    if not resumed then
      return { ok = false, error = err }
    end
    -- Always drain after a resume, even when no task was active: a task that
    -- was queued (`ready`) when the host died has no session to revive, and
    -- without a drain it would wait for the next submit to be noticed.
    schedule_job(opts, paths, cfg, runner, session)
    return { ok = true, resumed = resumed.resumed, errors = resumed.errors }
  end

  function runtime.feedback(input)
    local paths = p()
    local result, err = deps.calibrate.feedback(paths.root, input)
    if not result then
      return { ok = false, error = err }
    end
    return { ok = true, result = result }
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
