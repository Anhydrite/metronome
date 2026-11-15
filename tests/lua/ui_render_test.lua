-- Tests for maki/lua/metronome/ui/render.lua (REQ-20261114-37).
--
-- The renderer is pure: it turns the task projection into styled lines and
-- never opens a window. These tests pin the attention-bell ordering and the
-- row model the panel navigates.

return function()
  local render = load_module("ui/render")

  local function task(id, title, status, extra)
    local t = { id = id, title = title, status = status }
    for k, v in pairs(extra or {}) do
      t[k] = v
    end
    return t
  end

  -- short_id ---------------------------------------------------------------

  eq(render.short_id("T-20261114-a3f2"), "T-…a3f2", "short_id keeps the suffix")
  eq(render.short_id("T-1"), "T-1", "short_id leaves a short id alone")
  eq(render.short_id(nil), "?", "short_id handles a missing id")

  -- pending_questions ------------------------------------------------------

  local with_questions = task("T-20261114-d1e2", "answer me", "qualifying", {
    questions = {
      { id = "q1", text = "which db?" },
      { id = "q2", text = "which port?", answer = "5432" },
      { id = "q3", text = "empty answer", answer = "" },
    },
  })
  local pending = render.pending_questions(with_questions)
  eq(#pending, 2, "pending_questions counts unanswered and empty answers")
  eq(pending[1].id, "q1", "pending_questions keeps the first unanswered")
  eq(#render.pending_questions({ status = "ready" }), 0, "no questions means none pending")

  -- bucket -----------------------------------------------------------------

  eq(render.bucket(task("T-1", "a", "awaiting_answers")), "questions", "awaiting_answers is blocked")
  eq(render.bucket(with_questions), "questions", "an unanswered question outranks the status")
  eq(render.bucket(task("T-1", "a", "failed")), "failures", "failed is a failure")
  eq(render.bucket(task("T-1", "a", "stalled")), "failures", "stalled is a failure")
  eq(render.bucket(task("T-1", "a", "reviewing")), "review", "reviewing is review-ready")
  eq(render.bucket(task("T-1", "a", "changes_requested")), "review", "changes_requested is review-ready")
  eq(render.bucket(task("T-1", "a", "pr_open")), "review", "pr_open is review-ready")
  eq(render.bucket(task("T-1", "a", "running")), "progress", "running is in progress")
  eq(render.bucket(task("T-1", "a", "deployed")), "done", "deployed is done")

  -- urgency ----------------------------------------------------------------

  eq(render.urgency(task("T-1", "a", "awaiting_answers")) < render.urgency(task("T-1", "a", "failed")), true,
    "questions outrank failures")
  eq(render.urgency(task("T-1", "a", "failed")) < render.urgency(task("T-1", "a", "reviewing")), true,
    "failures outrank reviews")
  eq(render.urgency(task("T-1", "a", "reviewing")) < render.urgency(task("T-1", "a", "running")), true,
    "reviews outrank progress")

  -- detail and role --------------------------------------------------------

  eq(render.detail(with_questions), "2 blocked", "detail counts blocked questions")
  eq(render.detail(task("T-1", "a", "failed")), "failed", "detail shows the failure status")
  local review_task = task("T-1", "a", "reviewing", { review = { round = 2, max_rounds = 3 } })
  eq(render.detail(review_task), "review 2/3", "detail shows the review round")
  eq(render.detail(task("T-1", "a", "running", { phase = "implement" })), "implement",
    "detail shows the phase when there is one")

  eq(render.role_name("qualifier"), "chef de pupitre", "qualifier has an orchestra name")
  eq(render.role_name("analyst"), "harmoniste", "analyst has an orchestra name")
  eq(render.role_name("implementer"), "instrumentiste", "implementer has an orchestra name")
  eq(render.role_name("reviewer"), "critique", "reviewer has an orchestra name")
  eq(render.role_name("deployer"), "timbalier", "deployer has an orchestra name")
  eq(render.role_name("wizard"), "wizard", "an unknown role falls back to its key")

  eq(render.role_for(task("T-1", "a", "running", { phase = "implement" })), "instrumentiste",
    "phase maps to its orchestra name")
  eq(render.role_for(task("T-1", "a", "reviewing")), "critique", "status maps to its orchestra name")
  eq(render.role_for(task("T-1", "a", "deploying")), "timbalier", "deploying maps to the timbalier")
  eq(render.role_for(task("T-1", "a", "mystery")), nil, "an unknown status has no role")

  -- collect ----------------------------------------------------------------

  local map = {
    ["T-20261114-b"] = task("T-20261114-b", "b", "ready"),
    ["T-20261114-a"] = task("T-20261114-a", "a", "ready"),
  }
  local collected = render.collect(map)
  eq(#collected, 2, "collect reads a map")
  eq(collected[1].id, "T-20261114-a", "collect sorts map keys")
  eq(#render.collect({ task("T-1", "a", "ready"), task("T-2", "b", "ready") }), 2, "collect reads an array")
  eq(#render.collect({ { title = "no id" } }), 0, "collect drops entries without an id")

  -- rows and ordering ------------------------------------------------------

  local tasks = {
    task("T-20261114-a3f2", "export CSV", "reviewing", { phase = "review", review = { round = 2, max_rounds = 3 } }),
    task("T-20261114-b7c1", "fix login redirect", "failed", { phase = "implement" }),
    task("T-20261114-c9d0", "bump deps", "ready"),
    with_questions,
  }
  local rows = render.rows(tasks)
  eq(#rows, 4, "rows has one row per task")
  eq(rows[1].id, "T-20261114-d1e2", "blocked questions come first")
  eq(rows[2].id, "T-20261114-b7c1", "failures come second")
  eq(rows[3].id, "T-20261114-a3f2", "reviews come third")
  eq(rows[4].id, "T-20261114-c9d0", "progress comes last")
  eq(rows[1].bucket, "questions", "row carries its bucket")
  eq(rows[3].detail, "review 2/3", "row carries its detail")
  eq(rows[3].short_id, "T-…a3f2", "row carries its short id")
  eq(rows[4].waiting, true, "a ready task is marked waiting")
  eq(rows[2].waiting, false, "a failed task is not waiting")

  -- finished tasks are hidden by default -----------------------------------

  local with_done = {
    task("T-20261114-e5f6", "ship it", "deployed"),
    task("T-20261114-a7b8", "merge me", "merged"),
    task("T-20261114-c9d0", "bump deps", "ready"),
  }
  local visible = render.rows(with_done)
  eq(#visible, 1, "finished tasks are hidden by default")
  eq(visible[1].id, "T-20261114-c9d0", "only the in-progress task remains")
  local all = render.rows(with_done, { show_done = true })
  eq(#all, 3, "show_done brings the done bucket back")

  -- intentions and dependencies --------------------------------------------

  local grouped = {
    { id = "T-20261115-0001", title = "auth core", status = "running", intent = "login", depends_on = {}, branch = "metronome/auth-core-0001" },
    { id = "T-20261115-0002", title = "routes", status = "ready", intent = "login", depends_on = { "T-20261115-0001" } },
    { id = "T-20261115-0003", title = "export", status = "failed", intent = "export CSV", depends_on = {} },
  }
  local grouped_rows = render.rows(grouped)
  local groups = render.groups(grouped_rows)
  eq(#groups, 2, "rows group by intention")
  eq(groups[1].intent, "export CSV", "the most urgent intention comes first")
  eq(groups[2].intent, "login", "the other intention follows")
  eq(#groups[2].rows, 2, "the login group holds both tasks")

  local g_lines, g_rows, _, g_row_lines = render.lines(grouped)
  eq(g_rows[1].id, "T-20261115-0003", "display order puts the failure first")
  eq(g_rows[2].id, "T-20261115-0001", "then the login group")
  eq(g_rows[3].id, "T-20261115-0002", "the login group keeps its order")
  eq(g_row_lines[1] < g_row_lines[2], true, "row_lines maps the display order")
  local g_text = {}
  for _, line in ipairs(g_lines) do
    g_text[#g_text + 1] = render.text(line)
  end
  local g_joined = table.concat(g_text, "\n")
  has(g_joined, '"export CSV"', "the panel shows the intention")
  has(g_joined, '"login"', "the panel shows the other intention")
  has(g_joined, "2 tasks", "the header counts the tasks the intention produced")
  has(g_joined, "⎇ auth-core-0001", "a row shows its branch")
  has(g_joined, "└─▶", "a dependent task is indented under its dependency")
  has(g_joined, "T-…0002", "the dependent task is named")

  -- the dependency tree is the schema --------------------------------------
  local tree_rows = render.rows({
    { id = "T-20261115-0101", title = "root", status = "ready", depends_on = {} },
    { id = "T-20261115-0102", title = "child", status = "ready", depends_on = { "T-20261115-0101" } },
    { id = "T-20261115-0103", title = "grandchild", status = "ready", depends_on = { "T-20261115-0102" } },
    { id = "T-20261115-0104", title = "multi", status = "ready", depends_on = { "T-20261115-0101", "T-20261115-0102" } },
  })
  local tree = render.tree(tree_rows)
  eq(#tree, 4, "the tree holds every row")
  eq(tree[1].row.id, "T-20261115-0101", "the root comes first")
  eq(tree[1].prefix, "", "the root sits at the left margin")
  eq(tree[2].row.id, "T-20261115-0102", "the first child follows")
  eq(tree[2].prefix, "├─▶ ", "a non-last child uses a branch")
  eq(tree[3].row.id, "T-20261115-0103", "the grandchild follows its parent")
  eq(tree[3].prefix, "│  └─▶ ", "a grandchild keeps the ancestor bar")
  eq(tree[4].row.id, "T-20261115-0104", "the last child closes the branch")
  eq(tree[4].prefix, "└─▶ ", "the last child uses the closing branch")
  eq(tree[4].extra_deps, "T-…0102", "a second dependency is kept as an extra edge")

  -- critical path -----------------------------------------------------------
  local crit_rows = render.rows({
    { id = "T-1", title = "a", status = "ready", depends_on = {} },
    { id = "T-2", title = "b", status = "ready", depends_on = { "T-1" } },
    { id = "T-3", title = "c", status = "ready", depends_on = { "T-1" } },
    { id = "T-4", title = "d", status = "ready", depends_on = { "T-2" } },
  })
  local crit = render.critical(crit_rows)
  eq(crit["T-1"].critical, true, "the root is on the critical path")
  eq(crit["T-2"].critical, true, "the longest branch is critical")
  eq(crit["T-3"].critical, false, "the short branch has slack")
  eq(crit["T-3"].slack, 1, "the short branch can slip one unit")
  eq(crit["T-4"].es, 2, "the end waits for the longest branch")
  eq(crit["T-4"].ef, 3, "the end finishes after one unit")

  -- panes ------------------------------------------------------------------
  local pane_tasks = {
    { id = "T-1", title = "auth", status = "running", intent = "login", depends_on = {} },
    { id = "T-2", title = "routes", status = "ready", intent = "login", depends_on = { "T-1" } },
    { id = "T-3", title = "export", status = "failed", intent = "export", depends_on = {} },
  }
  local pane_lines, pane_rows, _, pane_row_lines, pane_groups, pane_selected =
    render.panes(pane_tasks, { selected_intent = 2 })
  eq(#pane_groups, 2, "panes groups by intention")
  eq(pane_selected, 2, "panes honours the selected intention")
  eq(#pane_rows, 2, "panes shows the selected intention's tasks")
  eq(pane_row_lines[1] < pane_row_lines[2], true, "panes maps rows to buffer lines")
  local pane_text = {}
  for _, line in ipairs(pane_lines) do
    pane_text[#pane_text + 1] = render.text(line)
  end
  local pane_joined = table.concat(pane_text, "\n")
  has(pane_joined, "REQUESTS", "panes renders the left column")
  has(pane_joined, "✓0", "panes shows the status icons")
  has(pane_joined, "▶1", "panes counts the running task")
  has(pane_joined, "☐1", "panes counts the todo task")

  -- an intentionless task is rendered flat, with no header
  local flat = render.lines({ task("T-20261115-0004", "legacy", "ready") })
  local flat_text = {}
  for _, line in ipairs(flat) do
    flat_text[#flat_text + 1] = render.text(line)
  end
  eq(table.concat(flat_text, "\n"):find("▸ \"", 1, true), nil, "no header for an intentionless task")

  -- counts -----------------------------------------------------------------

  local counts = render.counts(rows)
  eq(counts.questions, 1, "counts one blocked question")
  eq(counts.failures, 1, "counts one failure")
  eq(counts.review, 1, "counts one review")
  eq(counts.progress, 1, "counts one in progress")

  -- summary lines ----------------------------------------------------------

  local summary = render.summary_lines(rows)
  eq(#summary, 4, "the bell has one line per non-empty bucket")
  eq(render.text(summary[1]):find("questions", 1, true) ~= nil, true, "the bell names questions first")
  eq(render.text(summary[1]):find("1 task", 1, true) ~= nil, true, "the bell counts the questions")
  eq(render.text(summary[1]):find("a to answer", 1, true) ~= nil, true, "the bell hints the answer key")
  eq(render.text(summary[2]):find("failures", 1, true) ~= nil, true, "the bell names failures second")
  eq(render.text(summary[3]):find("review ready", 1, true) ~= nil, true, "the bell names reviews third")
  eq(render.text(summary[4]):find("in progress", 1, true) ~= nil, true, "the bell names progress last")

  local empty_summary = render.summary_lines({})
  eq(#empty_summary, 1, "an empty bell has one line")
  eq(render.text(empty_summary[1]), "nothing needs you", "an empty bell says nothing needs you")

  -- lines and render -------------------------------------------------------

  local lines, line_rows, line_counts = render.lines(tasks)
  eq(#line_rows, 4, "lines returns the rows")
  eq(line_counts.questions, 1, "lines returns the counts")
  eq(render.text(lines[1]):find("questions", 1, true) ~= nil, true, "lines starts with the bell")
  eq(render.text(lines[5]), "", "lines puts a spacer after the bell")
  eq(render.text(lines[6]):find("answer me", 1, true) ~= nil, true, "lines lists the blocked task first")
  eq(render.text(lines[6]):find("T-…d1e2", 1, true) ~= nil, true, "a row starts with the short id")
  eq(render.text(lines[6]):find("▸ chef de pupitre", 1, true) ~= nil, true, "a row names the owning role")

  local empty_lines, empty_rows = render.lines({})
  eq(#empty_rows, 0, "no tasks means no rows")
  eq(render.text(empty_lines[#empty_lines]), "(no tasks)", "an empty panel says so")

  local fake_buf = { written = nil }
  function fake_buf:set_lines(value)
    self.written = value
  end
  local rendered_lines, rendered_rows = render.render(fake_buf, tasks)
  eq(fake_buf.written, rendered_lines, "render writes the lines into the buffer")
  eq(#rendered_rows, 4, "render returns the rows")

  local no_buf_lines = render.render(nil, tasks)
  eq(#no_buf_lines > 0, true, "render works without a buffer")

  -- text -------------------------------------------------------------------

  eq(render.text("plain"), "plain", "text passes a string through")
  eq(render.text({ { "a", "bold" }, "b", { "c" } }), "abc", "text flattens spans")

  -- quiet mode (REQ-20261114-48) ------------------------------------------

  eq(render.spinner(0), render.SPINNER[1], "spinner starts on the first frame")
  eq(render.spinner(1), render.SPINNER[2], "spinner advances one frame")
  eq(render.spinner(#render.SPINNER), render.SPINNER[1], "spinner wraps after the last frame")
  eq(type(render.spinner(-1)), "string", "spinner tolerates a negative frame")

  local quiet_rows = render.rows(tasks, { quiet = true, frame = 3 })
  local progress_row, attention_row
  for _, row in ipairs(quiet_rows) do
    if row.bucket == "progress" then progress_row = row end
    if row.bucket == "questions" then attention_row = row end
  end
  eq(progress_row.spinner, render.spinner(3), "a progress row carries the spinner")
  eq(attention_row.spinner, render.spinner(3), "an attention row carries the spinner too")
  eq(attention_row.detail, "2 blocked", "quiet mode keeps what needs the user")

  local quiet_line = render.text(render.row_line(progress_row, { quiet = true }))
  has(quiet_line, render.spinner(3), "a quiet row shows the spinner")
  has(quiet_line, "ready", "a quiet row keeps the task status")
  local verbose_line = render.text(render.row_line(progress_row, { quiet = false }))
  has(verbose_line, "ready", "a verbose row keeps the action detail")

  -- A long title is cut so the status and the phase stay visible -----------
  local long_title = string.rep("tres long nom de tache ", 4)
  local long_row = render.rows({
    task("T-1", long_title, "running", { phase = "implement" }),
  })[1]
  local long_line = render.text(render.row_line(long_row, { quiet = false }))
  has(long_line, "running", "a long title does not hide the status")
  has(long_line, "implement", "a long title does not hide the phase")
  eq(render.fit("abcdefghij", 5):find("…", 1, true) ~= nil, true, "fit ends a cut string with an ellipsis")
  eq(render.fit("abc", 5), "abc", "fit leaves a short string alone")

  local quiet_lines = render.lines(tasks, { quiet = true, frame = 1 })
  local quiet_text = {}
  for _, line in ipairs(quiet_lines) do
    quiet_text[#quiet_text + 1] = render.text(line)
  end
  local joined = table.concat(quiet_text, "\n")
  has(joined, render.spinner(1), "quiet lines show the spinner")
  has(joined, "2 blocked", "quiet lines still show blocked questions")
end
