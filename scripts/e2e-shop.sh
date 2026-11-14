#!/usr/bin/env bash
# e2e-shop.sh — The final end-to-end scenario on a fake e-commerce project.
#
# Usage:
#   ./scripts/e2e-shop.sh [--keep] [--help]
#
# What it does:
#   1. creates a throwaway git repo for a small shop (products, accounts,
#      orders), a bare remote and a fake `gh`;
#   2. runs tests/e2e/shop_driver.lua inside maki, which qualifies the
#      intention into three tasks, drives each through implementation, checks,
#      convergence, review, PR and merge, retries a deliberately red check,
#      then deploys;
#   3. starts the delivered server from the merged base and exercises products,
#      accounts and orders over HTTP.
#
# `--keep` leaves the temporary directory in place for inspection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=false

usage() {
  cat <<EOF
Usage: $0 [--keep] [--help]

  --keep   Keep the temporary repository for inspection.
  --help   Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=true ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "error: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

TMP="$(mktemp -d)"
cleanup() {
  if [[ "$KEEP" == true ]]; then
    echo "kept: $TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

E2E_DIR="$TMP/e2e"
E2E_REPO="$E2E_DIR/repo"
E2E_REMOTE="$E2E_DIR/remote.git"
E2E_STATE="$E2E_DIR/state"
E2E_TASKS="$E2E_DIR/tasks"
E2E_WORKTREES="$E2E_DIR/worktrees"
E2E_RUNS="$E2E_DIR/runs"
E2E_CONFIG="$E2E_DIR/config.toml"
E2E_RESULT="$E2E_DIR/result.txt"
E2E_GH_MERGED="$E2E_DIR/gh-merged"
E2E_ERRFILE="${XDG_STATE_HOME:-$HOME/.local/state}/maki/metronome-shop-e2e-error.txt"

mkdir -p "$E2E_DIR/bin" "$E2E_STATE" "$E2E_TASKS" "$E2E_WORKTREES" "$E2E_RUNS"
mkdir -p "$E2E_REPO/routes"

# Fake `gh`: create prints a URL, view reports the state, merge pushes the
# branch to main so the next task and the post-merge checks see it.
cat >"$E2E_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-} ${2:-}"
case "$cmd" in
  "pr create")
    echo "https://github.com/example/shop/pull/7"
    ;;
  "pr view")
    if [[ -f "${E2E_GH_MERGED:?}" ]]; then
      echo '{"number":7,"url":"https://github.com/example/shop/pull/7","state":"MERGED"}'
    else
      echo '{"number":7,"url":"https://github.com/example/shop/pull/7","state":"OPEN"}'
    fi
    ;;
  "pr merge")
    git push origin HEAD:main >/dev/null
    touch "${E2E_GH_MERGED:?}"
    ;;
  *)
    exit 0
    ;;
esac
GH
chmod +x "$E2E_DIR/bin/gh"

# The shop skeleton. The server loads whichever route modules exist, so each
# task only writes its own file and the checks can run incrementally.
cat >"$E2E_REPO/package.json" <<'JSON'
{"name":"shop","version":"1.0.0","private":true,"scripts":{"check":"node check.js all"}}
JSON

cat >"$E2E_REPO/server.js" <<'JS'
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

cat >"$E2E_REPO/check.js" <<'JS'
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

cat >"$E2E_REPO/review-rules.md" <<'MD'
# Review rules

- The server must stay dependency-free.
- A route module exports an array of `{ method, path, handle }`.
MD

cat >"$E2E_REPO/deploy.md" <<'MD'
# Deploy

1. Run `node check.js all` against the merged server.
2. Report the exit code.
MD

printf '# Shop\n\nA tiny store used by the Metronome end-to-end scenario.\n' >"$E2E_REPO/README.md"

git init -q -b main "$E2E_REPO"
git -C "$E2E_REPO" config user.email "shop@example.com"
git -C "$E2E_REPO" config user.name "Shop"
git -C "$E2E_REPO" add -A
git -C "$E2E_REPO" commit -q -m "chore: shop skeleton"
git init -q --bare "$E2E_REMOTE"
git -C "$E2E_REPO" remote add origin "$E2E_REMOTE"
git -C "$E2E_REPO" push -q -u origin main

sed -e "s|/absolute/path/to/your/repo|$E2E_REPO|" \
  -e 's|base_ref = "master"|base_ref = "main"|' \
  "$ROOT/templates/config.toml" >"$E2E_CONFIG"

export E2E_DIR E2E_REPO E2E_STATE E2E_TASKS E2E_WORKTREES E2E_RUNS
export E2E_CONFIG E2E_RESULT E2E_GH_MERGED
export METRONOME_E2E_DRIVER="$ROOT/tests/e2e/shop_driver.lua"
export PATH="$E2E_DIR/bin:$PATH"

rm -f "$E2E_ERRFILE" "$E2E_RESULT"

echo "Metronome shop end-to-end"
echo "  repo:   $E2E_REPO"
echo "  remote: $E2E_REMOTE"
echo "  state:  $E2E_STATE"
echo ""

(cd "$ROOT" && maki --trust index "$ROOT/README.md" >/dev/null 2>&1) || true

if [[ -f "$E2E_ERRFILE" ]]; then
  echo "FAIL: the shop driver could not run:" >&2
  cat "$E2E_ERRFILE" >&2
  exit 1
fi

if [[ ! -f "$E2E_RESULT" ]]; then
  echo "FAIL: the shop driver produced no result at $E2E_RESULT" >&2
  exit 1
fi

cat "$E2E_RESULT"

if grep -q '^FAIL' "$E2E_RESULT"; then
  echo "FAIL: at least one shop check failed" >&2
  exit 1
fi

if ! grep -q '^PASS$' "$E2E_RESULT"; then
  echo "FAIL: the shop driver did not finish" >&2
  exit 1
fi

# The three route modules must really have landed on the remote.
for route in products accounts orders; do
  if ! git --git-dir="$E2E_REMOTE" show "main:routes/$route.js" >/dev/null 2>&1; then
    echo "FAIL: the remote main does not contain routes/$route.js" >&2
    exit 1
  fi
done
echo "ok[remote]: main contains the three route modules"

if ! grep -q '"status":"deployed"' "$E2E_STATE/state.jsonl"; then
  echo "FAIL: the journal never records the deployed status" >&2
  exit 1
fi
echo "ok[journal]: the last task reached deployed"

echo "PASS"
