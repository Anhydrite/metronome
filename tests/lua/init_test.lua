-- Tests for the init questions and config rendering in runtime.lua.
--
-- `/metronome init` must not guess: without answers it returns the questions,
-- and with answers it renders a config where every choice is explicit.

return function()
  local runtime = load_module("runtime")

  -- Questions --------------------------------------------------------------

  local questions = runtime.init_questions("/tmp/project")
  local by_key = {}
  for _, question in ipairs(questions) do
    by_key[question.key] = question
  end
  eq(by_key.repo.default, "/tmp/project", "the repo question defaults to the cwd")
  eq(by_key.base_ref.default, "main", "the base branch question defaults to main")
  eq(by_key.checks.default, "npm test", "the checks question defaults to npm test")
  eq(by_key.max_parallel.default, "1", "the parallelism question defaults to 1")
  for _, role in ipairs({ "qualifier", "analyst", "implementer", "reviewer", "deployer" }) do
    eq(type(by_key[role .. "_model"]), "table", "the questions ask for the " .. role .. " model")
    eq(type(by_key[role .. "_thinking"]), "table", "the questions ask for the " .. role .. " thinking")
  end
  eq(by_key.auto_merge.default, "false", "merge is off by default")
  eq(by_key.auto_deploy.default, "false", "deploy is off by default")

  -- Defaults ---------------------------------------------------------------

  local defaults = runtime.normalize_init({ answers = {} }, { repo = "/tmp/project" })
  eq(defaults.repo, "/tmp/project", "the repo defaults to the project path")
  eq(defaults.base_ref, "main", "the base defaults to main")
  eq(defaults.max_parallel, 1, "the parallelism defaults to 1")
  eq(defaults.checks[1], "npm test", "the checks default to npm test")
  eq(defaults.auto_merge, false, "merge stays off by default")
  eq(defaults.auto_deploy, false, "deploy stays off by default")
  eq(defaults.deploy_confirm, true, "deploy keeps its confirmation")
  eq(defaults.roles.implementer.model, "opencode-go/kimi-k3", "the implementer keeps its model")
  eq(defaults.roles.reviewer.thinking, "high", "the reviewer keeps its thinking")

  -- Updating an existing config keeps what was not overridden ---------------

  local current = {
    repo = "/tmp/project",
    base_ref = "develop",
    max_parallel = 2,
    checks = { "node check.js all" },
    auto_merge = true,
    auto_deploy = false,
    deploy_confirm = true,
    roles = {
      implementer = { model = "old/model", thinking = "low" },
    },
  }
  local merged = runtime.normalize_init({
    answers = { implementer_model = "new/model" },
  }, { repo = "/tmp/project" }, current)
  eq(merged.base_ref, "develop", "an update keeps the existing base branch")
  eq(merged.max_parallel, 2, "an update keeps the existing parallelism")
  eq(merged.checks[1], "node check.js all", "an update keeps the existing checks")
  eq(merged.auto_merge, true, "an update keeps the existing merge policy")
  eq(merged.auto_deploy, false, "an update keeps the existing deploy policy")
  eq(merged.roles.implementer.model, "new/model", "an update applies the override")
  eq(merged.roles.implementer.thinking, "low", "an update keeps the existing thinking")

  local current_questions = runtime.init_questions("/tmp/project", current)
  local current_by_key = {}
  for _, question in ipairs(current_questions) do
    current_by_key[question.key] = question
  end
  eq(current_by_key.base_ref.default, "develop", "the questions show the current base branch")
  eq(current_by_key.checks.default, "node check.js all", "the questions show the current checks")
  eq(current_by_key.implementer_model.default, "old/model", "the questions show the current model")

  -- Overrides --------------------------------------------------------------

  local answers = runtime.normalize_init({
    answers = {
      base_ref = "master",
      checks = "make test, npm run lint",
      max_parallel = "3",
      implementer_model = "acme/coder",
      implementer_thinking = "low",
      auto_merge = "true",
      auto_deploy = "yes",
      deploy_confirm = "false",
    },
  }, { repo = "/tmp/project" })
  eq(answers.base_ref, "master", "the base branch is overridden")
  eq(#answers.checks, 2, "the checks are split")
  eq(answers.checks[1], "make test", "the first check is trimmed")
  eq(answers.checks[2], "npm run lint", "the second check is trimmed")
  eq(answers.max_parallel, 3, "the parallelism is parsed")
  eq(answers.roles.implementer.model, "acme/coder", "the implementer model is overridden")
  eq(answers.roles.implementer.thinking, "low", "the implementer thinking is overridden")
  eq(answers.auto_merge, true, "merge can be turned on explicitly")
  eq(answers.auto_deploy, true, "deploy can be turned on explicitly")
  eq(answers.deploy_confirm, false, "the deploy confirmation can be turned off explicitly")

  -- Render ----------------------------------------------------------------

  local config = runtime.render_config(answers)
  eq(config:find('repo = "/tmp/project"', 1, true) ~= nil, true, "the config carries the repo")
  eq(config:find('base_ref = "master"', 1, true) ~= nil, true, "the config carries the base branch")
  eq(config:find("max_parallel = 3", 1, true) ~= nil, true, "the config carries the parallelism")
  eq(config:find('default = ["make test", "npm run lint"]', 1, true) ~= nil, true, "the config carries the checks")
  eq(config:find('model = "acme/coder"', 1, true) ~= nil, true, "the config carries the role model")
  eq(config:find('thinking = "low"', 1, true) ~= nil, true, "the config carries the role thinking")
  eq(config:find("auto_merge = true", 1, true) ~= nil, true, "the config carries the merge policy")
  eq(config:find("auto_deploy = true", 1, true) ~= nil, true, "the config carries the deploy policy")
  eq(config:find("confirm = false", 1, true) ~= nil, true, "the config carries the deploy confirmation")
  eq(config:find("[roles.reviewer]", 1, true) ~= nil, true, "the config carries every role section")

  -- A quote in a value cannot break the TOML.
  local quoted = runtime.normalize_init({
    answers = { checks = 'echo "hi", npm test' },
  }, { repo = "/tmp/project" })
  local quoted_config = runtime.render_config(quoted)
  eq(quoted_config:find('echo \\"hi\\"', 1, true) ~= nil, true, "quotes are escaped")
end
