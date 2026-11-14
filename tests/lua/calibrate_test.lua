-- Tests for maki/lua/metronome/calibrate.lua (REQ-20261114-32).
--
-- The calibrator reads a real repository tree on disk and a real JSONL
-- feedback file, so the whole module is exercised without spending a token.
-- The base directory is left in place for inspection: the module writes no
-- journal, so tests/run-lua.sh has nothing extra to validate.

return function()
  local c = load_module("calibrate")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "calibrate")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local repo = maki.fs.joinpath(base, "repo")
  local function put(rel, text)
    local path = maki.fs.joinpath(repo, rel)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
      maki.fs.mkdir(dir, { parents = true })
    end
    maki.fs.write(path, text)
  end

  local RULE_LINE = "- Never log to the console in shipped code."

  put("AGENTS.md", "# Project rules\n\n" .. RULE_LINE .. "\n")
  put("package.json", '{"name":"demo","scripts":{"lint":"eslint .","test":"node --test","typecheck":"tsc --noEmit"}}\n')
  put(".eslintrc.json", '{"root":true}\n')
  put("src/app.js", "console.log('hi')\n")
  put("tests/app.test.js", "test('x', function () {});\n")
  put("test_math.py", "def test_add():\n    assert 1 + 1 == 2\n")
  put(".github/workflows/ci.yml", "name: ci\n")
  put("docs/guide.md", "# guide\n")
  put("node_modules/pkg/index.js", "module.exports = {};\n")
  put("review-feedback.jsonl", table.concat({
    '{"vote":"up","rule":"no-console","comment":"good catch","finding_id":"f1"}',
    '{"vote":"up","rule":"no-console","comment":"again"}',
    '{"vote":"down","rule":"no-console","comment":"too noisy"}',
    '{"vote":"down","rule":"line-length","comment":"false positive"}',
    '{"vote":"down","rule":"line-length"}',
    '{"vote":"down","rule":"line-length","comment":"still wrong"}',
    '{"not json',
    "",
    '{"vote":"up","comment":"nice review"}',
  }, "\n") .. "\n")

  -- detect ------------------------------------------------------------------

  local detected, derr = c.detect(repo)
  eq(derr, nil, "detect has no error")
  eq(type(detected), "table", "detect returns a table")
  eq(detected and detected.agents_md ~= nil, true, "detect finds AGENTS.md")
  has(detected and detected.agents_md or "", RULE_LINE, "detect keeps the AGENTS.md rule verbatim")

  local linters = {}
  for _, name in ipairs(detected and detected.linters or {}) do
    linters[name] = true
  end
  eq(linters[".eslintrc.json"], true, "detect lists .eslintrc.json")

  local commands = {}
  for _, cmd in ipairs(detected and detected.commands or {}) do
    commands[cmd] = true
  end
  eq(commands["npm run lint"], true, "commands include npm run lint")
  eq(commands["npm test"], true, "commands include npm test")
  eq(commands["npm run typecheck"], true, "commands include npm run typecheck")
  eq(#(detected and detected.commands or {}), 3, "commands are deduplicated")

  local structure = {}
  for _, name in ipairs(detected and detected.structure or {}) do
    structure[name] = true
  end
  eq(structure["src"], true, "structure includes src")
  eq(structure["tests"], true, "structure includes tests")
  eq(structure["docs"], true, "structure includes docs")
  eq(structure["node_modules"], nil, "structure excludes node_modules")

  local tests = {}
  for _, path in ipairs(detected and detected.tests or {}) do
    tests[path] = true
  end
  eq(tests["tests/app.test.js"], true, "tests include tests/app.test.js")
  eq(tests["test_math.py"], true, "tests include test_math.py")

  local ci = {}
  for _, path in ipairs(detected and detected.ci or {}) do
    ci[path] = true
  end
  eq(ci[".github/workflows/ci.yml"], true, "ci includes .github/workflows/ci.yml")

  local truncated = c.detect(repo, { max_rules = 10 })
  eq(#(truncated and truncated.agents_md or ""), 10, "max_rules truncates AGENTS.md")

  local missing, merr = c.detect(maki.fs.joinpath(base, "nope"))
  eq(missing, nil, "missing repo returns nil")
  eq(merr ~= nil and merr:find("cannot read repository", 1, true) ~= nil, true, "missing repo explains itself")

  -- feedback ----------------------------------------------------------------

  local feedback, ferr = c.feedback(maki.fs.joinpath(repo, "review-feedback.jsonl"))
  eq(ferr, nil, "feedback has no error")
  eq(feedback and feedback.skipped, 1, "feedback counts the corrupt line")
  -- The fixture holds 2 up + 1 down for no-console, 3 down for line-length
  -- and 1 unruled entry: 7 valid entries. (The request text says "total 6",
  -- but its own fixture and score assertions add up to 7.)
  eq(feedback and feedback.total, 7, "feedback counts every valid entry")
  eq(#(feedback and feedback.entries or {}), 7, "feedback keeps every valid entry")

  local nc = feedback and feedback.by_rule and feedback.by_rule["no-console"]
  eq(nc and nc.up, 2, "no-console has two up votes")
  eq(nc and nc.down, 1, "no-console has one down vote")
  eq(nc and nc.score, 1, "no-console scores 1")
  eq(#(nc and nc.comments or {}), 3, "no-console keeps its comments")

  local ll = feedback and feedback.by_rule and feedback.by_rule["line-length"]
  eq(ll and ll.up, 0, "line-length has no up vote")
  eq(ll and ll.down, 3, "line-length has three down votes")
  eq(ll and ll.score, -3, "line-length scores -3")

  local unruled = feedback and feedback.by_rule and feedback.by_rule["(unruled)"]
  eq(unruled ~= nil, true, "entries without a rule are grouped under (unruled)")
  eq(unruled and unruled.up, 1, "the unruled entry is counted")

  local empty_feedback, eferr = c.feedback(maki.fs.joinpath(base, "absent.jsonl"))
  eq(eferr, nil, "a missing feedback file is not an error")
  eq(empty_feedback and empty_feedback.total, 0, "missing feedback has no entries")
  eq(empty_feedback and empty_feedback.skipped, 0, "missing feedback skips nothing")
  eq(type(empty_feedback and empty_feedback.by_rule), "table", "missing feedback still has a by_rule map")

  -- render ------------------------------------------------------------------

  local markdown = c.render(detected, feedback)
  eq(type(markdown), "string", "render returns a string")
  has(markdown, "# Review rules", "render has the title")
  has(markdown, "## Project rules", "render has the project rules section")
  has(markdown, RULE_LINE, "render carries the AGENTS.md rule")
  has(markdown, "## Linters", "render has the linters section")
  has(markdown, ".eslintrc.json", "render carries the linter")
  has(markdown, "## Commands", "render has the commands section")
  has(markdown, "npm run lint", "render carries the commands")
  has(markdown, "## Structure", "render has the structure section")
  has(markdown, "## Tests", "render has the tests section")
  has(markdown, "## CI", "render has the CI section")
  has(markdown, "## Protected paths", "render has the protected paths section")
  has(markdown, "review-rules.md", "render carries the default protected paths")
  has(markdown, "always blocking", "render says protected paths are always blocking")
  has(markdown, "## Calibration feedback", "render has the calibration section")
  has(markdown, "- no-console: up=2 down=1 — keep flagging", "no-console is marked keep flagging")
  has(markdown, "- line-length: up=0 down=3 — de-emphasize", "line-length is marked de-emphasize")
  has(markdown, "false positive", "render carries a feedback comment")
  eq(markdown:find("%d%d%d%d%-%d%d%-%d%d") == nil, true, "render carries no timestamp")
  eq(c.render(detected, feedback), markdown, "render is deterministic")

  local custom = c.render(detected, feedback, { protected_paths = { "release.md" } })
  has(custom, "release.md", "render honors custom protected paths")
  eq(custom:find("review-rules.md", 1, true) ~= nil, false, "custom protected paths replace the defaults")

  local no_feedback = c.render(detected, nil)
  eq(no_feedback:find("## Calibration feedback", 1, true), nil, "render omits calibration without feedback")

  local no_agents = c.render({ linters = {}, commands = {}, structure = {}, tests = {}, ci = {} }, nil)
  has(no_agents, "No AGENTS.md found.", "render says when AGENTS.md is absent")
  has(no_agents, "None detected.", "render says when nothing is detected")

  -- generate ----------------------------------------------------------------

  local generated, gerr = c.generate(repo)
  eq(gerr, nil, "generate has no error")
  eq(type(generated and generated.markdown), "string", "generate returns markdown")
  eq(type(generated and generated.detected), "table", "generate returns the detection")
  eq(type(generated and generated.feedback), "table", "generate returns the feedback")
  eq(generated and generated.feedback.total, 7, "generate reads the default feedback path")

  -- write -------------------------------------------------------------------

  local written, werr = c.write(repo)
  eq(werr, nil, "write has no error")
  eq(written, maki.fs.joinpath(repo, "review-rules.md"), "write returns the output path")
  local on_disk = maki.fs.read(maki.fs.joinpath(repo, "review-rules.md"))
  eq(type(on_disk), "string", "write creates review-rules.md")
  has(on_disk or "", RULE_LINE, "the written rules carry the AGENTS.md rule")

  local dry_path = maki.fs.joinpath(base, "dry.md")
  local dry, dryerr = c.write(repo, { output = dry_path, dry_run = true })
  eq(dryerr, nil, "dry-run write has no error")
  eq(dry, dry_path, "dry-run write returns the output path")
  eq(maki.fs.read(dry_path), nil, "dry-run writes nothing")

  -- run ---------------------------------------------------------------------

  local run_path = maki.fs.joinpath(base, "run-rules.md")
  local ran = c.run({ repo = repo, output = run_path })
  eq(ran and ran.ok, true, "run succeeds")
  eq(ran and ran.written, true, "run reports written=true")
  eq(ran and ran.path, run_path, "run returns the output path")
  eq(type(ran and ran.markdown), "string", "run returns the markdown")
  eq(type(ran and ran.detected), "table", "run returns the detection")
  eq(type(ran and ran.feedback), "table", "run returns the feedback")
  eq(type(maki.fs.read(run_path)), "string", "run writes the file")

  local dry_run = c.run({ repo = repo, output = dry_path, dry_run = true })
  eq(dry_run and dry_run.ok, true, "dry run succeeds")
  eq(dry_run and dry_run.written, false, "dry run reports written=false")
  eq(maki.fs.read(dry_path), nil, "dry run leaves no file")

  local bad_run = c.run({})
  eq(bad_run and bad_run.ok, false, "run without a repo fails")
  eq(bad_run and bad_run.error ~= nil, true, "run without a repo explains itself")
end
