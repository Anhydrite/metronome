-- Tests for maki/lua/metronome/qualify.lua (REQ-20261114-23).
--
-- The qualifier is exercised end to end without spending a token: the runner
-- is injected, the repository is a real directory tree on disk, and the state
-- journal it writes is validated by tests/run-lua.sh afterwards.

return function()
  local q = load_module("qualify")
  local state = load_module("state")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "qualify")

  -- Remove only what we must: a previous run must not pollute this one.
  local function wipe(path)
    local entries = maki.fs.dir(path)
    if entries then
      for _, e in ipairs(entries) do
        local name = e.name or e[1]
        local kind = e.kind or e[2]
        local child = maki.fs.joinpath(path, name)
        if kind == "directory" then
          wipe(child)
        else
          maki.fs.rm(child)
        end
      end
    end
    maki.fs.rm(path)
  end

  wipe(base)
  maki.fs.mkdir(base, { parents = true })

  -- A tiny repository with the traps the walker must avoid.
  local repo = maki.fs.joinpath(base, "repo")
  local function put(rel, text)
    local path = maki.fs.joinpath(repo, rel)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
      maki.fs.mkdir(dir, { parents = true })
    end
    maki.fs.write(path, text)
  end
  put("README.md", "# Demo\n\nA demo repository.\n")
  put("package.json", '{"name":"demo"}\n')
  put("src/app.js", "console.log('hi')\n")
  put(".git/config", "[core]\n")
  put("node_modules/pkg/index.js", "module.exports = {}\n")

  local root = maki.fs.joinpath(base, "state")

  -- repo_context -----------------------------------------------------------

  local ctx, cerr = q.repo_context(repo)
  eq(cerr, nil, "repo_context has no error")
  eq(type(ctx), "table", "repo_context returns a table")
  eq(ctx and ctx.root, repo, "repo_context keeps the root")
  eq(ctx and ctx.truncated, false, "small repo is not truncated")

  local listed = {}
  for _, f in ipairs(ctx and ctx.files or {}) do
    listed[f] = true
  end
  eq(listed["README.md"], true, "files include README.md")
  eq(listed["package.json"], true, "files include package.json")
  eq(listed["src/app.js"], true, "files include src/app.js")
  eq(listed[".git/config"], nil, "files exclude .git")
  eq(listed["node_modules/pkg/index.js"], nil, "files exclude node_modules")

  local excerpt_paths = {}
  for _, ex in ipairs(ctx and ctx.excerpts or {}) do
    excerpt_paths[ex.path] = ex.text
  end
  eq(excerpt_paths["README.md"] ~= nil, true, "excerpts contain README.md")
  eq(excerpt_paths["package.json"] ~= nil, true, "excerpts contain package.json")
  eq(type(excerpt_paths["README.md"]), "string", "excerpt text is a string")

  local capped, caperr = q.repo_context(repo, { max_files = 1 })
  eq(caperr, nil, "capped walk has no error")
  eq(#(capped and capped.files or {}), 1, "max_files caps the file list")
  eq(capped and capped.truncated, true, "hitting the cap sets truncated")

  local none, nerr = q.repo_context(nil)
  eq(none, nil, "nil repo returns nil")
  eq(nerr, "no repository path", "nil repo explains itself")

  local empty_repo, eerr = q.repo_context("")
  eq(empty_repo, nil, "empty repo returns nil")
  eq(eerr, "no repository path", "empty repo explains itself")

  local missing, merr = q.repo_context(maki.fs.joinpath(base, "nope"))
  eq(missing, nil, "missing repo returns nil")
  eq(merr ~= nil and merr:find("cannot read repository", 1, true) ~= nil, true, "missing repo explains itself")

  -- repo_context from a git ref --------------------------------------------
  --
  -- The pipeline reads `origin/<base>`, not the working directory: a diverged
  -- local checkout must not shape a task sheet. A fake git module proves the
  -- contract without a repository, and the file list must be exactly what the
  -- ref lists, sorted, with excerpts read from the same ref.

  local calls = { ls = {}, show = {} }
  local fake_git = {}
  function fake_git.ls_tree(_, ref)
    calls.ls[#calls.ls + 1] = ref
    if ref ~= "origin/main" then
      return nil, "unknown ref " .. tostring(ref)
    end
    return { "src/app.js", "README.md", "package.json" }
  end
  function fake_git.show_file(_, ref, path)
    calls.show[#calls.show + 1] = ref .. ":" .. path
    if ref ~= "origin/main" then
      return nil, "unknown ref " .. tostring(ref)
    end
    if path == "README.md" then
      return "# Committed\n"
    end
    return nil, "missing " .. path
  end

  local refctx, refcerr = q.repo_context(repo, { ref = "origin/main", git = fake_git })
  eq(refcerr, nil, "ref context has no error: " .. tostring(refcerr))
  eq(refctx and refctx.ref, "origin/main", "ref context records the ref")
  eq(refctx and refctx.root, repo, "ref context keeps the root")
  eq(#calls.ls, 1, "ls_tree is called once")
  eq(calls.ls[1], "origin/main", "ls_tree reads the requested ref")
  local ref_files = table.concat(refctx and refctx.files or {}, ",")
  eq(ref_files, "README.md,package.json,src/app.js", "ref file list is sorted")
  eq((refctx and #refctx.excerpts or 0) >= 1, true, "ref context excerpts at least one file")
  local ref_excerpt = refctx and refctx.excerpts[1] or {}
  eq(ref_excerpt.path, "README.md", "preferred file is excerpted first")
  eq(ref_excerpt.text, "# Committed\n", "excerpt comes from the ref, not the working tree")

  local ref_capped, ref_caperr = q.repo_context(repo, {
    ref = "origin/main",
    git = fake_git,
    max_files = 2,
  })
  eq(ref_caperr, nil, "capped ref context has no error")
  eq(#(ref_capped and ref_capped.files or {}), 2, "ref list honours max_files")
  eq(ref_capped and ref_capped.truncated, true, "ref list sets truncated at the cap")

  local bad_ref, bad_ref_err = q.repo_context(repo, { ref = "origin/nope", git = fake_git })
  eq(bad_ref, nil, "an unknown ref returns nil")
  eq(bad_ref_err, "unknown ref origin/nope", "the git error is propagated")

  local no_git, no_git_err = q.repo_context(repo, { ref = "origin/main" })
  eq(no_git, nil, "ref without the git module returns nil")
  eq(no_git_err ~= nil and no_git_err:find("git module", 1, true) ~= nil, true, "the refusal names the missing module")

  local empty_ref, empty_ref_err = q.repo_context(repo, { ref = "", git = fake_git })
  eq(empty_ref, nil, "empty ref returns nil")
  eq(empty_ref_err ~= nil and empty_ref_err:find("non-empty", 1, true) ~= nil, true, "empty ref explains itself")

  -- A ref context reaches the prompt, and says which tree it describes.
  local ref_prompt = q.build_prompt("add a thing", refctx, {})
  has(ref_prompt, "Ref: origin/main", "the prompt names the ref")
  has(ref_prompt, "- src/app.js", "the prompt lists ref files")
  has(ref_prompt, "# Committed", "the prompt carries ref excerpts")

  -- extract_json -----------------------------------------------------------

  local fenced = q.extract_json('```json\n{"a":1}\n```')
  eq(fenced and fenced.a, 1, "fenced JSON decoded")

  local fenced_bare = q.extract_json('```\n{"b":2}\n```')
  eq(fenced_bare and fenced_bare.b, 2, "fenced JSON without a language tag decoded")

  local prose = q.extract_json('Here is the answer:\n{"c":3}\nThanks.')
  eq(prose and prose.c, 3, "JSON surrounded by prose decoded")

  local braces = q.extract_json('{"s":"a } b { c","n":4}')
  eq(braces and braces.s, "a } b { c", "braces inside strings do not break the slice")
  eq(braces and braces.n, 4, "field after a braced string decoded")

  local escaped = q.extract_json('{"s":"quote \\" and } brace"}')
  eq(escaped and escaped.s, 'quote " and } brace', "escaped quotes do not break the slice")

  local bad, baderr = q.extract_json("{nope")
  eq(bad, nil, "invalid JSON returns nil")
  eq(baderr ~= nil and baderr:find("invalid JSON", 1, true) ~= nil, true, "invalid JSON explains itself")

  local notext, notexterr = q.extract_json(nil)
  eq(notext, nil, "nil text returns nil")
  eq(notexterr, "no text", "nil text explains itself")

  -- normalize --------------------------------------------------------------

  local payload = {
    tasks = {
      {
        title = "  First task  ",
        intent = "do the first thing",
        files = { "a.lua", "b.lua" },
        checks = { "make test" },
        acceptance = { "the first thing works" },
        depends_on = { "T-20261114-0001" },
        questions = { { text = "why?" } },
      },
      {
        title = "Second task",
        files = { "c.lua" },
        checks = { "make lint" },
      },
    },
    questions = { { id = "top1", text = "top level?" } },
  }
  local norm, nerr2 = q.normalize(payload, { max_questions = 15 })
  eq(nerr2, nil, "normalize accepts a two-task payload")
  eq(#(norm and norm.tasks or {}), 2, "normalize keeps both tasks")
  eq(norm and norm.tasks[1].title, "First task", "title is trimmed")
  eq(norm and norm.tasks[1].files[1], "a.lua", "files kept")
  eq(norm and norm.tasks[1].checks[1], "make test", "checks kept")
  eq(norm and norm.tasks[1].acceptance[1], "the first thing works", "acceptance kept")
  eq(norm and norm.tasks[1].depends_on[1], "T-20261114-0001", "depends_on kept")
  eq(norm and norm.tasks[1].intent, "do the first thing", "intent kept")
  eq(#(norm and norm.tasks[2].acceptance or {}), 0, "acceptance defaults to empty")
  eq(#(norm and norm.tasks[2].depends_on or {}), 0, "depends_on defaults to empty")
  eq(norm and norm.tasks[1].questions[1].id, "q1", "missing question id is generated")
  eq(norm and norm.tasks[1].questions[2].id, "top1", "top-level question lands on the first task")
  eq(#(norm and norm.questions or {}), 2, "global question list holds both")
  eq(norm and norm.truncated_questions, 0, "nothing truncated")

  local nofiles, nofileserr = q.normalize({ tasks = { { title = "x", checks = { "c" } } } })
  eq(nofiles, nil, "missing files returns nil")
  eq(nofileserr ~= nil and nofileserr:find("task 1: files must be a non-empty array", 1, true) ~= nil, true, "missing files explains itself")

  local nochecks, nocheckserr = q.normalize({ tasks = { { title = "x", files = { "f" } } } })
  eq(nochecks, nil, "missing checks returns nil")
  eq(nocheckserr ~= nil and nocheckserr:find("task 1: checks must be a non-empty array", 1, true) ~= nil, true, "missing checks explains itself")

  local longtitle, longtitleerr = q.normalize({ tasks = { { title = string.rep("a", 201), files = { "f" }, checks = { "c" } } } })
  eq(longtitle, nil, "over-long title returns nil")
  eq(longtitleerr ~= nil and longtitleerr:find("longer than 200", 1, true) ~= nil, true, "over-long title explains itself")

  local noqtext, noqtexterr = q.normalize({ tasks = { { title = "x", files = { "f" }, checks = { "c" }, questions = { { id = "q" } } } } })
  eq(noqtext, nil, "question without text returns nil")
  eq(noqtexterr ~= nil and noqtexterr:find("question 1 has no text", 1, true) ~= nil, true, "question without text explains itself")

  local many = { tasks = { { title = "many", files = { "f" }, checks = { "c" }, questions = {} } } }
  for i = 1, 20 do
    many.tasks[1].questions[i] = { id = "q" .. i, text = "question " .. i }
  end
  local cappedq, cappedqerr = q.normalize(many, { max_questions = 15 })
  eq(cappedqerr, nil, "20 questions normalizes")
  eq(#(cappedq and cappedq.tasks[1].questions or {}), 15, "questions are capped at 15")
  eq(#(cappedq and cappedq.questions or {}), 15, "global list is capped at 15")
  eq(cappedq and cappedq.truncated_questions, 5, "the excess is reported")

  local kept_id = q.normalize({ tasks = { { id = "T-20261114-abcd", title = "kept", files = { "f" }, checks = { "c" } } } })
  eq(kept_id and kept_id.tasks[1].id, "T-20261114-abcd", "a valid id is kept")

  local dropped_id = q.normalize({ tasks = { { id = "nonsense", title = "dropped", files = { "f" }, checks = { "c" } } } })
  eq(dropped_id and dropped_id.tasks[1].id, nil, "an invalid id is dropped")

  local with_intent = q.normalize({ tasks = { { title = "t", files = { "f" }, checks = { "c" } } } }, { intention = "the intention" })
  eq(with_intent and with_intent.tasks[1].intent, "the intention", "intent falls back to the intention")
  eq(with_intent and with_intent.tasks[1].origin, "the intention", "origin carries the submitted intention")

  local detailed = q.normalize({
    tasks = { { title = "t", intent = "detail of the work", files = { "f" }, checks = { "c" } } },
  }, { intention = "the ask" })
  eq(detailed and detailed.tasks[1].intent, "detail of the work", "intent keeps the qualifier's detail")
  eq(detailed and detailed.tasks[1].origin, "the ask", "origin stays the user's ask")

  local notasks, notaskserr = q.normalize({ tasks = {} })
  eq(notasks, nil, "empty tasks returns nil")
  eq(notaskserr ~= nil, true, "empty tasks explains itself")

  -- build_prompt -----------------------------------------------------------

  local prompt = q.build_prompt("Add a login page", ctx, { max_questions = 15 })
  eq(type(prompt), "string", "build_prompt returns a string")
  has(prompt, "Add a login page", "prompt carries the intention")
  has(prompt, repo, "prompt carries the repository path")
  has(prompt, "At most 15 questions in total.", "prompt states the question cap")
  has(prompt, "## Intention (verbatim)", "prompt has the intention section")
  has(prompt, "## Repository", "prompt has the repository section")
  has(prompt, "## Output contract", "prompt has the output contract")

  -- run --------------------------------------------------------------------

  local session_opts = { system = "sys", model_spec = "test/model", thinking = "low", tools = {} }
  local valid_answer = '```json\n{"tasks":[{"title":"Add login","intent":"add login","files":["src/app.js"],"checks":["npm test"],"acceptance":["login works"],"depends_on":[],"questions":[]}]}\n```'

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

  local runner_a, calls_a = scripted({ { text = valid_answer, cost = 0.25 } })
  local ran_a = q.run({ intention = "add login", runner = runner_a, session_opts = session_opts, repo = repo })
  eq(ran_a and ran_a.ok, true, "run succeeds on a valid first answer")
  eq(ran_a and ran_a.attempts, 1, "run records one attempt")
  eq(ran_a and ran_a.cost, 0.25, "run accumulates cost")
  eq(#(ran_a and ran_a.tasks or {}), 1, "run returns the normalized tasks")
  eq(ran_a and ran_a.tasks[1].title, "Add login", "run returns the task title")
  eq(calls_a[1] and calls_a[1].role, "qualifier", "runner is called as the qualifier")
  eq(calls_a[1] and calls_a[1].phase, "qualify", "runner is called in the qualify phase")
  eq(calls_a[1] and calls_a[1].system, "sys", "runner receives the system prompt")
  eq(calls_a[1] and calls_a[1].model_spec, "test/model", "runner receives the model spec")

  local runner_b, calls_b = scripted({ { text = "this is not json" }, { text = valid_answer } })
  local ran_b = q.run({ intention = "add login", runner = runner_b, session_opts = session_opts, repo = repo })
  eq(ran_b and ran_b.ok, true, "run recovers from an invalid first answer")
  eq(ran_b and ran_b.attempts, 2, "run records two attempts")
  eq(calls_b[2] ~= nil and calls_b[2].prompt:find("could not be used", 1, true) ~= nil, true, "the repair prompt says the answer was unusable")
  has(calls_b[2] and calls_b[2].prompt or "", "add login", "the repair prompt carries the intention")

  local runner_c, calls_c = scripted({ { text = "nope" }, { text = "still nope" } })
  local ran_c = q.run({ intention = "add login", runner = runner_c, session_opts = session_opts, repo = repo })
  eq(ran_c and ran_c.ok, false, "run fails after the repair budget")
  eq(ran_c and ran_c.error ~= nil and ran_c.error:find("invalid after repair", 1, true) ~= nil, true, "the failure names the repair")
  eq(ran_c and ran_c.attempts, 2, "the failed run records both attempts")
  eq(ran_c and ran_c.raw, "still nope", "the failed run keeps the last answer")

  local runner_d, _ = scripted({ { ok = false, error = "upstream 500" } })
  local ran_d = q.run({ intention = "add login", runner = runner_d, session_opts = session_opts, repo = repo })
  eq(ran_d and ran_d.ok, false, "a failed runner fails the run")
  eq(ran_d and ran_d.error, "upstream 500", "the runner error is propagated")

  local ran_e = q.run({ intention = "", runner = runner_a, session_opts = session_opts })
  eq(ran_e and ran_e.ok, false, "an empty intention is refused")

  -- next_id ----------------------------------------------------------------

  eq(q.next_id({ tasks = {} }, "20261114"), "T-20261114-0001", "next_id starts at 0001")
  eq(q.next_id({ tasks = { ["T-20261114-0001"] = {} } }, "20261114"), "T-20261114-0002", "next_id skips an existing id")
  eq(q.next_id({ tasks = { ["T-20261114-0001"] = {}, ["T-20261114-0002"] = {} } }, "20261114"), "T-20261114-0003", "next_id skips two existing ids")
  eq(q.next_id({ tasks = { ["T-20261113-0001"] = {} } }, "20261114"), "T-20261114-0001", "next_id ignores another date")

  -- apply ------------------------------------------------------------------

  local apply_payload = {
    tasks = {
      {
        title = "First task",
        intent = "intent one",
        files = { "src/app.js" },
        checks = { "npm test" },
        acceptance = { "the first task works" },
        questions = { { id = "q1", text = "Which auth?" } },
      },
      {
        title = "Second task",
        intent = "intent two",
        files = { "package.json" },
        checks = { "npm run lint" },
      },
    },
  }
  local apply_norm = q.normalize(apply_payload, { max_questions = 15 })
  local apply_result = {
    ok = true,
    tasks = apply_norm.tasks,
    questions = apply_norm.questions,
    truncated_questions = apply_norm.truncated_questions,
  }

  local applied, aerr = q.apply(state, root, apply_result, {})
  eq(aerr, nil, "apply has no error")
  eq(#(applied and applied.tasks or {}), 2, "apply creates two tasks")
  eq(applied and applied.tasks[1].status, "awaiting_answers", "a task with questions awaits answers")
  eq(applied and applied.tasks[2].status, "ready", "a task without questions is ready")

  local id1 = applied and applied.tasks[1].id
  local id2 = applied and applied.tasks[2].id
  eq(type(id1), "string", "first id is a string")
  eq(id1 ~= nil and id1:match("^T%-%d%d%d%d%d%d%d%d%-%x%x%x%x$") ~= nil, true, "first id matches the pattern")
  eq(id2 ~= nil and id2:match("^T%-%d%d%d%d%d%d%d%d%-%x%x%x%x$") ~= nil, true, "second id matches the pattern")
  eq(id1 ~= id2, true, "ids are unique")

  local sheet1 = maki.fs.read(maki.fs.joinpath(root, "tasks", id1 .. ".md"))
  local sheet2 = maki.fs.read(maki.fs.joinpath(root, "tasks", id2 .. ".md"))
  eq(type(sheet1), "string", "first sheet exists")
  eq(type(sheet2), "string", "second sheet exists")
  has(sheet1 or "", "First task", "first sheet carries the title")
  has(sheet1 or "", "src/app.js", "first sheet carries the files")
  has(sheet1 or "", "npm test", "first sheet carries the checks")
  has(sheet1 or "", "Which auth?", "first sheet carries the questions")
  has(sheet2 or "", "Second task", "second sheet carries the title")

  local loaded = state.load(root)
  eq(loaded.tasks[id1] and loaded.tasks[id1].files[1], "src/app.js", "state keeps the files")
  eq(loaded.tasks[id1] and loaded.tasks[id1].checks[1], "npm test", "state keeps the checks")
  eq(loaded.tasks[id1] and loaded.tasks[id1].questions[1].id, "q1", "state keeps the questions")
  eq(loaded.tasks[id2] and loaded.tasks[id2].status, "ready", "state keeps the final status")

  local dup_result = {
    ok = true,
    tasks = { { title = "Duplicate", files = { "x" }, checks = { "y" } } },
    questions = {},
    truncated_questions = 0,
  }
  local dup, duperr = q.apply(state, root, dup_result, { id_factory = function() return id1 end })
  eq(dup, nil, "apply refuses an existing id")
  eq(duperr ~= nil and duperr:find("already exists", 1, true) ~= nil, true, "the refusal explains itself")

  local failed_apply, failed_err = q.apply(state, root, { ok = false, error = "nope" }, {})
  eq(failed_apply, nil, "apply refuses an unsuccessful result")
  eq(failed_err, "cannot apply an unsuccessful qualification", "the refusal is explicit")
end
