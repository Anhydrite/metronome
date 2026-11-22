#!/usr/bin/env bash
# Prove two harness runs can run at the same time in the same checkout.
#
# Two independent `sh tests/run-lua.sh` invocations start together, with
# MAKI_TEST_TOKEN removed from their environment so each one must derive its own
# isolation token. Both must print PASS: a shared journal, a shared result file
# or a shared temp directory shows up here as a false failure.
#
# Usage: tests/run-lua-concurrent.sh
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
