-- End-to-end driver for scripts/e2e.sh (REQ-20261114-43).
--
-- Runs inside maki's Lua host against a throwaway repository created by the
-- shell script. It composes the real modules through the whole lifecycle:
-- init (config), submit (qualification), questions, analysis, scheduling,
-- implementation, checks, convergence, review, PR, merge, deploy, resume and
-- the protected-path guard. Model turns are injected runners; git, state and
-- the fake `gh` are real.

local E2E = maki.uv.os_getenv("E2E_DIR")
local REPO = maki.uv.os_getenv("E2E_REPO")
local STATE_ROOT = maki.uv.os_getenv("E2E_STATE")
local TASKS_DIR = maki.uv.os_getenv("E2E_TASKS")
local WORKTREES = maki.uv.os_getenv("E2E_WORKTREES")
local RUNS = maki.uv.os_getenv("E2E_RUNS")
local CONFIG_PATH = maki.uv.os_getenv("E2E_CONFIG")
local RESULT = maki.uv.os_getenv("E2E_RESULT")

local state = load_module("state")
local git = load_module("git")
local config = load_module("config")
local qualify = load_module("qualify")
local questions = load_module("questions")
local analyze = load_module("analyze")
local pipeline = load_module("pipeline")
local implement = load_module("implement")
local checks = load_module("checks")
local converge = load_module("converge")
local review = load_module("review")
local merge = load_module("merge")
local deploy = load_module("deploy")
local fence = load_module("fence")

local out = {}
local failed = false

local function ok(name)
  out[#out + 1] = "ok[" .. name .. "]"
end

local function fail(msg)
  failed = true
  out[#out + 1] = "FAIL: " .. tostring(msg)
end

local function check(cond, name, detail)
  if cond then
    ok(name)
  else
    fail(name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end

local function finish()
  out[#out + 1] = failed and "FAIL" or "PASS"
  maki.fs.write(RESULT, table.concat(out, "\n") .. "\n")
end

local function read(path)
  return maki.fs.read(path)
end

local function write(path, text)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    maki.fs.mkdir(dir, { parents = true })
  end
  return maki.fs.write(path, text)
end

local SESSION = {
  system = "e2e-system",
  model_spec = "e2e/model",
  thinking = "low",
  tools = { "read", "write", "run" },
}

-- Init -----------------------------------------------------------------------

local cfg, cfg_errors = config.load(CONFIG_PATH)
check(cfg ~= nil, "init: config loads", cfg_errors and table.concat(cfg_errors, "; "))
check(cfg ~= nil and cfg.project and cfg.project.base_ref == "main", "init: base_ref is main")
check(cfg ~= nil and cfg.roles and cfg.roles.implementer ~= nil, "init: implementer role is configured")

-- Submit: qualification ------------------------------------------------------

local QUALIFY_JSON = [[{"tasks":[
  {"title":"Add greeting endpoint","files":["app.txt"],"checks":["test -f app.txt"],"acceptance":["app.txt contains hello"]},
  {"title":"Document the endpoint","files":["docs.md"],"checks":["test -f docs.md"],"acceptance":["docs.md written"],"questions":[{"text":"Which language should the docs use?"}]}
]}]]

local qualified = qualify.run({
  intention = "Add a greeting endpoint and document it.",
  runner = function()
    return { ok = true, text = QUALIFY_JSON }
  end,
  session_opts = SESSION,
  repo = REPO,
  task_id = "qualify",
  validate = false,
})
check(qualified.ok, "submit: qualification runs", qualified.error)

local applied, apply_err = nil, nil
if qualified.ok then
  applied, apply_err = qualify.apply(state, STATE_ROOT, qualified, {
    tasks_dir = TASKS_DIR,
    id_factory = function(i)
      return string.format("T-20261114-e%03d", i)
    end,
  })
end
check(applied ~= nil, "submit: tasks are created", apply_err)

-- Questions ------------------------------------------------------------------

local round = questions.round(state, STATE_ROOT)
check(round ~= nil and #round.questions == 1, "questions: one blocking question",
  round and #round.questions)

if round and #round.questions > 0 then
  local answers = {}
  answers[round.questions[1].id] = "English"
  local answered, answer_err = questions.answer(state, STATE_ROOT, answers)
  check(answered ~= nil, "questions: the answer applies", answer_err)
  check(answered ~= nil and answered.applied >= 1, "questions: one answer was written")
end

-- Analysis gate --------------------------------------------------------------

local gate, gate_err = analyze.gate(state, STATE_ROOT, { tasks_dir = TASKS_DIR })
check(gate ~= nil and gate.ok, "analyze: the gate passes", gate_err or (gate and gate.verdict))

-- Scheduler ------------------------------------------------------------------

local dispatched = {}
local tick = pipeline.tick({
  state = state,
  root = STATE_ROOT,
  max_parallel = 1,
  stall = false,
  apply = true,
  dispatch = function(task, phase)
    dispatched[#dispatched + 1] = { id = task.id, phase = phase }
  end,
})
check(tick.ok, "scheduler: tick succeeds", tick.error)
check(#tick.started == 1, "scheduler: max_parallel starts one task", #tick.started)
check(#dispatched == 1, "scheduler: the task is dispatched")

local main_id = tick.started[1] and tick.started[1].id
check(main_id ~= nil, "scheduler: the task has an id")

-- Implementation -------------------------------------------------------------

local impl, worktree, branch = nil, nil, nil
if main_id then
  local task = state.load(STATE_ROOT).tasks[main_id]
  impl = implement.run({
    task = task,
    repo = REPO,
    state = state,
    root = STATE_ROOT,
    git = git,
    worktree_root = WORKTREES,
    tasks_dir = TASKS_DIR,
    remote = "origin",
    base_ref = "main",
    runner = function(request)
      local wt = maki.fs.joinpath(WORKTREES, request.task_id)
      write(maki.fs.joinpath(wt, "app.txt"), "hello from metronome\n")
      return { ok = true, text = "wrote app.txt" }
    end,
    session_opts = SESSION,
    state_root = RUNS,
    ctx = "e2e",
    max_attempts = 1,
    deadline_secs = 60,
  })
  check(impl.ok, "implement: the turn succeeds", impl.error)
  worktree = impl.ctx and impl.ctx.worktree
  branch = impl.ctx and impl.ctx.branch
  check(worktree ~= nil, "implement: a worktree was prepared")
  check(impl.sha ~= nil, "implement: the turn committed")
end

-- Resume ---------------------------------------------------------------------

if main_id then
  local resumed = pipeline.resume(state, STATE_ROOT, { apply = false })
  check(resumed ~= nil and #resumed.resumed >= 1, "resume: the running task is found")
end

-- Checks ---------------------------------------------------------------------

local verified = nil
if main_id and worktree then
  verified = checks.verify({
    checks = { "test -f app.txt" },
    worktree = worktree,
    timeout_ms = 30000,
    rollback = false,
  })
  check(verified ~= nil and verified.ok, "checks: the declared check passes",
    verified and verified.error)
  if verified then
    checks.write_report(STATE_ROOT, main_id, verified, {})
  end
end

-- Convergence ----------------------------------------------------------------

if main_id and worktree then
  local sheet = read(maki.fs.joinpath(TASKS_DIR, main_id .. ".md"))
  local converged = converge.run({
    task = state.load(STATE_ROOT).tasks[main_id],
    worktree = worktree,
    base = "main",
    git = git,
    root = STATE_ROOT,
    tasks_dir = TASKS_DIR,
    sheet = sheet,
    runner = function()
      return { ok = true, text = "noop" }
    end,
    session_opts = SESSION,
    state_root = RUNS,
    ctx = "e2e",
  })
  check(converged.ok, "converge: the diff matches the sheet", converged.error)
end

-- Review ---------------------------------------------------------------------

if main_id and worktree then
  state.transition(STATE_ROOT, main_id, "verifying", { phase = "verify" })
  state.transition(STATE_ROOT, main_id, "reviewing", { phase = "review" })
  local reviewed = review.review({
    task = main_id,
    worktree = worktree,
    base = "main",
    git = git,
    state = state,
    root = STATE_ROOT,
    runner = function()
      return { ok = true, text = '{"findings":[]}' }
    end,
    tasks_dir = TASKS_DIR,
    repo = REPO,
    state_root = RUNS,
    ctx = "e2e",
    session_opts = SESSION,
    fence = fence,
  })
  check(reviewed.ok and reviewed.approved, "review: the commit is approved", reviewed.error)
end

-- Pull request ---------------------------------------------------------------

local pr = nil
if main_id and worktree then
  pr = git.pr_open(state, STATE_ROOT, main_id, {
    repo = REPO,
    worktree = worktree,
    base = "main",
    head = branch,
    title = "Add greeting endpoint",
    body = "End-to-end scenario.",
    gh = "gh",
  })
  check(pr ~= nil and pr.number == 7, "pr: the pull request is opened",
    pr and pr.url or "no pr")
end

-- Merge ----------------------------------------------------------------------

if main_id and worktree then
  local merged = merge.run({
    task = main_id,
    worktree = worktree,
    repo = REPO,
    git = git,
    state = state,
    root = STATE_ROOT,
    remote = "origin",
    base = "main",
    checks = checks,
    gh = "gh",
    method = "squash",
    verify = true,
    commands = { "test -f app.txt" },
  })
  check(merged.ok, "merge: the PR merges and the base stays green", merged.error)
  check(state.load(STATE_ROOT).tasks[main_id].status == "merged", "merge: the task is merged")
end

-- Deploy ---------------------------------------------------------------------

if main_id then
  local deployed = deploy.run({
    task = main_id,
    root = STATE_ROOT,
    state = state,
    repo = REPO,
    plan_path = maki.fs.joinpath(REPO, "deploy.md"),
    runner = function()
      return { ok = true, text = "deployed" }
    end,
    confirm = false,
    confirmed = true,
    session_opts = SESSION,
    state_root = RUNS,
    ctx = "e2e",
    checks = checks,
  })
  check(deployed.ok, "deploy: the plan runs", deployed.error)
  check(state.load(STATE_ROOT).tasks[main_id].status == "deployed", "deploy: the task is deployed")
end

-- Protected paths ------------------------------------------------------------

local protected_id = "T-20261114-e003"
local created, create_err = state.create(STATE_ROOT, {
  id = protected_id,
  title = "Touch the review rules",
  status = "reviewing",
  files = { "review-rules.md" },
  checks = { "true" },
})
check(created ~= nil, "protected: the task is created", create_err)

if created then
  local pwt = maki.fs.joinpath(WORKTREES, protected_id)
  local added, add_err = git.worktree_add(REPO, pwt, "metronome/" .. protected_id, "main")
  check(added, "protected: the worktree is created", add_err)
  if added then
    write(maki.fs.joinpath(pwt, "review-rules.md"), "# changed rules\n")
    local sha, commit_err = git.commit(pwt, "docs: change the rules")
    check(sha ~= nil, "protected: the commit exists", commit_err)
    local guarded = review.review({
      task = protected_id,
      worktree = pwt,
      base = "main",
      git = git,
      state = state,
      root = STATE_ROOT,
      runner = function()
        return { ok = true, text = '{"findings":[]}' }
      end,
      tasks_dir = TASKS_DIR,
      repo = REPO,
      state_root = RUNS,
      ctx = "e2e",
      session_opts = SESSION,
      fence = fence,
    })
    check(guarded ~= nil and guarded.protected == true,
      "protected: the change is blocking", guarded and guarded.error)
    check(state.load(STATE_ROOT).tasks[protected_id].status == "changes_requested",
      "protected: the task is sent back")
  end
end

finish()
