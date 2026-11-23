-- Tests for the schema constraint on the qualifier (REQ-20261114-24).
--
-- REQ-23 gave the qualifier a structural normalization and a one-shot repair
-- pass. This file proves the missing half: the answer is validated against the
-- REAL schemas/task.schema.json, through tools/validate-task.py, and a
-- schema-illegal answer triggers the same repair pass a broken JSON answer
-- does. The projection is the object the schema actually governs, so
-- `acceptance` (which the schema forbids) never reaches the validator.

return function()
  local q = load_module("qualify")

  -- test_dir() empties and recreates the per-test workspace, so two runs (or
  -- two tests) never share a journal, a temporary repository or a worktree.
  local base = test_dir("qualify-schema")
  local validate_tmp = maki.fs.joinpath(base, "validate-tmp")

  -- task_projection ---------------------------------------------------------

  local with_acceptance = {
    title = "Add login",
    intent = "add login",
    files = { "src/app.js" },
    checks = { "npm test" },
    acceptance = { "login works" },
  }
  local proj = q.task_projection(with_acceptance)
  eq(type(proj), "table", "task_projection returns a table")
  eq(proj.acceptance, nil, "the projection omits acceptance")
  eq(proj.status, "draft", "the projection defaults status to draft")
  eq(type(proj.id), "string", "the projection has an id")
  eq(
    proj.id:match("^T%-%d%d%d%d%d%d%d%d%-[a-z0-9][a-z0-9][a-z0-9][a-z0-9]$") ~= nil,
    true,
    "the placeholder id matches the schema pattern"
  )
  eq(proj.title, "Add login", "the projection keeps the title")
  eq(proj.intent, "add login", "the projection keeps the intent")
  eq(proj.files[1], "src/app.js", "the projection keeps files")
  eq(proj.checks[1], "npm test", "the projection keeps checks")
  eq(proj.depends_on, nil, "an empty depends_on is omitted")
  eq(proj.questions, nil, "empty questions are omitted")

  local kept = q.task_projection({ id = "T-20261114-abcd", title = "t", files = { "f" }, checks = { "c" } })
  eq(kept.id, "T-20261114-abcd", "a valid id is kept in the projection")

  local full = q.task_projection({
    title = "t",
    files = { "f" },
    checks = { "c" },
    depends_on = { "T-20261113-0001" },
    questions = { { id = "q1", text = "why?" } },
  })
  eq(full.depends_on and full.depends_on[1], "T-20261113-0001", "a non-empty depends_on is kept")
  eq(full.questions and full.questions[1].id, "q1", "non-empty questions are kept")

  -- validate_projection: fake validator ------------------------------------

  local okv, verr = q.validate_projection({ id = "T-20261114-abcd" }, {
    validator = function()
      return true, nil
    end,
  })
  eq(okv, true, "a passing fake validator returns true")
  eq(verr, nil, "a passing fake validator returns no error")

  local badv, badverr = q.validate_projection({}, {
    validator = function()
      return nil, "schema says no"
    end,
  })
  eq(badv, nil, "a failing fake validator returns nil")
  eq(badverr, "schema says no", "the fake validator error propagates")

  -- validate_projection: the real Python validator -------------------------

  local legal = q.task_projection({
    title = "Add login",
    intent = "add login",
    files = { "src/app.js" },
    checks = { "npm test" },
  })
  local rok, rerr = q.validate_projection(legal, { tmp_dir = validate_tmp })
  eq(rok, true, "the real validator accepts a legal projection: " .. tostring(rerr))
  eq(rerr, nil, "the real validator returns no error for a legal projection")

  local illegal = {
    id = "T-20261114-abcd",
    title = "t",
    status = "draft",
    files = { "f" },
    checks = { "c" },
    acceptance = { "works" },
  }
  local iok, ierr = q.validate_projection(illegal, { tmp_dir = validate_tmp })
  eq(iok, nil, "the real validator rejects an acceptance field")
  eq(ierr ~= nil and ierr:find("task.schema.json", 1, true) ~= nil, true, "the rejection names the schema")
  eq(ierr ~= nil and ierr:find("acceptance", 1, true) ~= nil, true, "the rejection names the extra property")

  local bidok, biderr = q.validate_projection(
    { id = "bad", title = "t", status = "draft", files = { "f" }, checks = { "c" } },
    { tmp_dir = validate_tmp }
  )
  eq(bidok, nil, "the real validator rejects an id that does not match the pattern")
  eq(biderr ~= nil and biderr:find("task.schema.json", 1, true) ~= nil, true, "the id rejection names the schema")

  -- run --------------------------------------------------------------------

  local session_opts = { system = "sys", model_spec = "test/model", thinking = "low", tools = {} }
  local answer = '```json\n{"tasks":[{"title":"Add login","intent":"add login","files":["src/app.js"],"checks":["npm test"],"acceptance":["login works"]}]}\n```'

  local function scripted(steps)
    local calls = {}
    local i = 0
    local fn = function(opts)
      i = i + 1
      calls[i] = opts
      local step = steps[i] or steps[#steps]
      if step.ok == false then
        return { ok = false, error = step.error or "boom", attempts = 1, cost = step.cost or 0 }
      end
      return { ok = true, text = step.text, attempts = 1, cost = step.cost or 0 }
    end
    return fn, calls
  end

  -- A validator that rejects the first attempt and accepts the second: the
  -- same repair pass that handles broken JSON must handle a schema refusal.
  local seen = 0
  local stateful = function()
    seen = seen + 1
    if seen == 1 then
      return nil, "schema says no"
    end
    return true, nil
  end
  local runner_s, calls_s = scripted({ { text = answer }, { text = answer } })
  local ran_s = q.run({
    intention = "add login",
    runner = runner_s,
    session_opts = session_opts,
    validator = stateful,
  })
  eq(ran_s and ran_s.ok, true, "run repairs a schema-rejected answer")
  eq(ran_s and ran_s.attempts, 2, "the schema rejection costs one repair")
  eq(seen, 2, "the validator saw both attempts")
  has(calls_s[2] and calls_s[2].prompt or "", "could not be used", "the repair prompt says the answer was unusable")
  has(calls_s[2] and calls_s[2].prompt or "", "schema says no", "the repair prompt carries the validator error")

  -- The default path: no fake validator, the real Python one runs.
  local runner_p, _ = scripted({ { text = answer } })
  local ran_p = q.run({
    intention = "add login",
    runner = runner_p,
    session_opts = session_opts,
    tmp_dir = validate_tmp,
  })
  eq(ran_p and ran_p.ok, true, "run validates with the real schema by default")
  eq(ran_p and ran_p.attempts, 1, "a schema-legal answer needs no repair")

  -- The explicit opt-out: validate=false must skip the validator entirely.
  local reject_all = function()
    return nil, "schema says no"
  end
  local runner_o, _ = scripted({ { text = answer } })
  local ran_o = q.run({
    intention = "add login",
    runner = runner_o,
    session_opts = session_opts,
    validator = reject_all,
    validate = false,
  })
  eq(ran_o and ran_o.ok, true, "validate=false opts out of schema validation")
  eq(ran_o and ran_o.attempts, 1, "the opt-out needs no repair")
end
