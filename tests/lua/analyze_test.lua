-- Tests for maki/lua/metronome/analyze.lua (REQ-20261114-26).
--
-- The analyzer is exercised in two halves: the pure structural checks on
-- hand-built task tables, and the gate on a real state root whose journal
-- tests/run-lua.sh validates afterwards. Nothing here spends a token: the
-- runner is injected and the semantic half is scripted.

return function()
  local analyze = load_module("analyze")
  local state = load_module("state")

  local base = maki.fs.joinpath(maki.env.state_dir(), "metronome-tests", "analyze")
  maki.fs.rm(base, { recursive = true })
  maki.fs.mkdir(base, { parents = true })

  local root = maki.fs.joinpath(base, "state")

  -- A task table in the shape state.lua stores. Passing `{}` for checks keeps
  -- the empty array; passing nil falls back to the default.
  local function task(id, title, files, checks, deps)
    return {
      id = id,
      title = title,
      files = files or {},
      checks = checks or { "make test" },
      depends_on = deps or {},
    }
  end

  local function find_rule(result, rule)
    for _, finding in ipairs(result and result.findings or {}) do
      if finding.rule == rule then
        return finding
      end
    end
    return nil
  end

  local function count_rule(result, rule)
    local n = 0
    for _, finding in ipairs(result and result.findings or {}) do
      if finding.rule == rule then
        n = n + 1
      end
    end
    return n
  end

  local function named(finding)
    local set = {}
    for _, id in ipairs(finding and finding.tasks or {}) do
      set[id] = true
    end
    return set
  end

  -- normalize_title --------------------------------------------------------

  eq(analyze.normalize_title("  Add   AUTH page.  "), "add auth page", "normalize_title lowercases, collapses, trims and strips punctuation")
  eq(analyze.normalize_title("Fix: auth?!"), "fix: auth", "normalize_title strips trailing punctuation")
  eq(analyze.normalize_title("  Add   AUTH page.  "), analyze.normalize_title("add auth page"), "two title variants share one normalized form")
  eq(analyze.normalize_title("What.now."), "what.now", "normalize_title only strips trailing punctuation")
  eq(analyze.normalize_title(nil), "", "nil title normalizes to empty")
  eq(analyze.normalize_title(42), "", "a number title normalizes to empty")

  -- file_key ---------------------------------------------------------------

  eq(analyze.file_key({ "b.lua", "a.lua" }), "a.lua,b.lua", "file_key sorts the set")
  eq(analyze.file_key({ "a.lua", "b.lua" }), analyze.file_key({ "b.lua", "a.lua" }), "file_key is order independent")
  eq(analyze.file_key({ "a.lua", "a.lua" }), "a.lua", "file_key dedupes")
  eq(analyze.file_key({}), "", "an empty file set has an empty key")
  eq(analyze.file_key(nil), "", "nil files has an empty key")
  eq(analyze.file_key({ "", "a.lua" }), "a.lua", "blank entries are dropped")

  -- analyze: a coherent pair ----------------------------------------------

  local coherent = analyze.analyze({
    task("T-20261114-a001", "Add login", { "src/login.lua" }),
    task("T-20261114-a002", "Add logout", { "src/logout.lua" }),
  })
  eq(coherent.ok, true, "a coherent pair is ok")
  eq(coherent.verdict, "ok", "a coherent pair has verdict ok")
  eq(#coherent.findings, 0, "a coherent pair produces no findings")

  -- analyze: duplicate_title ----------------------------------------------

  local dup_title = analyze.analyze({
    task("T-20261114-b001", "Add login", { "src/a.lua" }),
    task("T-20261114-b002", "  add   LOGIN.  ", { "src/b.lua" }),
  })
  local dup_title_finding = find_rule(dup_title, "duplicate_title")
  eq(dup_title_finding and dup_title_finding.severity, "blocking", "duplicate_title is blocking")
  eq(dup_title_finding and dup_title_finding.tasks[1], "T-20261114-b001", "duplicate_title names the first task")
  eq(dup_title_finding and dup_title_finding.tasks[2], "T-20261114-b002", "duplicate_title names the second task")
  eq(dup_title.ok, false, "duplicate_title blocks")
  eq(dup_title.verdict, "blocked", "duplicate_title sets verdict blocked")
  eq(count_rule(dup_title, "duplicate_title"), 1, "duplicate_title fires once for a pair")

  -- analyze: duplicate_files ----------------------------------------------

  local dup_files = analyze.analyze({
    task("T-20261114-b003", "First", { "src/a.lua", "src/b.lua" }),
    task("T-20261114-b004", "Second", { "src/b.lua", "src/a.lua" }),
  })
  -- A task whose checks name a file another task produces must depend on it.
  local cross = analyze.analyze({
    { id = "T-20261115-0001", title = "orders route", files = { "routes/orders.js" },
      checks = { "node check.js orders" }, depends_on = {} },
    { id = "T-20261115-0002", title = "account page", files = { "public/mon-compte.html" },
      checks = { "grep -q 'routes/orders.js' public/mon-compte.html" }, depends_on = {} },
  })
  local cross_finding = find_rule(cross, "undeclared_file_dependency")
  eq(cross_finding ~= nil, true, "an undeclared cross-file dependency is flagged")
  eq(cross_finding and cross_finding.severity, "major", "undeclared_file_dependency is major")
  local declared = analyze.analyze({
    { id = "T-20261115-0003", title = "orders route", files = { "routes/orders.js" },
      checks = { "node check.js orders" }, depends_on = {} },
    { id = "T-20261115-0004", title = "account page", files = { "public/mon-compte.html" },
      checks = { "grep -q 'routes/orders.js' public/mon-compte.html" },
      depends_on = { "T-20261115-0003" } },
  })
  eq(count_rule(declared, "undeclared_file_dependency"), 0,
    "a declared dependency is not flagged")

  local dup_files_finding = find_rule(dup_files, "duplicate_files")
  eq(dup_files_finding and dup_files_finding.severity, "minor", "duplicate_files is minor")
  eq(dup_files_finding and dup_files_finding.tasks[1], "T-20261114-b003", "duplicate_files names the first task")
  eq(dup_files_finding and dup_files_finding.tasks[2], "T-20261114-b004", "duplicate_files names the second task")
  has(dup_files_finding and dup_files_finding.message or "", "src/a.lua", "duplicate_files names the files")
  eq(dup_files.ok, true, "duplicate_files does not block")

  -- analyze: file_overlap -------------------------------------------------

  local overlap = analyze.analyze({
    task("T-20261114-c001", "First", { "src/shared.lua", "src/one.lua" }),
    task("T-20261114-c002", "Second", { "src/shared.lua", "src/two.lua" }),
  })
  local overlap_finding = find_rule(overlap, "file_overlap")
  eq(overlap.ok, true, "file_overlap does not block")
  eq(overlap_finding == nil or overlap_finding.severity, "minor", "file_overlap is minor when emitted")
  if overlap_finding then
    eq(overlap_finding.tasks[1], "T-20261114-c001", "file_overlap names the first task")
    eq(overlap_finding.tasks[2], "T-20261114-c002", "file_overlap names the second task")
    has(overlap_finding.message, "src/shared.lua", "file_overlap names the shared file")
  end
  for _, finding in ipairs(overlap.findings) do
    eq(finding.severity ~= "blocking", true, "two tasks sharing a file produce no blocking finding")
  end

  -- analyze: inter-task rules are scoped by base_ref -----------------------

  -- Two tasks cut from different base branches are never concurrent: same
  -- title, partially overlapping files and checks that name each other's
  -- files must not be compared at all. The file sets are deliberately not
  -- identical (so file_overlap can fire on the shared file) and each check
  -- names a file only the other task owns (so undeclared_file_dependency and
  -- undeclared_gate_dependency can fire): any rule that forgets its
  -- same-group guard fails this block.
  local other_epics = analyze.analyze({
    { id = "T-20261122-a001", title = "Shared title",
      files = { "src/shared.lua", "src/only_a.lua" },
      checks = { "node src/only_b.lua" }, depends_on = {},
      base_ref = "metronome/epic/a" },
    { id = "T-20261122-b001", title = "  shared   TITLE.  ",
      files = { "src/shared.lua", "src/only_b.lua" },
      checks = { "node src/only_a.lua" }, depends_on = {},
      base_ref = "metronome/epic/b" },
  })
  eq(other_epics.ok, true, "tasks of different epics are ok")
  eq(count_rule(other_epics, "duplicate_title"), 0,
    "duplicate_title never crosses base_ref groups")
  eq(count_rule(other_epics, "duplicate_files"), 0,
    "duplicate_files never crosses base_ref groups")
  eq(count_rule(other_epics, "file_overlap"), 0,
    "file_overlap never crosses base_ref groups")
  eq(count_rule(other_epics, "undeclared_file_dependency"), 0,
    "undeclared_file_dependency never crosses base_ref groups")
  eq(count_rule(other_epics, "undeclared_gate_dependency"), 0,
    "undeclared_gate_dependency never crosses base_ref groups")
  eq(#other_epics.findings, 0, "tasks of different base_refs are never compared")

  -- A shared base_ref via opts groups the whole batch: a real duplicate is
  -- still caught inside one epic.
  local same_epic = analyze.analyze({
    { id = "T-20261122-a002", title = "Shared title", files = { "src/shared.lua" },
      checks = { "make test" }, depends_on = {} },
    { id = "T-20261122-a003", title = "shared title", files = { "src/other.lua" },
      checks = { "make test" }, depends_on = {} },
  }, { base_ref = "metronome/epic/a" })
  eq(find_rule(same_epic, "duplicate_title") ~= nil, true, "duplicate_title still fires inside one base_ref group")

  -- A task base_ref wins over the batch base_ref.
  local task_base_wins = analyze.analyze({
    { id = "T-20261122-a004", title = "Shared title", files = { "src/shared.lua" },
      checks = { "make test" }, depends_on = {}, base_ref = "metronome/epic/a" },
    { id = "T-20261122-a005", title = "shared title", files = { "src/other.lua" },
      checks = { "make test" }, depends_on = {} },
  }, { base_ref = "metronome/epic/b" })
  eq(find_rule(task_base_wins, "duplicate_title"), nil, "a task base_ref overrides the batch base_ref")

  -- A dependency cycle that spans two base branches is not a cycle: those
  -- tasks are never scheduled together, so the edges never both matter.
  local cross_epic_cycle = analyze.analyze({
    { id = "T-20261122-a006", title = "First", files = { "src/a.lua" },
      checks = { "make test" }, depends_on = { "T-20261122-b006" },
      base_ref = "metronome/epic/a" },
    { id = "T-20261122-b006", title = "Second", files = { "src/b.lua" },
      checks = { "make test" }, depends_on = { "T-20261122-a006" },
      base_ref = "metronome/epic/b" },
  })
  eq(find_rule(cross_epic_cycle, "dependency_cycle"), nil,
    "a cycle spanning two base_ref groups is not reported")
  eq(cross_epic_cycle.ok, true, "cross-group edges do not block")

  -- Two cycles in two groups: the findings are emitted per group in
  -- task-index order, so the report is reproducible (pairs order is not).
  local two_cycles = analyze.analyze({
    { id = "T-20261122-a008", title = "A first", files = { "src/a1.lua" },
      checks = { "make test" }, depends_on = { "T-20261122-a009" },
      base_ref = "metronome/epic/a" },
    { id = "T-20261122-b008", title = "B first", files = { "src/b1.lua" },
      checks = { "make test" }, depends_on = { "T-20261122-b009" },
      base_ref = "metronome/epic/b" },
    { id = "T-20261122-a009", title = "A second", files = { "src/a2.lua" },
      checks = { "make test" }, depends_on = { "T-20261122-a008" },
      base_ref = "metronome/epic/a" },
    { id = "T-20261122-b009", title = "B second", files = { "src/b2.lua" },
      checks = { "make test" }, depends_on = { "T-20261122-b008" },
      base_ref = "metronome/epic/b" },
  })
  local cycles = {}
  for _, finding in ipairs(two_cycles.findings) do
    if finding.rule == "dependency_cycle" then
      cycles[#cycles + 1] = finding
    end
  end
  eq(#cycles, 2, "each group reports its own cycle")
  eq(cycles[1] and cycles[1].tasks[1], "T-20261122-a008",
    "groups are walked in task-index order (first group first)")
  eq(cycles[2] and cycles[2].tasks[1], "T-20261122-b008",
    "groups are walked in task-index order (second group second)")

  -- Per-task rules still run on every task, whatever its group.
  local per_task_groups = analyze.analyze({
    { id = "T-20261122-a007", title = "No files", files = {},
      checks = { "make test" }, depends_on = {}, base_ref = "metronome/epic/a" },
    { id = "T-20261122-b007", title = "No checks", files = { "src/b.lua" },
      checks = {}, depends_on = {}, base_ref = "metronome/epic/b" },
  })
  local empty_files_finding = find_rule(per_task_groups, "empty_files")
  local empty_checks_finding = find_rule(per_task_groups, "empty_checks")
  eq(empty_files_finding and empty_files_finding.tasks[1], "T-20261122-a007",
    "empty_files still fires inside its own group")
  eq(empty_checks_finding and empty_checks_finding.tasks[1], "T-20261122-b007",
    "empty_checks still fires inside its own group")
  eq(per_task_groups.ok, false, "per-task findings still block across groups")

  local ordered = analyze.analyze({
    task("T-20261114-c003", "Second", { "src/shared.lua", "src/two.lua" }, nil, { "T-20261114-c004" }),
    task("T-20261114-c004", "First", { "src/shared.lua", "src/one.lua" }),
  })
  eq(find_rule(ordered, "file_overlap"), nil, "a direct dependency suppresses the overlap")
  eq(#ordered.findings, 0, "an ordered pair produces no findings")

  local transitive = analyze.analyze({
    task("T-20261114-c005", "Top", { "src/shared.lua", "src/top.lua" }, nil, { "T-20261114-c006" }),
    task("T-20261114-c006", "Mid", { "src/mid.lua" }, nil, { "T-20261114-c007" }),
    task("T-20261114-c007", "Base", { "src/shared.lua", "src/base.lua" }),
  })
  eq(find_rule(transitive, "file_overlap"), nil, "a transitive dependency suppresses the overlap")

  -- analyze: missing_dependency -------------------------------------------

  local missing = analyze.analyze({
    task("T-20261114-e001", "First", { "src/a.lua" }, nil, { "T-20261114-ffff" }),
  }, { known_ids = { ["T-20261114-e001"] = true } })
  local missing_finding = find_rule(missing, "missing_dependency")
  eq(missing_finding and missing_finding.severity, "blocking", "missing_dependency is blocking")
  eq(missing_finding and missing_finding.tasks[1], "T-20261114-e001", "missing_dependency names the task")
  has(missing_finding and missing_finding.message or "", "T-20261114-ffff", "missing_dependency names the unknown id")
  has(missing_finding and missing_finding.message or "", "neither a task id, a task title nor an index", "missing_dependency explains the reference kinds")
  eq(missing.ok, false, "missing_dependency blocks")

  local known = analyze.analyze({
    task("T-20261114-e001", "First", { "src/a.lua" }, nil, { "T-20261114-e002" }),
    task("T-20261114-e002", "Second", { "src/b.lua" }),
  }, { known_ids = { "T-20261114-e001", "T-20261114-e002" } })
  eq(find_rule(known, "missing_dependency"), nil, "a known dependency produces no finding")
  eq(#known.findings, 0, "a known dependency pair is coherent")

  local no_known = analyze.analyze({
    task("T-20261114-e003", "First", { "src/a.lua" }, nil, { "T-20261114-ffff" }),
  })
  eq(find_rule(no_known, "missing_dependency"), nil, "missing_dependency is skipped without known_ids")

  -- analyze: self_dependency ----------------------------------------------

  local self_dep = analyze.analyze({
    task("T-20261114-f001", "First", { "src/a.lua" }, nil, { "T-20261114-f001" }),
  })
  local self_finding = find_rule(self_dep, "self_dependency")
  eq(self_finding and self_finding.severity, "blocking", "self_dependency is blocking")
  eq(self_finding and self_finding.tasks[1], "T-20261114-f001", "self_dependency names the task")
  eq(find_rule(self_dep, "dependency_cycle"), nil, "a self dependency is not also reported as a cycle")
  eq(self_dep.ok, false, "self_dependency blocks")

  -- analyze: dependency_cycle ---------------------------------------------

  local cycle = analyze.analyze({
    task("T-20261114-d001", "First", { "src/a.lua" }, nil, { "T-20261114-d002" }),
    task("T-20261114-d002", "Second", { "src/b.lua" }, nil, { "T-20261114-d001" }),
  })
  local cycle_finding = find_rule(cycle, "dependency_cycle")
  eq(cycle_finding and cycle_finding.severity, "blocking", "dependency_cycle is blocking")
  eq(cycle_finding and #cycle_finding.tasks, 2, "dependency_cycle names both tasks")
  local cycle_named = named(cycle_finding)
  eq(cycle_named["T-20261114-d001"], true, "dependency_cycle names the first task")
  eq(cycle_named["T-20261114-d002"], true, "dependency_cycle names the second task")
  eq(count_rule(cycle, "dependency_cycle"), 1, "dependency_cycle reports the cycle once")
  eq(cycle.ok, false, "dependency_cycle blocks")

  -- analyze: gate_cycle and undeclared_gate_dependency ---------------------

  -- A check that runs a file another task owns is an implicit dependency. If
  -- the owner waits on us, neither task can go green: this is the deadlock
  -- the declared graph cannot see.
  local gate_cycle = analyze.analyze({
    task("T-20261114-h001", "Require a password", { "routes/auth.js" }, { "node check.js" }),
    task("T-20261114-h002", "Update the gate", { "check.js" }, { "node check.js" }, { "T-20261114-h001" }),
  })
  local gate_finding = find_rule(gate_cycle, "gate_cycle")
  eq(gate_finding and gate_finding.severity, "blocking", "gate_cycle is blocking")
  local gate_named = named(gate_finding)
  eq(gate_named["T-20261114-h001"], true, "gate_cycle names the task whose check runs the gate")
  eq(gate_named["T-20261114-h002"], true, "gate_cycle names the task that owns the gate")
  has(gate_finding and gate_finding.message or "", "check.js", "gate_cycle names the gate file")
  eq(gate_cycle.ok, false, "gate_cycle blocks")

  -- The same coupling with the right order is not a cycle: the task that
  -- runs the gate waits for the task that updates it.
  local gate_ordered = analyze.analyze({
    task("T-20261114-h003", "Require a password", { "routes/auth.js" }, { "node check.js" }, { "T-20261114-h004" }),
    task("T-20261114-h004", "Update the gate", { "check.js" }, { "node check.js" }),
  })
  eq(find_rule(gate_ordered, "gate_cycle"), nil, "a declared gate dependency is not a cycle")
  eq(find_rule(gate_ordered, "undeclared_gate_dependency"), nil, "a declared gate dependency is not undeclared")

  -- No ordering at all: the check would run the old gate. Major, not blocking,
  -- because adding the dependency is enough to fix it.
  local gate_undeclared = analyze.analyze({
    task("T-20261114-h005", "Require a password", { "routes/auth.js" }, { "node check.js" }),
    task("T-20261114-h006", "Update the gate", { "check.js" }, { "node check.js" }),
  })
  local undeclared_finding = find_rule(gate_undeclared, "undeclared_gate_dependency")
  eq(undeclared_finding and undeclared_finding.severity, "major", "undeclared_gate_dependency is major")
  eq(find_rule(gate_undeclared, "gate_cycle"), nil, "without an ordering there is no cycle")

  -- A task that owns the file its check runs is not coupled to anyone.
  local gate_own = analyze.analyze({
    task("T-20261114-h007", "Update the gate", { "check.js" }, { "node check.js" }),
  })
  eq(find_rule(gate_own, "gate_cycle"), nil, "a task that owns its gate is fine")
  eq(find_rule(gate_own, "undeclared_gate_dependency"), nil, "a task that owns its gate is not coupled")

  -- A check that names no declared file is opaque: no false positive.
  local gate_opaque = analyze.analyze({
    task("T-20261114-h008", "Run the suite", { "routes/auth.js" }, { "npm test" }),
    task("T-20261114-h009", "Update the gate", { "check.js" }, { "node check.js" }, { "T-20261114-h008" }),
  })
  eq(find_rule(gate_opaque, "gate_cycle"), nil, "an opaque check produces no gate finding")

  -- analyze: empty_files and empty_checks ---------------------------------

  local no_files = analyze.analyze({
    task("T-20261114-g001", "First", {}),
  })
  local no_files_finding = find_rule(no_files, "empty_files")
  eq(no_files_finding and no_files_finding.severity, "blocking", "empty_files is blocking")
  eq(no_files_finding and no_files_finding.tasks[1], "T-20261114-g001", "empty_files names the task")
  eq(no_files.ok, false, "empty_files blocks")

  local no_checks = analyze.analyze({
    { id = "T-20261114-g002", title = "First", files = { "src/a.lua" }, checks = {} },
  })
  local no_checks_finding = find_rule(no_checks, "empty_checks")
  eq(no_checks_finding and no_checks_finding.severity, "blocking", "empty_checks is blocking")
  eq(no_checks_finding and no_checks_finding.tasks[1], "T-20261114-g002", "empty_checks names the task")
  eq(no_checks.ok, false, "empty_checks blocks")

  -- analyze: unknown_file -------------------------------------------------

  local repo = maki.fs.joinpath(base, "repo")
  maki.fs.mkdir(maki.fs.joinpath(repo, "src"), { parents = true })
  maki.fs.write(maki.fs.joinpath(repo, "src", "exists.lua"), "-- hi\n")

  local unknown = analyze.analyze({
    task("T-20261114-h001", "First", { "src/exists.lua", "src/missing.lua" }),
  }, { repo = repo })
  local unknown_finding = find_rule(unknown, "unknown_file")
  eq(unknown_finding and unknown_finding.severity, "minor", "unknown_file is minor")
  eq(unknown_finding and unknown_finding.tasks[1], "T-20261114-h001", "unknown_file names the task")
  has(unknown_finding and unknown_finding.message or "", "src/missing.lua", "unknown_file names the missing file")
  eq(unknown.ok, true, "unknown_file is a warning, not a blocker")
  eq(unknown.verdict, "ok", "unknown_file leaves the verdict ok")

  local existing = analyze.analyze({
    task("T-20261114-h002", "First", { "src/exists.lua" }),
  }, { repo = repo })
  eq(find_rule(existing, "unknown_file"), nil, "an existing file produces no finding")

  local no_repo = analyze.analyze({
    task("T-20261114-h003", "First", { "src/missing.lua" }),
  })
  eq(find_rule(no_repo, "unknown_file"), nil, "unknown_file is skipped without a repo")

  -- With a ref, existence is read from git, not the checkout: a file that is
  -- only in the local checkout must not satisfy the check, and a file that is
  -- in the ref must satisfy it even when the checkout lacks it.
  local ref_git = {
    ls_tree = function(_, ref)
      if ref ~= "origin/main" then
        return nil, "unknown ref"
      end
      return { "src/on_base.lua" }
    end,
  }
  local ref_only = analyze.analyze({
    task("T-20261114-h004", "First", { "src/on_base.lua" }),
  }, { repo = repo, ref = "origin/main", git = ref_git })
  eq(find_rule(ref_only, "unknown_file"), nil, "a file on the ref is known")

  local local_only = analyze.analyze({
    task("T-20261114-h005", "First", { "src/exists.lua" }),
  }, { repo = repo, ref = "origin/main", git = ref_git })
  local local_only_finding = find_rule(local_only, "unknown_file")
  eq(local_only_finding ~= nil, true, "a file only in the checkout is not on the ref")
  has(local_only_finding and local_only_finding.message or "", "src/exists.lua",
    "the ref finding names the file")

  local bad_ref = analyze.analyze({
    task("T-20261114-h006", "First", { "src/exists.lua" }),
  }, {
    repo = repo,
    ref = "origin/main",
    git = { ls_tree = function() return nil, "boom" end },
  })
  eq(find_rule(bad_ref, "unknown_file"), nil, "an unreadable ref skips the check instead of guessing")

  -- analyze: oversized ----------------------------------------------------

  local oversized = analyze.analyze({
    task("T-20261114-i001", "First", { "a.lua", "b.lua", "c.lua" }),
  }, { max_files_per_task = 2 })
  local oversized_finding = find_rule(oversized, "oversized")
  eq(oversized_finding and oversized_finding.severity, "major", "oversized is major")
  eq(oversized_finding and oversized_finding.tasks[1], "T-20261114-i001", "oversized names the task")
  has(oversized_finding and oversized_finding.message or "", "3", "oversized names the count")
  eq(oversized.ok, true, "oversized is major, not blocking")

  local many_files = {}
  for i = 1, 16 do
    many_files[i] = string.format("src/f%02d.lua", i)
  end
  local default_cap = analyze.analyze({
    task("T-20261114-i002", "First", many_files),
  })
  eq(find_rule(default_cap, "oversized") ~= nil, true, "the default cap is 15 files")

  -- semantic_prompt -------------------------------------------------------

  local tasks_dir = maki.fs.joinpath(base, "tasks")
  maki.fs.mkdir(tasks_dir, { parents = true })
  maki.fs.write(
    maki.fs.joinpath(tasks_dir, "T-20261114-j001.md"),
    "# Sheet for j001\n\nAcceptance: login works.\n"
  )

  local prompt = analyze.semantic_prompt("Add a login page", {
    task("T-20261114-j001", "Add login", { "src/login.lua" }),
    task("T-20261114-j002", "Add logout", { "src/logout.lua" }, nil, { "T-20261114-j001" }),
  }, { tasks_dir = tasks_dir })
  has(prompt, "Add a login page", "semantic_prompt carries the intention verbatim")
  has(prompt, "T-20261114-j001", "semantic_prompt names the first task")
  has(prompt, "T-20261114-j002", "semantic_prompt names the second task")
  has(prompt, "src/login.lua", "semantic_prompt carries the files")
  has(prompt, "make test", "semantic_prompt carries the checks")
  has(prompt, "Acceptance: login works.", "semantic_prompt includes the sheet text when it exists")
  has(prompt, '"findings":[', "semantic_prompt states the JSON contract")
  has(prompt, '"severity":"blocking|major|minor|nit"', "semantic_prompt states the severity enum")
  has(prompt, '"rule":"contradiction|duplicate|gap|ordering|scope"', "semantic_prompt states the rule enum")
  has(prompt, "unexecutable", "semantic_prompt explains when blocking is allowed")

  -- parse_findings --------------------------------------------------------

  local parsed_object = analyze.parse_findings(
    '{"findings":[{"severity":"blocking","rule":"contradiction","message":"A and B disagree","tasks":["T-20261114-a001"]}]}'
  )
  eq(type(parsed_object), "table", "parse_findings decodes an object")
  eq(#parsed_object, 1, "parse_findings keeps one finding")
  eq(parsed_object and parsed_object[1].severity, "blocking", "parse_findings keeps the severity")
  eq(parsed_object and parsed_object[1].rule, "contradiction", "parse_findings keeps the rule")
  eq(parsed_object and parsed_object[1].message, "A and B disagree", "parse_findings keeps the message")
  eq(parsed_object and parsed_object[1].tasks[1], "T-20261114-a001", "parse_findings keeps the tasks")

  local parsed_array = analyze.parse_findings('[{"severity":"minor","message":"a gap"}]')
  eq(#parsed_array, 1, "parse_findings decodes a bare array")
  eq(parsed_array and parsed_array[1].rule, "semantic", "a missing rule defaults to semantic")
  eq(type(parsed_array and parsed_array[1].tasks), "table", "a missing tasks list becomes empty")
  eq(#(parsed_array and parsed_array[1].tasks or {}), 0, "the default tasks list is empty")

  local parsed_fenced = analyze.parse_findings('```json\n{"findings":[{"severity":"nit","message":"n"}]}\n```')
  eq(#parsed_fenced, 1, "parse_findings decodes fenced JSON")

  local parsed_prose = analyze.parse_findings('Here you go:\n{"findings":[]}\nDone.')
  eq(type(parsed_prose), "table", "parse_findings decodes JSON surrounded by prose")
  eq(#parsed_prose, 0, "an empty findings list is valid")

  local parsed_empty_array = analyze.parse_findings("[]")
  eq(type(parsed_empty_array), "table", "an empty bare array is valid")
  eq(#parsed_empty_array, 0, "an empty bare array has no findings")

  local bad_json, bad_json_err = analyze.parse_findings("{nope")
  eq(bad_json, nil, "invalid JSON returns nil")
  eq(bad_json_err ~= nil and bad_json_err:find("invalid JSON", 1, true) ~= nil, true, "invalid JSON explains itself")

  local no_json, no_json_err = analyze.parse_findings("no json here")
  eq(no_json, nil, "text without JSON returns nil")
  eq(no_json_err ~= nil and no_json_err:find("no JSON", 1, true) ~= nil, true, "text without JSON explains itself")

  local bad_severity, bad_severity_err = analyze.parse_findings(
    '{"findings":[{"severity":"fatal","message":"x"}]}'
  )
  eq(bad_severity, nil, "a bad severity returns nil")
  eq(bad_severity_err ~= nil and bad_severity_err:find("severity", 1, true) ~= nil, true, "a bad severity explains itself")

  local no_message, no_message_err = analyze.parse_findings(
    '{"findings":[{"severity":"minor"}]}'
  )
  eq(no_message, nil, "a missing message returns nil")
  eq(no_message_err ~= nil and no_message_err:find("message", 1, true) ~= nil, true, "a missing message explains itself")

  local bad_tasks, bad_tasks_err = analyze.parse_findings(
    '{"findings":[{"severity":"minor","message":"x","tasks":[""]}]}'
  )
  eq(bad_tasks, nil, "an empty task id returns nil")
  eq(bad_tasks_err ~= nil and bad_tasks_err:find("tasks", 1, true) ~= nil, true, "an empty task id explains itself")

  local bad_rule, bad_rule_err = analyze.parse_findings(
    '{"findings":[{"severity":"minor","message":"x","rule":42}]}'
  )
  eq(bad_rule, nil, "a non-string rule returns nil")
  eq(bad_rule_err ~= nil and bad_rule_err:find("rule", 1, true) ~= nil, true, "a non-string rule explains itself")

  local nil_text, nil_text_err = analyze.parse_findings(nil)
  eq(nil_text, nil, "nil text returns nil")
  eq(nil_text_err ~= nil, true, "nil text explains itself")

  -- run -------------------------------------------------------------------

  local session_opts = { system = "sys", model_spec = "test/model", thinking = "low", tools = {} }
  local run_tasks = {
    task("T-20261114-k001", "Add login", { "src/login.lua" }),
    task("T-20261114-k002", "Add logout", { "src/logout.lua" }),
  }

  local runner_calls = 0
  local major_runner = function()
    runner_calls = runner_calls + 1
    return {
      ok = true,
      text = '{"findings":[{"severity":"major","rule":"gap","message":"no test for logout","tasks":["T-20261114-k002"]}]}',
    }
  end
  local ran = analyze.run({
    tasks = run_tasks,
    intention = "add auth",
    runner = major_runner,
    session_opts = session_opts,
  })
  eq(runner_calls, 1, "run calls the runner once")
  eq(ran and ran.ok, true, "a major semantic finding does not block")
  eq(ran and ran.verdict, "ok", "a major semantic finding leaves the verdict ok")
  eq(ran and #ran.findings, 1, "the semantic finding is merged")
  eq(ran and ran.findings[1].rule, "gap", "the merged finding keeps its rule")
  eq(ran and ran.semantic.ok, true, "the semantic half succeeded")
  eq(ran and ran.structural.ok, true, "the structural half is exposed")

  local blocking_runner = function()
    return {
      ok = true,
      text = '{"findings":[{"severity":"blocking","rule":"contradiction","message":"A and B conflict","tasks":["T-20261114-k001"]}]}',
    }
  end
  local blocked = analyze.run({
    tasks = run_tasks,
    intention = "add auth",
    runner = blocking_runner,
    session_opts = session_opts,
  })
  eq(blocked and blocked.ok, false, "a blocking semantic finding blocks")
  eq(blocked and blocked.verdict, "blocked", "a blocking semantic finding sets verdict blocked")
  eq(blocked and #blocked.findings, 1, "the blocking finding is merged")

  local failing_runner = function()
    return { ok = false, error = "upstream 500" }
  end
  local failed = analyze.run({
    tasks = run_tasks,
    intention = "add auth",
    runner = failing_runner,
    session_opts = session_opts,
  })
  local failed_finding = find_rule(failed, "semantic_failed")
  eq(failed and failed.ok, false, "a failed runner blocks")
  eq(failed_finding and failed_finding.severity, "blocking", "semantic_failed is blocking")
  has(failed_finding and failed_finding.message or "", "upstream 500", "semantic_failed carries the error")

  local garbled_runner = function()
    return { ok = true, text = "not json" }
  end
  local garbled = analyze.run({
    tasks = run_tasks,
    intention = "add auth",
    runner = garbled_runner,
    session_opts = session_opts,
  })
  eq(garbled and garbled.ok, false, "unparseable semantic output blocks")
  eq(find_rule(garbled, "semantic_failed") ~= nil, true, "unparseable output becomes semantic_failed")

  local skipped_calls = 0
  local skipped = analyze.run({
    tasks = run_tasks,
    intention = "add auth",
    semantic = false,
    runner = function()
      skipped_calls = skipped_calls + 1
      return { ok = true, text = "{}" }
    end,
    session_opts = session_opts,
  })
  eq(skipped and skipped.ok, true, "semantic=false returns the structural result")
  eq(skipped and skipped.semantic.skipped, true, "semantic=false marks the semantic half skipped")
  eq(skipped_calls, 0, "semantic=false never calls the runner")

  local no_runner = analyze.run({ tasks = run_tasks, intention = "add auth" })
  eq(no_runner and no_runner.semantic.skipped, true, "no runner marks the semantic half skipped")

  local seen = nil
  local capture_runner = function(opts)
    seen = opts
    return { ok = true, text = '{"findings":[]}' }
  end
  analyze.run({
    tasks = run_tasks,
    intention = "add auth",
    runner = capture_runner,
    session_opts = session_opts,
    state_root = root,
    ctx = "ctx",
  })
  eq(seen and seen.role, "analyst", "the runner is called as the analyst")
  eq(seen and seen.phase, "analyze", "the runner is called in the analyze phase")
  eq(seen and seen.task_id, "analyze", "the runner gets a default task id")
  eq(seen and seen.system, "sys", "the runner receives the system prompt")
  eq(seen and seen.model_spec, "test/model", "the runner receives the model spec")
  eq(seen and seen.thinking, "low", "the runner receives the thinking level")
  eq(seen and seen.state_root, root, "the runner receives the state root")
  eq(seen and seen.ctx, "ctx", "the runner receives the context")
  has(seen and seen.prompt or "", "add auth", "the runner receives the semantic prompt")

  -- write_report ----------------------------------------------------------

  local report_root = maki.fs.joinpath(base, "report")
  local report_path, report_err = analyze.write_report(report_root, {
    verdict = "ok",
    findings = {},
  }, { intention = "add auth", now = "2026-11-14T00:00:00Z" })
  eq(report_err, nil, "write_report has no error")
  eq(report_path, maki.fs.joinpath(report_root, "analysis.json"), "write_report writes analysis.json")
  local report_text = maki.fs.read(report_path)
  eq(type(report_text), "string", "the analysis report exists")
  local decoded_ok, report = pcall(maki.json.decode, report_text)
  eq(decoded_ok, true, "the analysis report decodes")
  eq(report and report.at, "2026-11-14T00:00:00Z", "the report records the timestamp")
  eq(report and report.intention, "add auth", "the report records the intention")
  eq(report and report.verdict, "ok", "the report records the verdict")
  eq(type(report and report.findings), "table", "the report records the findings")

  -- gate ------------------------------------------------------------------

  local created_a = state.create(root, {
    id = "T-20261114-m001",
    title = "Add login",
    files = { "src/login.lua" },
    checks = { "make test" },
    status = "qualifying",
  })
  eq(type(created_a), "table", "the first qualifying task is created")
  local created_b = state.create(root, {
    id = "T-20261114-m002",
    title = "Add logout",
    files = { "src/logout.lua" },
    checks = { "make test" },
    status = "qualifying",
  })
  eq(type(created_b), "table", "the second qualifying task is created")

  local gated = analyze.gate(state, root, { intention = "add auth", now = "2026-11-14T00:00:00Z" })
  eq(gated and gated.ok, true, "the gate passes a coherent pair")
  eq(gated and gated.verdict, "ok", "the gate verdict is ok")
  eq(gated and #gated.tasks, 2, "the gate moves both tasks")
  eq(gated and gated.tasks[1], "T-20261114-m001", "the first moved task is sorted")
  eq(gated and gated.tasks[2], "T-20261114-m002", "the second moved task is sorted")

  local after_gate = state.load(root)
  eq(after_gate.tasks["T-20261114-m001"].status, "ready", "the first task moved to ready")
  eq(after_gate.tasks["T-20261114-m002"].status, "ready", "the second task moved to ready")

  local analysis_path = maki.fs.joinpath(root, "analysis.json")
  local analysis_text = maki.fs.read(analysis_path)
  eq(type(analysis_text), "string", "the gate writes analysis.json")
  local analysis_ok, analysis = pcall(maki.json.decode, analysis_text)
  eq(analysis_ok, true, "analysis.json decodes")
  eq(analysis and analysis.verdict, "ok", "analysis.json records the verdict")
  eq(analysis and analysis.intention, "add auth", "analysis.json records the intention")

  local empty_gate = analyze.gate(state, root, { intention = "nothing to do" })
  eq(empty_gate and empty_gate.ok, true, "a gate with no qualifying task is ok")
  eq(empty_gate and #empty_gate.tasks, 0, "a gate with no qualifying task moves nothing")
  eq(empty_gate and #empty_gate.findings, 0, "a gate with no qualifying task has no findings")

  state.create(root, {
    id = "T-20261114-m003",
    title = "Add cache",
    files = { "src/cache.lua" },
    checks = { "make test" },
    status = "qualifying",
  })
  state.create(root, {
    id = "T-20261114-m004",
    title = "  add   CACHE.  ",
    files = { "src/other.lua" },
    checks = { "make test" },
    status = "qualifying",
  })

  local blocked_gate = analyze.gate(state, root, { intention = "add cache", now = "2026-11-14T00:01:00Z" })
  eq(blocked_gate and blocked_gate.ok, false, "the gate blocks a duplicate title")
  eq(blocked_gate and blocked_gate.verdict, "blocked", "the gate verdict is blocked")
  eq(blocked_gate and #blocked_gate.tasks, 0, "the gate moves nothing when blocked")
  local gate_finding = find_rule(blocked_gate, "duplicate_title")
  eq(gate_finding and gate_finding.severity, "blocking", "the gate reports the blocking finding")

  local after_blocked = state.load(root)
  eq(after_blocked.tasks["T-20261114-m003"].status, "qualifying", "the first duplicate stays qualifying")
  eq(after_blocked.tasks["T-20261114-m004"].status, "qualifying", "the second duplicate stays qualifying")
end
