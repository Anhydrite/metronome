#!/usr/bin/env bash
# Run the Lua test suite inside maki's own Lua host.
#
# This machine has no standalone Lua interpreter, so the suite runs as a
# project plugin: `maki index <file>` loads it without calling a model, the
# harness writes its results, and this script judges that file.
#
# Every invocation gets its own workspace under
# <state_dir>/metronome-tests/<token>/ so two runs can execute in parallel
# without sharing a journal, a temporary repository or a worktree.
#
# Usage: tests/run-lua.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/maki"

# One token per run. A caller that already exported MAKI_TEST_TOKEN (a nested
# harness, a check that wants the artifacts) keeps its identity; otherwise mint
# one from the clock, the pid and randomness so concurrent runs cannot collide.
OWN_TOKEN=0
if [[ -n "${MAKI_TEST_TOKEN:-}" ]]; then
  TOKEN="$MAKI_TEST_TOKEN"
else
  TOKEN="$(date +%s%N)-$$-${RANDOM}${RANDOM}"
  MAKI_TEST_TOKEN="$TOKEN"
  OWN_TOKEN=1
fi
export MAKI_TEST_TOKEN

RUN_DIR="$STATE/metronome-tests/$TOKEN"

# Where the Lua tests write their journals. maki derives its state dir as
# <XDG_STATE_HOME>/maki and every tests/lua file writes under
# <state_dir>/metronome-tests/<name>, so with XDG_STATE_HOME="$RUN_DIR" (below)
# the journals root is $RUN_DIR/maki/metronome-tests. This is deliberately not
# $RUN_DIR/<name>: maki inserts its own "maki" level and the per-test <name>
# suffix is fixed in the test files, which this change may not touch. The root
# is exported so metronome_test.lua's test_dir() helper resolves exactly where
# validate_journal() looks, and printed so an operator finds the artifacts.
TESTS_DIR="$RUN_DIR/maki/metronome-tests"

export MAKI_TEST_RESULTS="$RUN_DIR/lua-results.txt"
export MAKI_TEST_ERROR_PATH="$RUN_DIR/harness-error.txt"
export MAKI_TEST_JOURNALS="$TESTS_DIR"

# Print the workspace so a caller can prove two concurrent runs are distinct.
echo "RUN: token=$TOKEN dir=$RUN_DIR journals=$TESTS_DIR"

if [[ ! -f "$ROOT/.maki/init.lua" ]]; then
  echo "FAIL: missing .maki/init.lua harness entry" >&2
  exit 1
fi

# Own the workspace: remove it on exit, after the journals have been validated,
# on success and on failure alike. A reused token belongs to the caller, so its
# run dir survives -- but the journals it may still hold are dropped below, so
# a stale journal can never satisfy validate_journal() for this run.
if [[ "$OWN_TOKEN" -eq 1 ]]; then
  rm -rf "$RUN_DIR"
  trap 'rm -rf "$RUN_DIR"' EXIT
fi
mkdir -p "$RUN_DIR"

# maki derives its state dir as <XDG_STATE_HOME>/maki, and every Lua test writes
# under <state_dir>/metronome-tests/<name>. Pointing XDG_STATE_HOME at this
# run's workspace therefore moves all of those paths (journals, temp repos,
# worktrees) under $TESTS_DIR without touching a single test file, while keeping
# them real paths so git's canonical comparisons still match.
export XDG_STATE_HOME="$RUN_DIR"

# Start from empty artifacts, in reuse mode too: validate_journal() only detects
# a missing journal, so leftovers from an earlier run with the same token could
# otherwise vouch for a journal this run never wrote.
rm -rf "$TESTS_DIR"
rm -f "$MAKI_TEST_RESULTS" "$MAKI_TEST_ERROR_PATH"

# `maki index` exits non-zero for reasons unrelated to plugins, so the result
# file is the judge, not the exit code.
METRONOME_LUA_TESTS=1 maki --trust index "$ROOT/README.md" >/dev/null 2>&1 || true

if [[ -f "$MAKI_TEST_ERROR_PATH" ]]; then
  echo "FAIL: harness could not load:" >&2
  cat "$MAKI_TEST_ERROR_PATH" >&2
  exit 1
fi

if [[ ! -f "$MAKI_TEST_RESULTS" ]]; then
  echo "FAIL: harness produced no results at $MAKI_TEST_RESULTS" >&2
  exit 1
fi

cat "$MAKI_TEST_RESULTS"

if grep -q '^FAIL ' "$MAKI_TEST_RESULTS"; then
  echo "FAIL: at least one Lua assertion failed" >&2
  exit 1
fi

summary="$(grep '^SUMMARY ' "$MAKI_TEST_RESULTS" || true)"
if [[ -z "$summary" ]]; then
  echo "FAIL: no SUMMARY line; the harness did not finish" >&2
  exit 1
fi

if ! grep -q 'failed=0' <<<"$summary"; then
  echo "FAIL: $summary" >&2
  exit 1
fi

echo "PASS: $summary"

# Validate one journal written by a test. A missing journal is a hard failure:
# a path drift must not silently skip the schema check that guards the test.
validate_journal() {
  local label="$1" rel="$2"
  local path="$TESTS_DIR/$rel"
  if [[ ! -f "$path" ]]; then
    echo "FAIL: expected journal for $label is missing at $path" >&2
    exit 1
  fi
  if ! "$ROOT/tools/validate-state.py" "$path" >/dev/null; then
    echo "FAIL: the journal for $label violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$path" >&2 || true
    exit 1
  fi
  echo "PASS: journal for $label satisfies event and task schemas ($path)"
}

# The journal state.lua wrote, the end-to-end git/PR journal, and one journal
# per role that moves a task: all live in this run's workspace and all must
# satisfy the schemas on every run, so code and contract cannot drift apart.
validate_journal "state.lua" "roundtrip/state.jsonl"
validate_journal "the git/PR e2e test" "git-pr-e2e/state/state.jsonl"
validate_journal "the qualify test" "qualify/state/state.jsonl"
validate_journal "the questions test" "questions/state/state.jsonl"
validate_journal "the analyze test" "analyze/state/state.jsonl"
validate_journal "the implement test" "implement/state/state.jsonl"
validate_journal "the checks test" "checks/state/state.jsonl"
validate_journal "the review test" "review/state/state.jsonl"
validate_journal "the merge test" "merge/state/state.jsonl"
validate_journal "the deploy test" "deploy/state/state.jsonl"
