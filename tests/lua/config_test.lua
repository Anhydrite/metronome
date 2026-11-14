-- Tests for maki/lua/metronome/config.lua (REQ-20261114-17).
--
-- The host-side validator pins the same contract in Python; these tests keep
-- the Lua loader honest so the two cannot drift.

return function()
  local config = load_module("config")
  local cwd = maki.uv.cwd()

  local VALID = [[
# a comment
[project]
repo = "/tmp/repo"      # trailing comment
base_ref = "master"
max_parallel = 3

[git]
branch_prefix = "metronome/"

[roles.qualifier]
model = "ocgo/deepseek-v4.1-flash"
thinking = "high"

[roles.analyst]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"

[roles.implementer]
model = "opencode-go/kimi-k3"
thinking = "max"

[roles.reviewer]
model = "ocgo/deepseek-v4-pro"
thinking = "high"

[roles.deployer]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"

[checks]
default = ["npm test", "npm run lint"]
re_run_after_merge = true

[review]
max_rounds = 4
protected_paths = ["review-rules.md", "AGENTS.md"]

[merge]
auto_merge = true

[limits]
max_task_cost_usd = 2.5
max_questions_per_round = 15
]]

  -- Parsing -----------------------------------------------------------------

  local parsed = config.parse(VALID)
  eq(parsed.project.repo, "/tmp/repo", "string value parsed")
  eq(parsed.project.base_ref, "master", "trailing comment stripped")
  eq(parsed.project.max_parallel, 3, "integer parsed")
  eq(parsed.git.branch_prefix, "metronome/", "nested table parsed")
  eq(parsed.roles.implementer.model, "opencode-go/kimi-k3", "deeply nested table parsed")
  eq(parsed.roles.implementer.thinking, "max", "role thinking parsed")
  eq(parsed.checks.default[1], "npm test", "array first element")
  eq(parsed.checks.default[2], "npm run lint", "array second element")
  eq(parsed.checks.re_run_after_merge, true, "boolean parsed")
  eq(parsed.merge.auto_merge, true, "boolean in nested table")
  eq(parsed.limits.max_task_cost_usd, 2.5, "float parsed")
  eq(parsed.limits.max_questions_per_round, 15, "question limit parsed")

  -- A '#' inside a string is not a comment.
  local quoted = config.parse('[project]\nrepo = "/tmp/a#b"\nbase_ref = "main"\n')
  eq(quoted.project.repo, "/tmp/a#b", "hash inside a string kept")

  -- Malformed input must name the line.
  local ok1, err1 = pcall(config.parse, '[project]\nrepo = "unterminated\n')
  eq(ok1, false, "unterminated string refused")
  eq(err1 ~= nil and tostring(err1):find("line 2") ~= nil, true, "parse error names the line")

  local ok2, err2 = pcall(config.parse, '[project]\nrepo\n')
  eq(ok2, false, "line without '=' refused")
  eq(err2 ~= nil and tostring(err2):find("line 2") ~= nil, true, "missing '=' names the line")

  -- Validation --------------------------------------------------------------

  local valid, verr = config.validate(config.parse(VALID))
  eq(verr, nil, "valid config has no problems")
  eq(valid.project.max_parallel, 3, "explicit value kept")
  eq(valid.review.max_rounds, 4, "explicit review rounds kept")

  -- Defaults fill what the file leaves out.
  local minimal = config.parse([[
[project]
repo = "/tmp/repo"
base_ref = "main"

[roles.qualifier]
model = "a/b"
thinking = "high"

[roles.analyst]
model = "a/b"
thinking = "low"

[roles.implementer]
model = "a/b"
thinking = "max"

[roles.reviewer]
model = "a/b"
thinking = "high"

[roles.deployer]
model = "a/b"
thinking = "low"
]])
  local filled, ferr = config.validate(minimal)
  eq(ferr, nil, "minimal config validates")
  eq(filled.project.max_parallel, 2, "max_parallel defaulted")
  eq(filled.review.max_rounds, 3, "max_rounds defaulted")
  eq(filled.merge.auto_merge, false, "auto_merge defaults off")
  eq(filled.limits.max_questions_per_round, 15, "question limit defaults to 15")
  eq(filled.review.protected_paths[1], "review-rules.md", "protected paths defaulted")
  eq(filled.quality.variants, 1, "variants default to 1")
  eq(filled.deploy.plan_file, "deploy.md", "deploy plan defaulted")

  -- A missing role names the role.
  local missing = config.parse([[
[project]
repo = "/tmp/repo"
base_ref = "main"

[roles.qualifier]
model = "a/b"
thinking = "high"
]])
  local none, problems = config.validate(missing)
  eq(none, nil, "config missing roles is refused")
  local joined = table.concat(problems, " | ")
  has(joined, "roles.analyst is missing", "missing analyst named")
  has(joined, "roles.implementer is missing", "missing implementer named")
  has(joined, "roles.reviewer is missing", "missing reviewer named")
  has(joined, "roles.deployer is missing", "missing deployer named")

  -- A bad model spec names the field.
  local bad_model = config.parse([[
[project]
repo = "/tmp/repo"
base_ref = "main"

[roles.qualifier]
model = "not a spec"
thinking = "high"

[roles.analyst]
model = "a/b"
thinking = "low"

[roles.implementer]
model = "a/b"
thinking = "max"

[roles.reviewer]
model = "a/b"
thinking = "high"

[roles.deployer]
model = "a/b"
thinking = "low"
]])
  local bm, bmprob = config.validate(bad_model)
  eq(bm, nil, "bad model refused")
  has(table.concat(bmprob, " | "), "roles.qualifier.model", "bad model names the field")

  -- A bad thinking level names the field.
  local bad_thinking = config.parse([[
[project]
repo = "/tmp/repo"
base_ref = "main"

[roles.qualifier]
model = "a/b"
thinking = "ultra"

[roles.analyst]
model = "a/b"
thinking = "low"

[roles.implementer]
model = "a/b"
thinking = "max"

[roles.reviewer]
model = "a/b"
thinking = "high"

[roles.deployer]
model = "a/b"
thinking = "low"
]])
  local bt, btprob = config.validate(bad_thinking)
  eq(bt, nil, "bad thinking refused")
  has(table.concat(btprob, " | "), "roles.qualifier.thinking", "bad thinking names the field")

  -- A relative repo path is refused: the pipeline needs an absolute one.
  local relative = config.parse([[
[project]
repo = "repo"
base_ref = "main"
]])
  local rel, relprob = config.validate(relative)
  eq(rel, nil, "relative repo refused")
  has(table.concat(relprob, " | "), "project.repo", "relative repo names the field")

  -- Loading the shipped template through the real loader.
  local loaded, lerr = config.load(maki.fs.joinpath(cwd, "templates", "config.toml"))
  eq(lerr, nil, "shipped template loads")
  eq(loaded ~= nil and loaded.roles.implementer.thinking, "max", "template implementer thinking")
  eq(loaded ~= nil and loaded.limits.max_questions_per_round, 15, "template question limit")

  -- A missing file is reported, not raised.
  local nf, nferr = config.load(maki.fs.joinpath(cwd, "does-not-exist.toml"))
  eq(nf, nil, "missing file returns nil")
  eq(type(nferr), "table", "missing file returns problems")
  has(table.concat(nferr, " | "), "cannot read", "missing file explains itself")
end
