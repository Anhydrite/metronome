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
local function normalize_init(input, paths, current)
  current = type(current) == "table" and current or {}
  local current_roles = type(current.roles) == "table" and current.roles or {}
  local answers = type(input) == "table" and (input.answers or input) or {}

  local auto_merge
  if answers.auto_merge ~= nil then
    auto_merge = truthy(answers.auto_merge)
  else
    auto_merge = current.auto_merge == true
  end
  local auto_deploy
  if answers.auto_deploy ~= nil then
    auto_deploy = truthy(answers.auto_deploy)
  else
    auto_deploy = current.auto_deploy == true
  end
  local deploy_confirm
  if answers.deploy_confirm ~= nil then
    deploy_confirm = not (answers.deploy_confirm == false or answers.deploy_confirm == "false")
  else
    deploy_confirm = current.deploy_confirm ~= false
  end
  local checks
  if answers.checks ~= nil then
    checks = split_checks(answers.checks)
  elseif type(current.checks) == "table" then
    checks = current.checks
  else
    checks = { "npm test" }
  end

  local normalized = {
    repo = answers.repo or current.repo or paths.repo,
    base_ref = answers.base_ref or current.base_ref or "main",
    max_parallel = tonumber(answers.max_parallel) or current.max_parallel or 1,
    checks = checks,
    auto_merge = auto_merge,
    auto_deploy = auto_deploy,
    deploy_confirm = deploy_confirm,
    roles = {},
  }
  for _, role in ipairs(ROLE_ORDER) do
    local default = DEFAULT_ROLES[role]
    local role_current = current_roles[role] or {}
    normalized.roles[role] = {
      model = answers[role .. "_model"] or role_current.model or default.model,
      thinking = answers[role .. "_thinking"] or role_current.thinking or default.thinking,
    }
  end
  return normalized
end

local function render_config(answers)
  local lines = {
    "[project]",
    "repo = " .. toml_string(answers.repo),
    "base_ref = " .. toml_string(answers.base_ref),
    "max_parallel = " .. tostring(answers.max_parallel),
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
  lines[#lines + 1] = "max_rounds = 3"
  lines[#lines + 1] = "require_checks_green = true"
  lines[#lines + 1] = 'protected_paths = ["review-rules.md", "AGENTS.md", ".metronome/", "deploy.md"]'
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[merge]"
  lines[#lines + 1] = "auto_merge = " .. tostring(answers.auto_merge)
  lines[#lines + 1] = 'method = "squash"'
  lines[#lines + 1] = "auto_rebase = true"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[deploy]"
  lines[#lines + 1] = "auto_deploy = " .. tostring(answers.auto_deploy)
  lines[#lines + 1] = "confirm = " .. tostring(answers.deploy_confirm)
  lines[#lines + 1] = 'plan_file = "deploy.md"'
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[quality]"
  lines[#lines + 1] = "variants = 1"
  lines[#lines + 1] = "stall_minutes = 20"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[limits]"
  lines[#lines + 1] = "max_task_cost_usd = 5.0"
  lines[#lines + 1] = "timeout_minutes = 30"
  lines[#lines + 1] = "max_questions_per_round = 15"
  return table.concat(lines, "\n") .. "\n"
end

-- Exposed for tests and for the command surface.
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
    return cfg, nil, paths
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

  local function run_task(opts, task_id, paths, cfg, runner, session)
    local state = deps.state
    local loaded = state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[task_id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(task_id) }
    end

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
    })
    if not impl.ok then
      return impl
    end

    local worktree = impl.ctx.worktree
    local checks = task.checks or cfg.checks.default
    local verified = deps.checks.verify({
      checks = checks,
      worktree = worktree,
      timeout_ms = (cfg.checks.timeout_secs or 600) * 1000,
      rollback = false,
    })
    if not verified or not verified.ok then
      return { ok = false, error = (verified and verified.error) or "checks failed", impl = impl }
    end
    deps.checks.write_report(paths.root, task_id, verified, {})

    local sheet = deps.implement.read_sheet(paths.root, task, { tasks_dir = paths.tasks })
    -- The worktree is cut from origin/<base>, so the diff must be read against
    -- the same ref. The local base branch is not advanced by a GitHub merge.
    local diff_base = "origin/" .. cfg.project.base_ref
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
      return converged
    end

    state.transition(paths.root, task_id, "verifying", { phase = "verify" })
    state.transition(paths.root, task_id, "reviewing", { phase = "review" })

    local reviewed = deps.review.review({
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
    })
    if not reviewed.ok or not reviewed.approved then
      return { ok = false, error = (reviewed and reviewed.error) or "review not approved", review = reviewed }
    end

    local pr = deps.git.pr_open(state, paths.root, task_id, {
      repo = paths.repo,
      worktree = worktree,
      base = cfg.project.base_ref,
      head = impl.ctx.branch,
      title = task.title,
      body = "Metronome task " .. task_id,
      gh = "gh",
    })
    if not pr then
      return { ok = false, error = "cannot open the pull request" }
    end

    -- `auto_merge` is the project's switch. Off means the task stops at
    -- `pr_open` with a PR a human can review and merge; on means the merger
    -- takes it the rest of the way (and redeploys when `auto_deploy` is set).
    if not (cfg.merge and cfg.merge.auto_merge) then
      return { ok = true, task_id = task_id, sha = impl.sha, pr = pr, pr_open = true }
    end

    local merged = deps.merge.run({
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
    if not merged.ok then
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
      return { ok = true, task_id = task_id, sha = impl.sha, pr = pr, merged = merged, deployed = deployed }
    end

    return { ok = true, task_id = task_id, sha = impl.sha, pr = pr, merged = merged }
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

  -- The part of a run that follows qualification: the analysis gate, the
  -- scheduler loop and the optional deploy. `submit` reaches it after applying
  -- the qualified tasks; `answer` reaches it after the pending questions are
  -- answered, so answering resumes the pipeline instead of leaving the tasks
  -- stuck in `qualifying` forever.
  local function after_questions(opts, paths, cfg, runner, session)
    local gate, gerr = deps.analyze.gate(deps.state, paths.root, { tasks_dir = paths.tasks })
    if not gate or not gate.ok then
      return { ok = false, error = gerr or (gate and gate.verdict) or "analysis gate failed" }
    end

    local results = {}
    local deployed = false
    for _ = 1, 32 do
      local tick = deps.pipeline.tick({
        state = deps.state,
        root = paths.root,
        max_parallel = 1,
        stall = false,
        apply = true,
        dispatch = function(task)
          local result = run_task(opts, task.id, paths, cfg, runner, session)
          results[#results + 1] = result
          if not result.ok then
            log(paths, "task " .. task.id .. " failed: " .. tostring(result.error))
            pcall(deps.state.transition, paths.root, task.id, "failed", {
              reason = tostring(result.error or "task failed"),
            })
          end
        end,
      })
      if not tick.ok then
        return { ok = false, error = tick.error, results = results }
      end
      if #tick.started == 0 then
        break
      end
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
  local scheduler_running = false
  local scheduler_dirty = false
  local scheduler_job = nil
  local scheduler_extra = {}

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

  -- A background qualification cannot block on a tool result, so it pushes the
  -- questions back into the chat: the agent relays them with the native
  -- `question` tool and answers through `metronome_answer`.
  local function ask_in_chat(ctx, questions)
    if not (maki.session and type(maki.session.prompt) == "function") then
      return false
    end
    local sid = type(ctx) == "table" and ctx.session or ctx_session_id(ctx)
    local lines = {
      "Metronome a qualifié une intention et a besoin de réponses.",
      "Utilise l'outil `question` pour poser ces questions à l'utilisateur, puis appelle `metronome_answer` avec les réponses (la clé est entre parenthèses).",
    }
    for _, question in ipairs(questions) do
      lines[#lines + 1] = string.format("- (%s) %s", tostring(question.id), tostring(question.text))
    end
    local ok, sent = pcall(maki.session.prompt, table.concat(lines, "\n"), { session = sid })
    return ok and sent ~= nil
  end

  local function schedule_job(opts, paths, cfg, runner, session)    scheduler_job = {
      opts = opts,
      paths = paths,
      cfg = cfg,
      runner = runner,
      session = session,
    }
    scheduler_dirty = true
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

    local qualified = deps.qualify.run({
      intention = opts.intention,
      runner = runner,
      session_opts = session.qualifier,
      repo = paths.repo,
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
    local opts = {
      intention = input.intention,
      answers = input.answers,
      -- Qualify through a background ctx too: the qualifier is a role session,
      -- and a role session opened with the tool's LuaCtx is cancelled with the
      -- turn. `{ session = sid }` opens it as a background session instead.
      ctx = background_ctx(M.resolve_ctx(input, ctx)),
    }
    -- Qualification is a role turn: run the whole `drive` in the background so
    -- the chat is free at once and the user can enqueue another demand. The
    -- result lands in `last_submit`; questions are pushed back to the chat.
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
    local paths = p()
    local loaded = deps.state.load(paths.root)
    local task = loaded and loaded.tasks and loaded.tasks[input.id]
    if not task then
      return { ok = false, error = "unknown task: " .. tostring(input.id) }
    end
    if task.status ~= "failed" and task.status ~= "stalled" then
      return { ok = false, error = "task is not failed or stalled" }
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
        return
      end
      if not result.ok then
        pcall(deps.state.transition, paths.root, input.id, "failed", {
          reason = tostring(result.error or "task failed"),
        })
      end
      runtime.last_background = result
    end
    schedule_job(bg, paths, cfg, runner, session)
    return { ok = true, background = true, task = moved }
  end

  function runtime.abandon(input)
    local paths = p()
    local moved, err = deps.state.transition(paths.root, input.id, "abandoned", { reason = "abandoned by the user" })
    if not moved then
      return { ok = false, error = err }
    end
    return { ok = true, task = moved }
  end

  function runtime.calibrate(input)
    local paths = p()
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
    local paths = p()
    local current, current_err = current_answers(paths)
    if current_err then
      return { ok = false, error = "existing config is invalid: " .. current_err }
    end
    local answers = type(input) == "table" and (input.answers or input) or nil
    local updating = type(answers) == "table" and next(answers) ~= nil
    if updating then
      local normalized = normalize_init(input, paths, current)
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
    local paths = p()
    local resumed, err = deps.pipeline.resume(deps.state, paths.root, { apply = true })
    if not resumed then
      return { ok = false, error = err }
    end
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
