#!/usr/bin/env bash
# T0 — two harness runs must survive running at the same time.
#
# Before the token isolation, every `tests/run-lua.sh` wrote its journals,
# temporary repositories and worktrees under fixed paths, so two runs sharing a
# worktree overwrote each other's artifacts and failed for reasons unrelated to
# the code under test. This test launches two real runs in the same worktree at
# the same time and demands two green summaries, two distinct run workspaces,
# and no workspace left behind.
#
# It needs no fake at all: both runs are `maki index` on the real suite.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok[$*]"
}

[[ -f "$ROOT/tests/run-lua.sh" ]] || fail "tests/run-lua.sh is missing"

# Launch both runs. MAKI_TEST_TOKEN is unset on purpose: a caller's token must
# never leak into the children, otherwise the two runs would share one
# workspace and the test would prove nothing.
pids=()
for i in 1 2; do
  (
    env -u MAKI_TEST_TOKEN bash "$ROOT/tests/run-lua.sh" \
      >"$TMP/run-$i.log" 2>&1
    printf '%s\n' "$?" >"$TMP/run-$i.code"
  ) &
  pids+=("$!")
done
wait "${pids[0]}" || true
wait "${pids[1]}" || true

# Judge each run on its own: code, summary, and the workspace it printed.
declare -a TOKENS=() DIRS=()
for i in 1 2; do
  log="$TMP/run-$i.log"
  code_file="$TMP/run-$i.code"

  [[ -f "$code_file" ]] || fail "instance $i produced no exit code (log: $log)"
  code="$(cat "$code_file")"
  if [[ "$code" != "0" ]]; then
    detail="$(grep -E '^(FAIL|SUMMARY) ' "$log" 2>/dev/null | head -n 3 || true)"
    [[ -n "$detail" ]] && detail="
  $detail"
    fail "instance $i exited $code instead of 0 (log: $log)$detail"
  fi

  [[ -f "$log" ]] || fail "instance $i produced no log at $log"
  if ! grep -Eq '^PASS: SUMMARY .*failed=0' "$log"; then
    fail "instance $i printed no 'PASS: SUMMARY ... failed=0' (log: $log)"
  fi

  run_line="$(grep -m1 '^RUN: ' "$log" || true)"
  if [[ -z "$run_line" ]]; then
    fail "instance $i printed no 'RUN: token=... dir=...' workspace line, so its run directory cannot be identified (log: $log)"
  fi

  token="$(sed -n 's/^RUN: token=\([^ ]*\) .*/\1/p' <<<"$run_line")"
  dir="$(sed -n 's/^RUN: .* dir=\([^ ]*\) .*/\1/p' <<<"$run_line")"
  [[ -n "$token" && -n "$dir" ]] \
    || fail "instance $i printed an unparsable RUN line: $run_line (log: $log)"

  TOKENS+=("$token")
  DIRS+=("$dir")
  ok "instance-$i: PASS in workspace token=$token dir=$dir"
done

# Two concurrent runs must not share a workspace, or the isolation is a lie.
[[ "${TOKENS[0]}" != "${TOKENS[1]}" ]] \
  || fail "both instances used the same token '${TOKENS[0]}': workspaces collided (dirs: ${DIRS[0]} and ${DIRS[1]})"
[[ "${DIRS[0]}" != "${DIRS[1]}" ]] \
  || fail "both instances used the same run directory ${DIRS[0]}: workspaces collided"
ok "distinct-workspaces: ${TOKENS[0]} (${DIRS[0]}) vs ${TOKENS[1]} (${DIRS[1]})"

# A finished run owns its workspace and must not leave it on disk: a leftover
# would let a later run reuse stale journals.
for i in 1 2; do
  idx=$((i - 1))
  dir="${DIRS[$idx]}"
  if [[ -e "$dir" ]]; then
    fail "instance $i left its run directory behind at $dir (token ${TOKENS[$idx]})"
  fi
  ok "cleaned-up: instance-$i removed $dir"
done

echo "PASS"
