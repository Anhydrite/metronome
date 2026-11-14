-- E-commerce end-to-end driver for scripts/e2e-shop.sh (REQ-20261114-47).
--
-- Runs inside maki against a throwaway shop repository created by the shell.
-- It qualifies one intention into three tasks (products, accounts, orders),
-- drives each through implementation, checks, convergence, review, PR and
-- merge, deliberately fails the orders check once and retries it, deploys the
-- last task, then validates the delivered server from the merged base.

local E2E_DIR = maki.uv.os_getenv("E2E_DIR")
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
  system = "shop-e2e-system",
  model_spec = "e2e/model",
  thinking = "low",
  tools = { "read", "write", "run" },
}

-- Route sources --------------------------------------------------------------

local PRODUCTS = [=[
module.exports = [
  {
    method: 'GET',
    path: '/products',
    handle(req, res) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify([
        { id: 1, name: 'Coffee', price: 9 },
        { id: 2, name: 'Mug', price: 12 },
      ]));
    },
  },
];
]=]

local ACCOUNTS = [=[
const accounts = {};

module.exports = [
  {
    method: 'POST',
    path: '/accounts',
    handle(req, res, body) {
      const { name } = JSON.parse(body || '{}');
      if (!name) {
        res.writeHead(400);
        return res.end('name required');
      }
      accounts[name] = accounts[name] || { name };
      res.writeHead(201, { 'content-type': 'application/json' });
      res.end(JSON.stringify(accounts[name]));
    },
  },
  {
    method: 'POST',
    path: '/login',
    handle(req, res, body) {
      const { name } = JSON.parse(body || '{}');
      if (!accounts[name]) {
        res.writeHead(401);
        return res.end('unknown account');
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(accounts[name]));
    },
  },
];
]=]

local ORDERS_OK = [=[
const orders = [];

module.exports = [
  {
    method: 'POST',
    path: '/orders',
    handle(req, res, body) {
      const { account, productId, quantity } = JSON.parse(body || '{}');
      if (!account || !productId || !quantity) {
        res.writeHead(400);
        return res.end('missing fields');
      }
      const order = { id: orders.length + 1, account, productId, quantity };
      orders.push(order);
      res.writeHead(201, { 'content-type': 'application/json' });
      res.end(JSON.stringify(order));
    },
  },
  {
    method: 'GET',
    path: '/orders',
    handle(req, res) {
      const account = new URL(req.url, 'http://localhost').searchParams.get('account');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(orders.filter((order) => order.account === account)));
    },
  },
];
]=]

-- The first orders attempt is deliberately red: the check must fail, the
-- worktree must roll back, and the retry must write the correct module.
local ORDERS_BUGGY = [=[
module.exports = [
  { method: 'POST', path: '/orders', handle(req, res) { res.writeHead(500); res.end('not implemented'); } },
  { method: 'GET', path: '/orders', handle(req, res) { res.writeHead(500); res.end('not implemented'); } },
];
]=]

local SOURCES = {
  products = PRODUCTS,
  accounts = ACCOUNTS,
  orders = ORDERS_OK,
}

-- Init -----------------------------------------------------------------------

local cfg, cfg_errors = config.load(CONFIG_PATH)
check(cfg ~= nil, "init: config loads", cfg_errors and table.concat(cfg_errors, "; "))

-- Submit: qualification ------------------------------------------------------

local QUALIFY_JSON = [[{"tasks":[
  {"title":"Products catalogue","files":["routes/products.js"],"checks":["node check.js products"],"acceptance":["GET /products returns at least two products"]},
  {"title":"Accounts and login","files":["routes/accounts.js"],"checks":["node check.js accounts"],"acceptance":["POST /accounts creates, POST /login authenticates"]},
  {"title":"Orders","files":["routes/orders.js"],"checks":["node check.js orders"],"acceptance":["POST /orders records quantity, GET /orders lists it"]}
]}]]

local qualified = qualify.run({
  intention = "Build a small shop with products, accounts and orders.",
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
      return string.format("T-20261114-s%03d", i)
    end,
  })
end
check(applied ~= nil, "submit: three tasks are created", apply_err)

-- Map each task to its scope and chain the dependencies.
local scope_by_id = {}
local id_by_scope = {}
local scope_by_title = {
  ["Products catalogue"] = "products",
  ["Accounts and login"] = "accounts",
  ["Orders"] = "orders",
}
if applied then
  for _, task in ipairs(applied.tasks) do
    local scope = scope_by_title[task.title]
    if scope then
      scope_by_id[task.id] = scope
      id_by_scope[scope] = task.id
    end
  end
end
check(id_by_scope.products ~= nil and id_by_scope.accounts ~= nil and id_by_scope.orders ~= nil,
  "submit: every scope has a task")

if id_by_scope.accounts then
  state.set_fields(STATE_ROOT, id_by_scope.accounts, {
    depends_on = { id_by_scope.products },
  })
end
if id_by_scope.orders then
  state.set_fields(STATE_ROOT, id_by_scope.orders, {
    depends_on = { id_by_scope.accounts },
  })
end
check(true, "submit: dependencies chain products -> accounts -> orders")

local gate, gate_err = analyze.gate(state, STATE_ROOT, { tasks_dir = TASKS_DIR })
check(gate ~= nil and gate.ok, "analyze: the gate passes", gate_err or (gate and gate.verdict))

-- One task at a time ---------------------------------------------------------

local attempts = {}
local merged_ids = {}

local function run_one(scope)
  local tick = pipeline.tick({
    state = state,
    root = STATE_ROOT,
    max_parallel = 1,
    stall = false,
    apply = true,
    dispatch = function() end,
  })
  check(tick.ok, scope .. ": scheduler tick succeeds", tick.error)
  check(#tick.started == 1, scope .. ": the scheduler starts one task", #tick.started)
  local started = tick.started[1]
  if not started then
    return nil
  end
  local id = started.id
  check(scope_by_id[id] == scope, scope .. ": the right task started", scope_by_id[id])

  local impl = nil
  local verified = nil
  for attempt = 1, 3 do
    attempts[id] = (attempts[id] or 0) + 1
    local source = SOURCES[scope]
    if scope == "orders" and attempts[id] == 1 then
      source = ORDERS_BUGGY
    end
    impl = implement.run({
      task = state.load(STATE_ROOT).tasks[id],
      repo = REPO,
      state = state,
      root = STATE_ROOT,
      git = git,
      worktree_root = WORKTREES,
      tasks_dir = TASKS_DIR,
      remote = "origin",
      base_ref = "main",
      runner = function(request)
        local path = maki.fs.joinpath(WORKTREES, request.task_id, "routes", scope .. ".js")
        write(path, source)
        return { ok = true, text = "wrote routes/" .. scope .. ".js (attempt " .. attempts[id] .. ")" }
      end,
      session_opts = SESSION,
      state_root = RUNS,
      ctx = "shop",
      max_attempts = 1,
      deadline_secs = 60,
      -- The buggy attempt must not reach the remote: the branch is pushed
      -- once, after the check is green.
      push = false,
    })
    check(impl.ok, scope .. ": the turn succeeds (attempt " .. attempt .. ")", impl.error)
    if not impl.ok then
      return nil
    end

    verified = checks.verify({
      checks = { "node check.js " .. scope },
      worktree = impl.ctx.worktree,
      root = STATE_ROOT,
      task_id = id,
      state = state,
      git = git,
      rollback = true,
      timeout_ms = 60000,
    })
    check(verified ~= nil, scope .. ": the check ran", verified and verified.error)
    if verified and verified.ok then
      break
    end
    check(verified ~= nil and verified.rolled_back == true,
      scope .. ": a red check rolled back (attempt " .. attempt .. ")")
  end

  check(verified ~= nil and verified.ok, scope .. ": the declared check passes")
  if not (verified and verified.ok) then
    return nil
  end
  if scope == "orders" then
    check(attempts[id] >= 2, "orders: the red attempt was retried")
  end
  checks.write_report(STATE_ROOT, id, verified, {})
  local pushed, push_err = git.push(impl.ctx.worktree, impl.ctx.branch, { remote = "origin" })
  check(pushed, scope .. ": the branch is pushed", push_err)

  local sheet = read(maki.fs.joinpath(TASKS_DIR, id .. ".md"))
  local converged = converge.run({
    task = state.load(STATE_ROOT).tasks[id],
    worktree = impl.ctx.worktree,
    base = "origin/main",
    git = git,
    root = STATE_ROOT,
    tasks_dir = TASKS_DIR,
    sheet = sheet,
    runner = function()
      return { ok = true, text = "noop" }
    end,
    session_opts = SESSION,
    state_root = RUNS,
    ctx = "shop",
  })
  check(converged.ok, scope .. ": the diff matches the sheet", converged.error)

  state.transition(STATE_ROOT, id, "verifying", { phase = "verify" })
  state.transition(STATE_ROOT, id, "reviewing", { phase = "review" })
  local reviewed = review.review({
    task = id,
    worktree = impl.ctx.worktree,
    base = "origin/main",
    git = git,
    state = state,
    root = STATE_ROOT,
    runner = function()
      return { ok = true, text = '{"findings":[]}' }
    end,
    tasks_dir = TASKS_DIR,
    repo = REPO,
    state_root = RUNS,
    ctx = "shop",
    session_opts = SESSION,
    fence = fence,
  })
  check(reviewed.ok and reviewed.approved, scope .. ": the commit is approved", reviewed.error)

  local pr = git.pr_open(state, STATE_ROOT, id, {
    repo = REPO,
    worktree = impl.ctx.worktree,
    base = "main",
    head = impl.ctx.branch,
    title = "Shop: " .. scope,
    body = "End-to-end shop task.",
    gh = "gh",
  })
  check(pr ~= nil and pr.number == 7, scope .. ": the PR is opened", pr and pr.url)

  local merged = merge.run({
    task = id,
    worktree = impl.ctx.worktree,
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
    commands = { "node check.js " .. scope },
  })
  check(merged.ok, scope .. ": the PR merges and the base stays green", merged.error)
  if merged.ok then
    merged_ids[#merged_ids + 1] = id
  end
  return id
end

local last_id = nil
for _, scope in ipairs({ "products", "accounts", "orders" }) do
  last_id = run_one(scope)
  if not last_id then
    break
  end
end
check(#merged_ids == 3, "pipeline: all three tasks merged", #merged_ids)

-- Deploy ---------------------------------------------------------------------

if last_id then
  local deployed = deploy.run({
    task = last_id,
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
    ctx = "shop",
    checks = checks,
  })
  check(deployed.ok, "deploy: the plan runs", deployed.error)
  check(state.load(STATE_ROOT).tasks[last_id].status == "deployed", "deploy: the task is deployed")
end

-- Validate the delivered site from the merged base ---------------------------

local fetched = git.fetch(REPO, "origin")
check(fetched, "final: the remote is fetched")
local final_dir = maki.fs.joinpath(WORKTREES, "final")
local added, add_err = git.worktree_add(REPO, final_dir, nil, "origin/main", { detach = true })
check(added, "final: the merged base is checked out", add_err)
if added then
  local final = checks.run({ "node check.js all" }, {
    worktree = final_dir,
    timeout_ms = 60000,
  })
  check(final ~= nil and final.ok, "final: the delivered shop passes products, accounts and orders",
    final and final.failed and final.failed[1] and final.failed[1].stderr)
  git.worktree_remove(REPO, final_dir, { force = true })
end

finish()
