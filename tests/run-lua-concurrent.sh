#!/usr/bin/env bash
# Prove two harness runs can run at the same time in the same checkout.
#
# Two independent `sh tests/run-lua.sh` invocations start together, with
# MAKI_TEST_TOKEN removed from their environment so each one must derive its own
# isolation token. Both must print PASS: a shared journal, a shared result file
# or a shared temp directory shows up here as a false failure.
#
# Usage: tests/run-lua-concurrent.sh
#
# T0 evidence (red first). This script was written and run before the isolation
# change, against the unmodified base tree (commit dd903df, the base of this
# branch) with only this file copied in:
#
#   $ cd <base tree> && sh tests/run-lua-concurrent.sh ; echo $?
#   PASS: concurrent run first finished green
#   FAIL: concurrent run second did not pass
#   --- second.log ---
#   ...
#   FAIL task with checkpoints created: task already exists: T-20261114-c001
#   FAIL T-20261114-cv03: worktree created: worktree add failed [git_error]:
#     ... fatal: not a git repository (or any parent up to mount point /)
#   FAIL T-20261114-mg05: seed committed: git commit failed [git_error]:
#     ... fatal: gitfile does not point to a valid repository:
#     .../state/maki/metronome-tests/merge/wt-T-20261114-mg05/.git
#   SUMMARY passed=3332 failed=8
#   FAIL: at least one Lua assertion failed
#   FAIL: two concurrent harness runs collided
#   1
#
# The first instance reached `SUMMARY passed=3538 failed=0`; the second one,
# running at the same time, found its tasks, worktrees and journals reset by
# the first because every test wrote to the fixed metronome-tests/<name> paths.
# Both go green once each run owns its token (the change this script proves).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/metronome-concurrent.XXXXXX")"
trap 'rm -rf "$LOGDIR"' EXIT

pids=()
ids=(first second)
for id in "${ids[@]}"; do
  # env -u: the children must not inherit a token from the caller, otherwise
  # they would share the caller's (or each other's) isolation directory.
  env -u MAKI_TEST_TOKEN sh "$ROOT/tests/run-lua.sh" >"$LOGDIR/$id.log" 2>&1 &
  pids+=("$!")
done

status=0
for i in "${!ids[@]}"; do
  id="${ids[$i]}"
  if wait "${pids[$i]}"; then
    echo "PASS: concurrent run $id finished green"
  else
    echo "FAIL: concurrent run $id did not pass" >&2
    status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  for id in "${ids[@]}"; do
    echo "--- $id.log ---" >&2
    cat "$LOGDIR/$id.log" >&2 || true
  done
  echo "FAIL: two concurrent harness runs collided" >&2
  exit 1
fi

echo "PASS: two concurrent harness runs"
