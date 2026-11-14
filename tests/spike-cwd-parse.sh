#!/usr/bin/env bash
# T0 — parser test for the Phase 0 cwd probe.
#
# REQ-20261114-04 is only proven when the log says which cwd the subagent
# inherited AND whether the out-of-cwd directory was reachable.
# tools/spike-cwd.sh turns that log into a verdict; these fixtures pin the
# three outcomes that matter.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER="$ROOT/tools/spike-cwd.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$PARSER" ]]; then
  echo "FAIL: parser missing or not executable at $PARSER" >&2
  exit 1
fi

expect() {
  local name="$1" want="$2" log="$3"
  local out
  out="$("$PARSER" "$log" 2>&1 || true)"
  if ! grep -q "verdict=$want" <<<"$out"; then
    echo "FAIL[$name]: want verdict=$want, got: $out" >&2
    return 1
  fi
  echo "ok[$name]: $out"
}

# Subagent inherits the parent cwd but the worktree is still reachable by
# absolute path: the isolation we need is available, just not by cd.
cat >"$TMP/reachable.log" <<'LOG'
[10:00:01] cwd: parent cwd=/home/anhydrite/metronome
[10:00:01] cwd: probe_dir=/home/anhydrite/.local/state/maki/metronome-spike/probe-worktree
[10:00:01] cwd: reply: PWD=/home/anhydrite/metronome
[10:00:01] cwd: reply: LS=ok
LOG

# Subagent runs inside the worktree already (cwd was set for it).
cat >"$TMP/in-worktree.log" <<'LOG'
[10:00:01] cwd: parent cwd=/home/anhydrite/metronome
[10:00:01] cwd: probe_dir=/home/anhydrite/.local/state/maki/metronome-spike/probe-worktree
[10:00:01] cwd: reply: PWD=/home/anhydrite/.local/state/maki/metronome-spike/probe-worktree
[10:00:01] cwd: reply: LS=ok
LOG

# Directory not reachable at all: the worktree plan needs a different route.
cat >"$TMP/unreachable.log" <<'LOG'
[10:00:01] cwd: parent cwd=/home/anhydrite/metronome
[10:00:01] cwd: probe_dir=/home/anhydrite/.local/state/maki/metronome-spike/probe-worktree
[10:00:01] cwd: reply: PWD=/home/anhydrite/metronome
[10:00:01] cwd: reply: LS=missing
LOG

expect reachable reachable "$TMP/reachable.log"
expect in-worktree reachable "$TMP/in-worktree.log"
expect unreachable unreachable "$TMP/unreachable.log"

# The inheritance flag must be derived, not guessed.
out="$("$PARSER" "$TMP/reachable.log")"
grep -q "inherits_parent_cwd=yes" <<<"$out" || { echo "FAIL: inheritance not derived" >&2; exit 1; }
out="$("$PARSER" "$TMP/in-worktree.log")"
grep -q "inherits_parent_cwd=no" <<<"$out" || { echo "FAIL: inheritance not derived" >&2; exit 1; }

echo "PASS"
