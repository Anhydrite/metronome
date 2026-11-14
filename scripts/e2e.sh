#!/usr/bin/env bash
# e2e.sh — One end-to-end scenario on a throwaway repository.
#
# Usage:
#   ./scripts/e2e.sh [--keep] [--help]
#
# What it does:
#   1. creates a throwaway git repo, a bare remote and a fake `gh`;
#   2. runs tests/e2e/driver.lua inside maki's Lua host, which composes the
#      real modules: init, submit, questions, analyze, schedule, implement,
#      checks, converge, review, PR, merge, deploy, resume and the protected
#      path guard;
#   3. judges the driver's result, the remote's main branch and the journal.
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
E2E_ERRFILE="${XDG_STATE_HOME:-$HOME/.local/state}/maki/metronome-e2e-error.txt"

mkdir -p "$E2E_DIR/bin" "$E2E_STATE" "$E2E_TASKS" "$E2E_WORKTREES" "$E2E_RUNS"

# A fake `gh`: create prints a URL, view reports the state, merge really pushes
# the branch to main so the post-merge checks see the change.
cat >"$E2E_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-} ${2:-}"
case "$cmd" in
  "pr create")
    echo "https://github.com/example/e2e/pull/7"
    ;;
  "pr view")
    if [[ -f "${E2E_GH_MERGED:?}" ]]; then
      echo '{"number":7,"url":"https://github.com/example/e2e/pull/7","state":"MERGED"}'
    else
      echo '{"number":7,"url":"https://github.com/example/e2e/pull/7","state":"OPEN"}'
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

# Throwaway repository and bare remote.
git init -q -b main "$E2E_REPO"
git -C "$E2E_REPO" config user.email "e2e@example.com"
git -C "$E2E_REPO" config user.name "E2E"
printf '# e2e\n' >"$E2E_REPO/README.md"
printf '# Review rules\n\n- No secrets in the diff.\n' >"$E2E_REPO/review-rules.md"
printf '# Deploy\n\n1. echo deployed\n' >"$E2E_REPO/deploy.md"
git -C "$E2E_REPO" add -A
git -C "$E2E_REPO" commit -q -m "chore: init"
git init -q --bare "$E2E_REMOTE"
git -C "$E2E_REPO" remote add origin "$E2E_REMOTE"
git -C "$E2E_REPO" push -q -u origin main

# Config: the shipped template, pointed at the throwaway repo and main.
sed -e "s|/absolute/path/to/your/repo|$E2E_REPO|" \
  -e 's|base_ref = "master"|base_ref = "main"|' \
  "$ROOT/templates/config.toml" >"$E2E_CONFIG"

export E2E_DIR E2E_REPO E2E_STATE E2E_TASKS E2E_WORKTREES E2E_RUNS
export E2E_CONFIG E2E_RESULT E2E_GH_MERGED
export METRONOME_E2E_DRIVER="$ROOT/tests/e2e/driver.lua"
export PATH="$E2E_DIR/bin:$PATH"

rm -f "$E2E_ERRFILE" "$E2E_RESULT"

echo "Metronome end-to-end"
echo "  repo:   $E2E_REPO"
echo "  remote: $E2E_REMOTE"
echo "  state:  $E2E_STATE"
echo ""

# `maki index` exits non-zero for reasons unrelated to plugins, so the driver's
# result file is the judge, not the exit code.
(cd "$ROOT" && maki --trust index "$ROOT/README.md" >/dev/null 2>&1) || true

if [[ -f "$E2E_ERRFILE" ]]; then
  echo "FAIL: the E2E driver could not run:" >&2
  cat "$E2E_ERRFILE" >&2
  exit 1
fi

if [[ ! -f "$E2E_RESULT" ]]; then
  echo "FAIL: the E2E driver produced no result at $E2E_RESULT" >&2
  exit 1
fi

cat "$E2E_RESULT"

if grep -q '^FAIL' "$E2E_RESULT"; then
  echo "FAIL: at least one E2E check failed" >&2
  exit 1
fi

if ! grep -q '^PASS$' "$E2E_RESULT"; then
  echo "FAIL: the E2E driver did not finish" >&2
  exit 1
fi

# The merge must really have landed on the remote, not only in the journal.
if ! git --git-dir="$E2E_REMOTE" show main:app.txt 2>/dev/null | grep -q "hello from metronome"; then
  echo "FAIL: the remote main does not contain the implemented change" >&2
  exit 1
fi
echo "ok[remote]: main contains app.txt"

if ! grep -q '"status":"deployed"' "$E2E_STATE/state.jsonl"; then
  echo "FAIL: the journal never records the deployed status" >&2
  exit 1
fi
echo "ok[journal]: the task reached deployed"

echo "PASS"
