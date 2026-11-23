-- Tests for maki/lua/metronome/questions.lua (REQ-20261114-25).
--
-- The question loop is exercised in two halves: the pure functions (dedup,
-- collect, synthesize) on hand-built tables, and the stateful half (round,
-- answer) on a real state root whose journal tests/run-lua.sh validates
-- afterwards. Nothing here spends a token: the state module is injected.

return function()
  local questions = load_module("questions")
  local qualify = load_module("qualify")
  local state = load_module("state")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "questions")

  -- Remove only what we must: a previous run must not pollute this one. The
  -- base itself is kept, because run-lua.sh validates the journal left in it.
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

  local root = maki.fs.joinpath(base, "state")
  local journal_path = maki.fs.joinpath(root, "state.jsonl")
  local tasks_dir = maki.fs.joinpath(root, "tasks")

  -- The sheet a task starts with. Every answer the loop applies must rewrite
  -- this file, through the same renderer qualify.apply used.
  local function sheet_path(id)
    return maki.fs.joinpath(tasks_dir, id .. ".md")
  end

  local function write_sheet(id)
    local task = state.load(root).tasks[id]
    return maki.fs.write(sheet_path(id), qualify.sheet_markdown(task))
  end

  maki.fs.mkdir(tasks_dir, { parents = true })

  -- Every answer call injects the one sheet renderer and the sheet directory:
  -- questions.answer refuses to run without them.
  local function answer_opts(extra)
    local opts = { qualify = qualify, tasks_dir = tasks_dir }
    for key, value in pairs(extra or {}) do
      opts[key] = value
    end
    return opts
  end

  -- dedup_key --------------------------------------------------------------

  eq(questions.MAX_PER_ROUND_DEFAULT, 15, "the per-round cap defaults to 15")
  eq(questions.dedup_key("  Which AUTH?  "), "which auth", "dedup_key lowercases, trims and strips punctuation")
  eq(questions.dedup_key("which auth"), "which auth", "dedup_key keeps an already-normal key")
  eq(questions.dedup_key("  Which AUTH?  "), questions.dedup_key("which auth"), "two variants share one key")
  eq(questions.dedup_key("Which\n\tAUTH   now?!"), "which auth now", "dedup_key collapses whitespace")
  eq(questions.dedup_key("What.now."), "what.now", "dedup_key only strips trailing punctuation")
  eq(questions.dedup_key(nil), "", "nil is an empty key")
  eq(questions.dedup_key(42), "", "a number is an empty key")
  eq(questions.dedup_key({}), "", "a table is an empty key")

  -- collect ----------------------------------------------------------------

  local synthetic = {
    tasks = {
      ["T-20261114-0001"] = {
        id = "T-20261114-0001",
        status = "awaiting_answers",
        created_at = "2026-11-14T00:00:01Z",
        questions = {
          { id = "q1", text = "Which AUTH?" },
          { id = "q2", text = "Which database?" },
        },
      },
      ["T-20261114-0002"] = {
        id = "T-20261114-0002",
        status = "awaiting_answers",
        created_at = "2026-11-14T00:00:02Z",
        questions = { { id = "q1", text = "Which AUTH?" } },
      },
      ["T-20261114-0003"] = {
        id = "T-20261114-0003",
        status = "ready",
        created_at = "2026-11-14T00:00:03Z",
        questions = { { id = "q1", text = "Should be ignored?" } },
      },
      ["T-20261114-0004"] = {
        id = "T-20261114-0004",
        status = "awaiting_answers",
        created_at = "2026-11-14T00:00:04Z",
        questions = { { id = "q1", text = "Already answered?", answer = "yes" } },
      },
    },
  }

  local pending = questions.collect(synthetic)
  eq(#pending, 3, "collect keeps the three unanswered questions")
  eq(pending[1].task_id, "T-20261114-0001", "collect sorts tasks by id")
  eq(pending[1].question_id, "q1", "collect keeps the question id")
  eq(pending[1].index, 1, "collect records the question index")
  eq(pending[1].text, "Which AUTH?", "collect keeps the text verbatim")
  eq(pending[1].created_at, "2026-11-14T00:00:01Z", "collect carries created_at")
  eq(pending[2].question_id, "q2", "collect keeps the second question")
  eq(pending[2].index, 2, "collect records the second index")
  eq(pending[3].task_id, "T-20261114-0002", "the duplicate-text question is still collected")
  eq(pending[3].text, "Which AUTH?", "the duplicate keeps its own text")
  eq(#questions.collect({ tasks = {} }), 0, "collect on an empty state is empty")
  eq(#questions.collect(nil), 0, "collect on nil is empty")

  local no_id = questions.collect({
    tasks = {
      ["T-20261114-0005"] = {
        id = "T-20261114-0005",
        status = "awaiting_answers",
        questions = { { text = "No id?" } },
      },
    },
  })
  eq(no_id[1] and no_id[1].question_id, "q1", "a missing question id falls back to q<index>")

  -- synthesize -------------------------------------------------------------

  local synth_pending = {
    { task_id = "T-20261114-0001", question_id = "q1", text = "Which AUTH?", index = 1, created_at = "2026-11-14T00:00:02Z" },
    { task_id = "T-20261114-0002", question_id = "q1", text = "which auth", index = 1, created_at = "2026-11-14T00:00:01Z" },
    { task_id = "T-20261114-0003", question_id = "q1", text = "Which cache?", index = 1, created_at = "2026-11-14T00:00:03Z" },
  }
  local synth = questions.synthesize(synth_pending, { blockers = { ["T-20261114-0003"] = 2 } })
  eq(synth.total, 2, "duplicates collapse into one group")
  eq(synth.truncated, 0, "nothing is truncated without a cap")
  eq(#synth.questions, 2, "two groups are kept")
  eq(synth.questions[1].id, "T-20261114-0003/q1", "the blocking group ranks first")
  eq(synth.questions[1].priority, 2, "the priority is the blocker count")
  eq(synth.questions[1].blocking, true, "a blocking group is flagged")
  eq(synth.questions[2].id, "T-20261114-0001/q1", "the id is <task_id>/<question_id>")
  eq(synth.questions[2].text, "Which AUTH?", "the first text is canonical")
  eq(synth.questions[2].blocking, false, "a non-blocking group is not flagged")
  eq(synth.questions[2].priority, 0, "a non-blocking group has priority 0")
  eq(#synth.questions[2].sources, 2, "both duplicate sources are listed")
  eq(synth.questions[2].sources[1].task_id, "T-20261114-0001", "the first source comes first")
  eq(synth.questions[2].sources[2].task_id, "T-20261114-0002", "the second source follows")
  eq(synth.questions[2].sources[2].question_id, "q1", "sources carry the question id")

  local capped = questions.synthesize({
    { task_id = "T-1", question_id = "q1", text = "one", index = 1, created_at = "2026-11-14T00:00:01Z" },
    { task_id = "T-2", question_id = "q1", text = "two", index = 1, created_at = "2026-11-14T00:00:02Z" },
    { task_id = "T-3", question_id = "q1", text = "three", index = 1, created_at = "2026-11-14T00:00:03Z" },
  }, { max_questions = 2 })
  eq(capped.total, 3, "the cap reports the full total")
  eq(#capped.questions, 2, "the cap keeps two")
  eq(capped.truncated, 1, "the cap reports one truncated")
  eq(capped.questions[1].id, "T-1/q1", "ties break on created_at")

  local many = {}
  for i = 1, 16 do
    many[i] = {
      task_id = string.format("T-%02d", i),
      question_id = "q1",
      text = "question " .. i,
      index = 1,
      created_at = "2026-11-14T00:00:00Z",
    }
  end
  local default_cap = questions.synthesize(many)
  eq(#default_cap.questions, 15, "the default cap is 15")
  eq(default_cap.total, 16, "the default cap still reports the total")
  eq(default_cap.truncated, 1, "the default cap truncates the excess")

  -- round ------------------------------------------------------------------

  local a, aerr0 = state.create(root, {
    id = "T-20261114-aaaa",
    title = "Auth task",
    status = "awaiting_answers",
    created_at = "2026-11-14T00:00:01Z",
    questions = {
      { id = "q1", text = "Which AUTH?" },
      { id = "q2", text = "Which database?" },
    },
  })
  eq(type(a), "table", "task A is created")
  eq(aerr0, nil, "creating task A has no error")
  local b = state.create(root, {
    id = "T-20261114-bbbb",
    title = "Duplicate auth task",
    status = "awaiting_answers",
    created_at = "2026-11-14T00:00:02Z",
    questions = { { id = "q1", text = "which auth" } },
  })
  eq(type(b), "table", "task B is created")
  local c = state.create(root, {
    id = "T-20261114-cccc",
    title = "Cache task",
    status = "awaiting_answers",
    created_at = "2026-11-14T00:00:03Z",
    questions = { { id = "q1", text = "Which cache?" } },
  })
  eq(type(c), "table", "task C is created")
  local d = state.create(root, {
    id = "T-20261114-dddd",
    title = "Dependent task",
    status = "ready",
    created_at = "2026-11-14T00:00:04Z",
    depends_on = { "T-20261114-cccc" },
  })
  eq(type(d), "table", "task D is created")

  for _, id in ipairs({
    "T-20261114-aaaa",
    "T-20261114-bbbb",
    "T-20261114-cccc",
    "T-20261114-dddd",
  }) do
    write_sheet(id)
  end
  local untouched_sheet = maki.fs.read(sheet_path("T-20261114-dddd"))
  eq(type(untouched_sheet), "string", "the unrelated task has an initial sheet")

  local round, rerr = questions.round(state, root, { max_questions = 2 })
  eq(rerr, nil, "round has no error")
  eq(round and round.total, 3, "round sees three groups")
  eq(round and #round.questions, 2, "round caps at two")
  eq(round and round.truncated, 1, "round reports the truncation")
  eq(round and round.questions[1].id, "T-20261114-cccc/q1", "the blocking task ranks first")
  eq(round and round.questions[1].priority, 1, "the blocker count is one")
  eq(round and round.questions[1].blocking, true, "the blocking task is flagged")
  eq(round and round.questions[2].id, "T-20261114-aaaa/q1", "the deduped group follows by created_at")
  eq(round and #round.questions[2].sources, 2, "the deduped group has both sources")
  eq(round and round.questions[2].text, "Which AUTH?", "the first text is canonical")

  local full_round = questions.round(state, root)
  eq(full_round and full_round.total, 3, "the default round sees every group")
  eq(full_round and #full_round.questions, 3, "the default round keeps every group")

  -- answer: the deduped canonical id writes to both sources -----------------

  local ans, anserr = questions.answer(
    state, root, { ["T-20261114-aaaa/q1"] = "OAuth" },
    answer_opts({ now = "2026-11-14T12:00:00Z" })
  )
  eq(anserr, nil, "answer has no error")
  eq(ans and ans.answered, 1, "one answer was given")
  eq(ans and ans.applied, 2, "the answer is applied to both sources")
  eq(ans and #ans.tasks, 2, "two tasks moved")
  eq(ans and ans.tasks[1], "T-20261114-aaaa", "the first moved task is sorted")
  eq(ans and ans.tasks[2], "T-20261114-bbbb", "the second moved task is sorted")

  local after = state.load(root)
  eq(after.tasks["T-20261114-aaaa"].status, "qualifying", "task A moved to qualifying")
  eq(after.tasks["T-20261114-bbbb"].status, "qualifying", "task B moved to qualifying")
  eq(after.tasks["T-20261114-aaaa"].questions[1].answer, "OAuth", "task A keeps the answer")
  eq(after.tasks["T-20261114-aaaa"].questions[1].answered_at, "2026-11-14T12:00:00Z", "task A records answered_at")
  eq(after.tasks["T-20261114-aaaa"].questions[1].id, "q1", "the question id is preserved")
  eq(after.tasks["T-20261114-aaaa"].questions[1].text, "Which AUTH?", "the question text is preserved")
  eq(after.tasks["T-20261114-aaaa"].questions[2].answer, nil, "the other question is untouched")
  eq(after.tasks["T-20261114-bbbb"].questions[1].answer, "OAuth", "task B keeps the answer")
  eq(after.tasks["T-20261114-bbbb"].questions[1].answered_at, "2026-11-14T12:00:00Z", "task B records answered_at")

  -- the sheet the implementer reads carries the answer ---------------------

  local sheet_a = maki.fs.read(sheet_path("T-20261114-aaaa"))
  has(sheet_a or "", "- q1: Which AUTH?", "task A's sheet keeps the question line")
  has(sheet_a or "", "  - Réponse (2026-11-14T12:00:00Z): OAuth",
    "task A's sheet renders the answer under its question")
  local sheet_b = maki.fs.read(sheet_path("T-20261114-bbbb"))
  has(sheet_b or "", "OAuth", "the duplicate source's sheet carries the answer too")
  eq(maki.fs.read(sheet_path("T-20261114-dddd")), untouched_sheet,
    "a task whose questions got no answer keeps its sheet bytes")
  eq(sheet_a, qualify.sheet_markdown(after.tasks["T-20261114-aaaa"]),
    "the rewritten sheet is exactly what sheet_markdown renders")

  -- the answer must survive journal replay, not just the projection --------

  maki.fs.rm(maki.fs.joinpath(root, "state.json"))
  local replayed = state.load(root)
  eq(replayed.tasks["T-20261114-aaaa"].questions[1].answer, "OAuth", "the answer survives journal replay")
  eq(replayed.tasks["T-20261114-bbbb"].questions[1].answer, "OAuth", "the duplicate source survives replay")
  eq(replayed.tasks["T-20261114-aaaa"].status, "qualifying", "the status survives replay")

  -- a remaining question on an already-qualifying task ---------------------

  local rest, resterr = questions.answer(
    state, root, { ["T-20261114-aaaa/q2"] = "Postgres" },
    answer_opts({ now = "2026-11-14T12:05:00Z" })
  )
  eq(resterr, nil, "answering a remaining question on a qualifying task does not fail")
  eq(rest and rest.answered, 1, "the remaining answer is counted")
  eq(rest and rest.applied, 1, "the remaining answer is written once")
  eq(rest and #rest.tasks, 0, "an already-qualifying task is not re-added")
  local after_rest = state.load(root)
  eq(after_rest.tasks["T-20261114-aaaa"].questions[2].answer, "Postgres", "the remaining answer is stored")
  eq(after_rest.tasks["T-20261114-aaaa"].status, "qualifying", "the task stays qualifying")

  -- refusals write nothing -------------------------------------------------

  local before_journal = maki.fs.read(journal_path)
  eq(type(before_journal), "string", "the journal exists before the refusals")

  local unknown, uerr = questions.answer(
    state, root, { ["T-20261114-aaaa/nope"] = "x" }, answer_opts()
  )
  eq(unknown, nil, "an unknown id returns nil")
  eq(uerr ~= nil and uerr:find("unknown question id", 1, true) ~= nil, true, "the unknown id explains itself")
  eq(maki.fs.read(journal_path), before_journal, "a refused answer writes nothing")

  local mixed, merr = questions.answer(state, root, {
    ["T-20261114-cccc/q1"] = "redis",
    ["T-20261114-zzzz/q1"] = "x",
  }, answer_opts())
  eq(mixed, nil, "a partially invalid batch returns nil")
  eq(merr ~= nil and merr:find("unknown question id", 1, true) ~= nil, true, "the invalid entry is named")
  eq(maki.fs.read(journal_path), before_journal, "a partially invalid batch writes nothing")

  local empty, eerr = questions.answer(
    state, root, { ["T-20261114-cccc/q1"] = "   " }, answer_opts()
  )
  eq(empty, nil, "an empty answer returns nil")
  eq(eerr ~= nil and eerr:find("non-empty string", 1, true) ~= nil, true, "the empty answer explains itself")
  eq(maki.fs.read(journal_path), before_journal, "an empty answer writes nothing")

  local notstr, nserr = questions.answer(
    state, root, { ["T-20261114-cccc/q1"] = 42 }, answer_opts()
  )
  eq(notstr, nil, "a non-string answer returns nil")
  eq(nserr ~= nil and nserr:find("non-empty string", 1, true) ~= nil, true, "the non-string answer explains itself")

  local bad, baderr = questions.answer(state, root, nil, answer_opts())
  eq(bad, nil, "nil answers returns nil")
  eq(baderr, "answers must be a table", "nil answers explains itself")

  -- the list form ----------------------------------------------------------

  local listed, lerr = questions.answer(state, root, {
    { id = "T-20261114-cccc/q1", answer = "redis" },
  }, answer_opts({ now = "2026-11-14T12:10:00Z" }))
  eq(lerr, nil, "the list form has no error")
  eq(listed and listed.answered, 1, "the list form counts the answer")
  eq(listed and listed.applied, 1, "the list form applies the answer")
  eq(listed and listed.tasks[1], "T-20261114-cccc", "the list form moves the task")
  local after_list = state.load(root)
  eq(after_list.tasks["T-20261114-cccc"].questions[1].answer, "redis", "the list form stores the answer")
  eq(after_list.tasks["T-20261114-cccc"].status, "qualifying", "the list form moves the task to qualifying")

  -- a failing sheet write is an error, not a silent success ----------------

  local e = state.create(root, {
    id = "T-20261114-eeee",
    title = "Sheet failure task",
    status = "awaiting_answers",
    created_at = "2026-11-14T00:00:05Z",
    questions = { { id = "q1", text = "Which region?" } },
  })
  eq(type(e), "table", "task E is created")

  -- A regular file where the sheet directory should be: every write fails.
  local blocked = maki.fs.joinpath(base, "blocked")
  maki.fs.write(blocked, "not a directory")
  local unwritten, unwritten_err = questions.answer(
    state, root, { ["T-20261114-eeee/q1"] = "eu-west" },
    { qualify = qualify, tasks_dir = maki.fs.joinpath(blocked, "tasks") }
  )
  eq(unwritten, nil, "a failing sheet write returns nil")
  eq(
    unwritten_err ~= nil and unwritten_err:find("cannot write sheet for T-20261114-eeee", 1, true) ~= nil,
    true,
    "the sheet failure names the task"
  )
end
