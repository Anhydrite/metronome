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

  -- A failed task names its cause and its resume action, not only its status --
  local transient_failure = task("T-1", "a", "failed", {
    failure = { cause = "git_identity", message = "empty ident", remedy = "set user.email",
      transient = true, attempts = 2, at = 10, next_retry_at = 70 },
  })
  eq(render.detail(transient_failure), "git_identity · reprise auto 2/3",
    "a transient failure shows the automatic retry and its attempt count")
  local human_failure = task("T-1", "a", "failed", {
    failure = { cause = "auth", message = "401", remedy = "gh auth login",
      transient = false, attempts = 1, at = 10 },
  })
  eq(render.detail(human_failure), "auth · metronome_retry",
    "a non-transient failure names the tool that resumes it")
  local legacy_failure = task("T-1", "a", "failed", { failure_reason = "git commit exit 1" })
  has(render.detail(legacy_failure), "metronome_retry",
    "a legacy failure_reason still says how to resume")
  local failed_row = render.rows({ transient_failure })[1]
  has(render.text(render.row_line(failed_row, {})), "git_identity",
    "the row carries the typed cause and its action")

  -- The detail honours the column width and cuts cleanly --------------------
  local wide = render.detail(human_failure, "failures", 12)
  eq(render.width_of(wide) <= 12, true, "the failure detail fits the column width")
  has(wide, "…", "a clipped failure detail ends with an ellipsis")
  eq(render.detail(human_failure, "failures", 40), "auth · metronome_retry",
    "a detail that fits is left alone")

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

  -- origin is the request identity: one ask, many detailed tasks -----------
  local split = {
    { id = "T-20261115-0201", title = "auth core", status = "running", intent = "hash passwords", origin = "add a login system" },
    { id = "T-20261115-0202", title = "routes", status = "ready", intent = "account routes", origin = "add a login system" },
    { id = "T-20261115-0203", title = "docs", status = "ready", intent = "write the readme", origin = "add a login system" },
  }
  local split_groups = render.groups(render.rows(split))
  eq(#split_groups, 1, "tasks sharing an origin stay one request")
  eq(split_groups[1].intent, "add a login system", "the request is the submitted intention")
  eq(#split_groups[1].rows, 3, "all three tasks belong to it")

  -- The PERT graph is the dependency schema: nodes, arrows, critical path.
  local pert_rows = render.rows(grouped)
  local pert_lines, pert_order, pert_node_line = render.pert(pert_rows)
  eq(#pert_lines > 0, true, "pert returns lines")
  eq(#pert_order, #pert_rows, "pert orders every row")
  eq(type(pert_node_line[pert_order[1].id]), "number", "pert maps a row to its line")
  local pert_text = {}
  for _, spans in ipairs(pert_lines) do
    local parts = {}
    for _, span in ipairs(spans) do parts[#parts + 1] = span[1] end
    pert_text[#pert_text + 1] = table.concat(parts)
  end
  local pert_joined = table.concat(pert_text, "\n")
  has(pert_joined, "▶", "the pert graph draws an arrow")
  local chain = render.critical_chain(pert_rows)
  eq(#chain >= 2, true, "the critical path has at least one edge")

  -- diamond ---------------------------------------------------------------
  -- A diamond DAG (A->B, A->C, B->D, C->D) plus a multi-parent node and an
  -- already-merged prerequisite. The schema must draw every node, terminal
  -- ones dimmed, so no declared edge disappears; the navigable list below
  -- stays filtered to non-terminal tasks.
  local diamond_tasks = {
    { id = "T-20261115-0100", title = "schema", status = "merged", origin = "login", depends_on = {} },
    { id = "T-20261115-0101", title = "hash", status = "merged", origin = "login", depends_on = { "T-20261115-0100" } },
    { id = "T-20261115-0102", title = "routes", status = "running", origin = "login", depends_on = { "T-20261115-0100" } },
    { id = "T-20261115-0103", title = "session", status = "ready", origin = "login", depends_on = { "T-20261115-0101", "T-20261115-0102" } },
  }
  local diamond_rows = render.rows(diamond_tasks, { show_done = true })
  local diamond_lines, diamond_order, diamond_node_line = render.pert(diamond_rows, { right_width = 39 })
  eq(#diamond_order, 4, "the diamond schema draws every task, terminal included")
  eq(diamond_node_line["T-20261115-0100"], 1, "the merged root maps to its line")
  local diamond_text = {}
  for _, spans in ipairs(diamond_lines) do
    diamond_text[#diamond_text + 1] = render.text(spans)
  end
  local diamond_joined = table.concat(diamond_text, "\n")
  has(diamond_joined, "T-…0100", "the merged prerequisite is drawn")
  has(diamond_joined, "T-…0101", "the merged dependency is drawn")
  has(diamond_joined, "├─▶", "the schema draws a branch")
  has(diamond_joined, "└─▶", "the schema draws a closing branch")

  local function style_of(lines, needle)
    for _, spans in ipairs(lines) do
      for _, span in ipairs(spans) do
        if tostring(span[1]):find(needle, 1, true) then
          return span[2]
        end
      end
    end
  end
  eq(style_of(diamond_lines, "T-…0100"), "dim", "a merged node is dimmed")
  eq(style_of(diamond_lines, "T-…0103"), "run", "a critical active node is highlighted")

  -- The selected node is the panel's only selector: it turns bold, terminal
  -- nodes included, and the other nodes keep their own style.
  local sel_lines = render.pert(diamond_rows, { right_width = 39, selected_id = "T-20261115-0100" })
  eq(style_of(sel_lines, "T-…0100"), "bold", "the selected node is highlighted")
  eq(style_of(sel_lines, "T-…0102"), "run", "the other nodes keep their style")

  -- panes only highlights a node when the user clicked one; the request line is
  -- the default selector, so a plain render bolds no node.
  local sel_pane = render.panes(diamond_tasks, {
    right_width = 39, selected_row = 2, show_task_selection = true,
  })
  eq(style_of(sel_pane, "T-…0103"), "bold", "panes highlights an explicitly selected task's node")
  eq(style_of(sel_pane, "login"), "bold", "the selected request is the selector")

  local no_sel_pane = render.panes(diamond_tasks, { right_width = 39, selected_row = 2 })
  eq(style_of(no_sel_pane, "T-…0103"), "run", "panes leaves nodes unhighlighted by default")

  -- panes: the simple two-column layout, full schema on the right.
  local pane_lines, pane_rows, _, pane_row_lines = render.panes(diamond_tasks, { right_width = 39 })
  eq(#pane_rows, 2, "the cursor model keeps the non-terminal tasks")
  eq(pane_rows[1].id, "T-20261115-0102", "the running task leads the cursor model")
  eq(#pane_row_lines, 2, "each cursor row maps to a schema line")
  eq(pane_row_lines[1] < pane_row_lines[2], true, "the mapping follows the schema")
  local pane_text = {}
  for _, line in ipairs(pane_lines) do
    pane_text[#pane_text + 1] = render.text(line)
  end
  local pane_joined = table.concat(pane_text, "\n")
  has(pane_joined, "PERT", "the right column is the PERT schema")
  has(pane_joined, "login", "the left column lists the request")
  eq(pane_joined:find("T-…0100", 1, true), nil,
    "a finished task is removed from the schema")

  -- panes drops finished tasks but keeps failures and work in flight ---------
  local mixed = {
    { id = "T-1", title = "done", status = "merged", intent = "ship" },
    { id = "T-2", title = "broken", status = "failed", intent = "ship" },
    { id = "T-3", title = "moving", status = "running", intent = "ship" },
    { id = "T-4", title = "waiting", status = "ready", intent = "ship" },
    { id = "T-5", title = "gone", status = "deployed", intent = "old" },
  }
  local mixed_lines, mixed_rows, _, _, mixed_groups = render.panes(mixed)
  eq(#mixed_groups, 1, "a request with only finished tasks is removed")
  eq(mixed_groups[1].intent, "ship", "the request with live work stays")
  eq(#mixed_groups[1].rows, 3, "finished tasks are dropped from the schema")
  eq(#mixed_rows, 3, "the cursor model keeps errors and live work")
  local mixed_text = {}
  for _, line in ipairs(mixed_lines) do mixed_text[#mixed_text + 1] = render.text(line) end
  local mixed_joined = table.concat(mixed_text, "\n")
  eq(mixed_joined:find("T-1", 1, true), nil, "a merged task is not drawn")
  has(mixed_joined, "fail", "the request column names the request state")
  has(mixed_joined, "T-2", "a failed task stays")
  has(mixed_joined, "T-3", "a running task stays")
  has(mixed_joined, "T-4", "a waiting task stays")
  eq(mixed_joined:find("old", 1, true), nil, "a fully finished request is not listed")

  -- request_icon: the request carries the same state as its tasks -----------
  eq(render.request_icon({ { status = "failed" } }), "✗", "a failed request carries a cross")
  eq(render.request_icon({ { status = "merged" } }), "✓", "a finished request carries a check")
  eq(render.request_icon({ { status = "ready" } }), "☐", "a request not started carries an empty box")
  eq(render.request_icon({ { status = "running" } }, 0), render.spinner(0),
    "a running request animates")
  local _, _, running_word = render.request_icon({ { status = "running" } }, 0)
  eq(running_word, "run", "the request word is short enough for the column")

  -- PERT nodes animate the work in flight and mark a blocked node -----------
  local live_rows = render.rows({
    { id = "T-1", title = "moving", status = "running" },
    { id = "T-2", title = "blocked", status = "awaiting_answers",
      questions = { { id = "q", text = "?" } } },
    { id = "T-3", title = "waiting", status = "ready" },
    { id = "T-4", title = "broken", status = "failed" },
  }, { frame = 0 })
  local live_lines = render.pert(live_rows, { frame = 0 })
  local live_text = {}
  for _, spans in ipairs(live_lines) do live_text[#live_text + 1] = render.text(spans) end
  local live_joined = table.concat(live_text, "\n")
  has(live_joined, render.spinner(0), "a running node animates")
  has(live_joined, "running", "a running node names its state")
  has(live_joined, "?", "a blocked node carries a question mark")
  has(live_joined, "☐", "a waiting node carries an empty box")
  has(live_joined, "✗", "a failed node does not animate")

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
  eq(#pane_rows, 2, "the cursor model holds the selected request's tasks")
  eq(#pane_row_lines, 2, "each cursor row maps to a schema line")
  local pane_text = {}
  for _, line in ipairs(pane_lines) do
    pane_text[#pane_text + 1] = render.text(line)
  end
  local pane_joined = table.concat(pane_text, "\n")
  has(pane_joined, "login", "the left column lists the request")
  has(pane_joined, "export", "the left column lists the other request")
  has(pane_joined, "PERT", "the right column is the PERT schema")
  has(pane_joined, "T-1", "the selected request's schema is drawn")

  -- request_status: the word a request carries, by what needs the human first.
  local rs = render.request_status
  eq(rs({ { status = "running" }, { status = "ready" } }), "running",
    "a running task makes the request running")
  eq(rs({ { status = "failed" }, { status = "running" } }), "failed",
    "a failure outranks progress")
  eq(rs({ { status = "merged" }, { status = "deployed" } }), "done",
    "a fully merged request is done")
  eq(rs({ { status = "ready" }, { status = "draft" } }), "not started",
    "a request nothing started reads not started")
  eq(rs({ { status = "merged" }, { status = "ready" } }), "partial",
    "a half-merged request is partial")
  eq(rs({}), "empty", "an empty request says so")

  -- a task with no phase must not print a JSON null as a userdata
  local no_phase = render.rows({ { id = "T-1", title = "t", status = "ready", phase = maki.NIL } })
  eq(render.detail(no_phase[1], "progress"), "ready", "a null phase falls back to the status")
  eq(render.text(render.row_line(no_phase[1], {})):find("userdata", 1, true), nil,
    "a row never prints userdata")

  -- a request blocked on a question says so, ahead of any other state
  eq(rs({ { status = "awaiting_answers", blocked = true }, { status = "running" } }), "questions",
    "a blocked request reads questions")

  -- fit_spans: the right column is a fixed width, so a long line is cut here
  local clipped = render.fit_spans({ { "abcdef", "dim" }, { "ghij", "ok" } }, 6)
  local clipped_text = render.text(clipped)
  eq(render.width_of(clipped_text) <= 6, true, "fit_spans respects the width")
  has(clipped_text, "…", "a clipped line ends with an ellipsis")
  eq(render.text(render.fit_spans({ { "abc", "dim" } }, 10)), "abc", "a short line is untouched")

  -- A realistic long row is clipped with an ellipsis, never left to spill.
  local long_rows = render.rows({
    { id = "T-20261115-0201", title = "page statique /about", status = "awaiting_answers",
      intent = "about", depends_on = {},
      questions = { { id = "q1", text = "contenu ?" } } },
  })
  local long_line = render.row_line(long_rows[1], {})
  local cut = render.fit_spans(long_line, 77)
  local cut_text = render.text(cut)
  eq(render.width_of(cut_text) <= 77, true, "a long row fits the right column")
  has(cut_text, "…", "a clipped row ends with an ellipsis")

  -- panes clips the right column to opts.right_width
  local narrow = render.panes(pane_tasks, { selected_intent = 2, right_width = 18 })
  for _, line in ipairs(narrow) do
    eq(render.width_of(render.text(line)) <= 40 + 3 + 18, true,
      "every pane line fits the left column, the separator and the right width")
  end

  -- group_counts agrees with the word: one classification, two renderings.
  local gc = render.group_counts({
    { status = "merged" }, { status = "running" },
    { status = "failed" }, { status = "ready" },
  })
  eq(gc.done, 1, "group_counts counts done")
  eq(gc.running, 1, "group_counts counts running")
  eq(gc.failed, 1, "group_counts counts failed")
  eq(gc.todo, 1, "group_counts counts todo")
  eq(gc.total, 4, "group_counts counts the total")

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
