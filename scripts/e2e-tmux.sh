#!/usr/bin/env bash
# e2e-tmux.sh — the realistic end-to-end scenario.
#
# Usage:
#   ./scripts/e2e-tmux.sh [--repo OWNER/NAME] [--keep] [--timeout SECS] [--help]
#
# What it does:
#   1. builds a small shop repository (products, accounts, orders) and pushes
#      it to a real, private GitHub repository;
#   2. installs the Metronome plugin and starts maki in a tmux session in that
#      repository;
#   3. drives the real `/metronome` command surface from tmux:
#        /metronome init --defaults
#        /metronome submit "Build a small shop..."
#   4. waits for the journal to record a deployed task, then checks the merged
#      GitHub PR and starts the delivered server from origin/main to exercise
#      products, accounts and orders over HTTP.
#
# The model turns are scripted (METRONOME_E2E_SCRIPT) so the test is about the
# orchestration, tmux, git, GitHub PR and deploy path, not model quality.
#
# The default repository is Anhydrite/metronome-shop-e2e, private. Creating a
# repository is an external action; pass --repo to use another one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GH_REPO="Anhydrite/metronome-shop-e2e"
KEEP=false
TIMEOUT=420

usage() {
  cat <<EOF
Usage: $0 [--repo OWNER/NAME] [--keep] [--timeout SECS] [--help]

  --repo OWNER/NAME   GitHub repository to create or reuse (default: $GH_REPO)
  --keep              Keep the temporary directory and the tmux session.
  --timeout SECS      How long to wait for the task to deploy (default: 420)
  --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) GH_REPO="${2:?--repo needs a value}"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v tmux >/dev/null || { echo "FAIL: tmux is required" >&2; exit 1; }
command -v gh >/dev/null || { echo "FAIL: gh is required" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "FAIL: gh is not authenticated" >&2; exit 1; }

TMP="$(mktemp -d)"
SESSION="metronome-e2e-$$"
REPO="$TMP/shop"
SLUG="$(printf '%s' "$REPO" | sed -e 's#[/\\]\+#-#g' -e 's#^-\+##' -e 's#-\+$##')"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/maki/metronome/$SLUG"
SCRIPT="$STATE/e2e-script.json"
RESULT="$TMP/result.txt"
LOG="$TMP/tmux.log"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if [[ "$KEEP" == true ]]; then
    echo "kept: $TMP"
    echo "state: $STATE"
  else
    rm -rf "$TMP" "$STATE"
  fi
}
trap cleanup EXIT

rm -rf "$STATE"
mkdir -p "$REPO/routes" "$STATE"

# Shop skeleton --------------------------------------------------------------

cat >"$REPO/package.json" <<'JSON'
{"name":"shop","version":"1.0.0","private":true,"scripts":{"check":"node check.js all"}}
JSON

cat >"$REPO/server.js" <<'JS'
const http = require('http');
const fs = require('fs');
const path = require('path');

const routes = [];
for (const name of ['products', 'accounts', 'orders']) {
  const file = path.join(__dirname, 'routes', name + '.js');
  if (fs.existsSync(file)) {
    for (const route of require(file)) routes.push(route);
  }
}

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    const urlPath = req.url.split('?')[0];
    for (const route of routes) {
      if (route.method === req.method && route.path === urlPath) {
        try {
          return route.handle(req, res, body);
        } catch (err) {
          res.writeHead(500);
          return res.end('error');
        }
      }
    }
    res.writeHead(404);
    res.end('not found');
  });
});

server.listen(Number(process.env.PORT || 0), () => {
  console.log('PORT=' + server.address().port);
});
JS

cat >"$REPO/check.js" <<'JS'
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');

const scope = process.argv[2] || 'all';

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

function request(port, method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const req = http.request({
      host: '127.0.0.1',
      port,
      method,
      path: urlPath,
      headers: data ? {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(data),
      } : {},
    }, (res) => {
      let out = '';
      res.on('data', (chunk) => { out += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: out }));
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

function start() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
      env: { ...process.env, PORT: '0' },
    });
    let out = '';
    child.stdout.on('data', (chunk) => {
      out += chunk.toString();
      const match = out.match(/PORT=(\d+)/);
      if (match) resolve({ child, port: Number(match[1]) });
    });
    child.stderr.on('data', (chunk) => process.stderr.write(chunk));
    child.on('error', reject);
    setTimeout(() => reject(new Error('server did not start: ' + out)), 5000);
  });
}

async function main() {
  const { child, port } = await start();
  try {
    const scopes = scope === 'all' ? ['products', 'accounts', 'orders'] : [scope];
    for (const s of scopes) {
      if (s === 'products') {
        const res = await request(port, 'GET', '/products');
        assert(res.status === 200, 'products status ' + res.status);
        const list = JSON.parse(res.body);
        assert(Array.isArray(list) && list.length >= 2, 'products list');
        assert(list.every((p) => p.id && p.name && typeof p.price === 'number'), 'product shape');
      }
      if (s === 'accounts') {
        const created = await request(port, 'POST', '/accounts', { name: 'alice' });
        assert(created.status === 201, 'account create ' + created.status);
        const login = await request(port, 'POST', '/login', { name: 'alice' });
        assert(login.status === 200, 'login ' + login.status);
        const missing = await request(port, 'POST', '/login', { name: 'bob' });
        assert(missing.status === 401, 'unknown login ' + missing.status);
      }
      if (s === 'orders') {
        await request(port, 'POST', '/accounts', { name: 'alice' });
        const created = await request(port, 'POST', '/orders', {
          account: 'alice', productId: 1, quantity: 2,
        });
        assert(created.status === 201, 'order create ' + created.status);
        const list = await request(port, 'GET', '/orders?account=alice');
        assert(list.status === 200, 'orders list ' + list.status);
        const orders = JSON.parse(list.body);
        assert(Array.isArray(orders) && orders.length >= 1, 'orders array');
        assert(orders[0].quantity === 2, 'order quantity');
      }
    }
  } finally {
    child.kill('SIGKILL');
  }
}

main()
  .then(() => { console.log('ok ' + scope); })
  .catch((err) => { console.error('FAIL ' + err.message); process.exit(1); });
JS

cat >"$REPO/review-rules.md" <<'MD'
# Review rules

- The server must stay dependency-free.
- A route module exports an array of `{ method, path, handle }`.
MD

cat >"$REPO/deploy.md" <<'MD'
# Deploy

1. Run `node check.js all` against the merged server.
2. Report the exit code.
MD

printf '# Shop\n\nA tiny store used by the Metronome tmux end-to-end scenario.\n' >"$REPO/README.md"

# Route sources the scripted implementer writes into each task worktree.

cat >"$TMP/products.js" <<'JS'
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
JS

cat >"$TMP/accounts.js" <<'JS'
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
JS

cat >"$TMP/orders.js" <<'JS'
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
JS

# script.json: tasks, dependencies by title, and the files each turn writes.
python3 - "$TMP" >"$SCRIPT" <<'PY'
import json, pathlib, sys
tmp = pathlib.Path(sys.argv[1])
def read(name):
    return (tmp / name).read_text()
tasks = [
    {
        "title": "Products catalogue",
        "files": ["routes/products.js"],
        "checks": ["node check.js products"],
        "acceptance": ["GET /products returns at least two products"],
        "write": {"routes/products.js": read("products.js")},
    },
    {
        "title": "Accounts and login",
        "files": ["routes/accounts.js"],
        "checks": ["node check.js accounts"],
        "acceptance": ["POST /accounts creates, POST /login authenticates"],
        "depends_on": ["Products catalogue"],
        "write": {"routes/accounts.js": read("accounts.js")},
    },
    {
        "title": "Orders",
        "files": ["routes/orders.js"],
        "checks": ["node check.js orders"],
        "acceptance": ["POST /orders records quantity, GET /orders lists it"],
        "depends_on": ["Accounts and login"],
        "write": {"routes/orders.js": read("orders.js")},
    },
]
print(json.dumps({"tasks": tasks, "answers": {}}, indent=2))
PY

# Git and GitHub -------------------------------------------------------------

git init -q -b main "$REPO"
git -C "$REPO" config user.email "shop@example.com"
git -C "$REPO" config user.name "Shop"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: shop skeleton"

if gh repo view "$GH_REPO" >/dev/null 2>&1; then
  echo "reusing GitHub repository $GH_REPO"
  git -C "$REPO" remote add origin "https://github.com/$GH_REPO.git"
  git -C "$REPO" fetch -q origin
  # Reset through a pull request, never a direct commit on main: even the test
  # fixture obeys the rule the pipeline is proving.
  git -C "$REPO" checkout -q -B chore/reset-skeleton origin/main
  git -C "$REPO" rm -r --quiet routes 2>/dev/null || true
  git -C "$REPO" add -A
  if ! git -C "$REPO" diff --cached --quiet; then
    git -C "$REPO" commit -q -m "chore: reset the shop skeleton"
    git -C "$REPO" push -q -u origin chore/reset-skeleton
    reset_pr="$(gh pr create --repo "$GH_REPO" --base main --head chore/reset-skeleton \
      --title "chore: reset the shop skeleton" \
      --body "Reset the test fixture through a pull request.")"
    gh pr merge "$reset_pr" --repo "$GH_REPO" --squash --delete-branch >/dev/null
  fi
  git -C "$REPO" checkout -q main
  git -C "$REPO" fetch -q origin
  git -C "$REPO" reset --hard -q origin/main
  # Branches from earlier runs share the deterministic task ids; clear them so
  # this run's first push is not rejected as a non-fast-forward.
  git -C "$REPO" ls-remote --heads origin 'metronome/*' 2>/dev/null \
    | awk '{print $2}' | sed 's#refs/heads/##' \
    | while read -r branch; do
        [[ -n "$branch" ]] && git -C "$REPO" push -q origin --delete "$branch" || true
      done
else
  echo "creating private GitHub repository $GH_REPO"
  gh repo create "$GH_REPO" --private --source "$REPO" --remote origin --push >/dev/null
fi

# The run starts here. Every code commit added after this point must have a
# pull request; older history is out of scope.
git -C "$REPO" fetch -q origin
BASE_SHA="$(git -C "$REPO" rev-parse origin/main)"

# Every change to main must arrive through a pull request. The skeleton was
# pushed before this point; from here on, a direct push is refused.
if printf '%s' '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null}' \
  | gh api -X PUT "repos/$GH_REPO/branches/main/protection" --input - >/dev/null 2>&1; then
  echo "ok[protection]: main requires a pull request"
else
  echo "warning: could not enable branch protection on $GH_REPO" >&2
fi

# Config and plugin ----------------------------------------------------------

sed -e "s|/absolute/path/to/your/repo|$REPO|" \
  -e 's|base_ref = "master"|base_ref = "main"|' \
  "$ROOT/templates/config.toml" >"$STATE/config.toml"

"$ROOT/scripts/install.sh" >/dev/null

# tmux session ---------------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 60 -c "$REPO" "maki; sleep 600"

# The splash animation overlays the transcript but the input is live; give it
# time to finish before typing.
sleep 12

tmux send-keys -t "$SESSION" -l '/metronome init --defaults'
tmux send-keys -t "$SESSION" Enter
sleep 3
# A real user states the intention in natural language; the agent decides to
# call the metronome_submit tool.
tmux send-keys -t "$SESSION" -l 'Build a small shop with products, accounts and orders. Call the metronome_submit tool with that intention now, then report the result. Do not ask questions.'
tmux send-keys -t "$SESSION" Enter

# Wait for the journal to record the deployed task.
deployed=false
for _ in $(seq 1 "$TIMEOUT"); do
  if [[ -f "$STATE/state.jsonl" ]] && grep -q '"status":"deployed"' "$STATE/state.jsonl"; then
    deployed=true
    break
  fi
  sleep 1
done

if [[ "$deployed" != true ]]; then
  echo "FAIL: no task reached deployed within ${TIMEOUT}s" >&2
  tmux capture-pane -pt "$SESSION" -S -120 >&2 || true
  exit 1
fi
echo "ok[journal]: a task reached deployed"

# A real user asks for the result; the agent calls metronome_status.
tmux send-keys -t "$SESSION" -l 'Use the metronome_status tool to report the final state of every task.'
tmux send-keys -t "$SESSION" Enter
sleep 5
if ! tmux capture-pane -pt "$SESSION" -S -80 | grep -q 'deployed'; then
  echo "FAIL: metronome_status did not report the deployed state" >&2
  exit 1
fi
echo "ok[user]: maki answered a natural-language status request"

# The delivered server from origin/main --------------------------------------

VALIDATE="$TMP/validate"
git -C "$REPO" fetch -q origin
git -C "$REPO" worktree add -q --detach "$VALIDATE" origin/main
if ! (cd "$VALIDATE" && node check.js all); then
  echo "FAIL: the delivered server does not pass the checks" >&2
  exit 1
fi
echo "ok[http]: products, accounts and orders pass against origin/main"

for route in products accounts orders; do
  if ! git -C "$REPO" show "origin/main:routes/$route.js" >/dev/null 2>&1; then
    echo "FAIL: origin/main does not contain routes/$route.js" >&2
    exit 1
  fi
done
echo "ok[remote]: origin/main contains the three route modules"

# The real GitHub PR ---------------------------------------------------------

MERGED="$(gh pr list --repo "$GH_REPO" --state merged --json number,title,state --limit 10)"
if [[ "$MERGED" == "[]" ]]; then
  echo "FAIL: no merged pull request on $GH_REPO" >&2
  exit 1
fi

# Every PR this run recorded must be merged on GitHub, not just any PR.
python3 - "$STATE/state.json" >"$TMP/prs.txt" <<'PYPR'
import json, sys
state = json.load(open(sys.argv[1]))
for task in state.get("tasks", {}).values():
    pr = task.get("pr") or {}
    if pr.get("number"):
        print(pr["number"])
PYPR
while read -r number; do
  [[ -z "$number" ]] && continue
  state="$(gh pr view "$number" --repo "$GH_REPO" --json state --jq .state)"
  if [[ "$state" != "MERGED" ]]; then
    echo "FAIL: PR #$number is $state, not MERGED" >&2
    exit 1
  fi
done <"$TMP/prs.txt"
echo "ok[github]: every PR recorded by the run is merged on $GH_REPO"

# No code commit this run added to main may bypass a pull request.
git -C "$REPO" fetch -q origin
for sha in $(git -C "$REPO" rev-list "$BASE_SHA..origin/main"); do
  files="$(gh api "repos/$GH_REPO/commits/$sha" --jq '.files[].filename')"
  if printf '%s\n' "$files" | grep -q '^routes/'; then
    count="$(gh api "repos/$GH_REPO/commits/$sha/pulls" --jq 'length')"
    if [[ "$count" == "0" ]]; then
      echo "FAIL: commit $sha touched routes/ without a pull request" >&2
      exit 1
    fi
  fi
done
echo "ok[pr-only]: every routes/ commit added by this run came from a pull request"

{
  echo "repo=$GH_REPO"
  echo "state=$STATE"
  echo "merged_prs=$MERGED"
  echo "PASS"
} >"$RESULT"

cat "$RESULT"
