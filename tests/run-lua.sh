#!/usr/bin/env bash
# Run the Lua test suite inside maki's own Lua host.
#
# This machine has no standalone Lua interpreter, so the suite runs as a
# project plugin: `maki index <file>` loads it without calling a model, the
# harness writes lua-results.txt, and this script judges that file.
#
# Isolation: every invocation owns a unique token and keeps ALL its temporary
# state under <state_dir>/metronome-tests/<token>/. Two runs in the same
# checkout therefore cannot reset each other's journals, repositories or
# worktrees. MAKI_TEST_TOKEN is exported so the Lua harness and the test files
# resolve the same directory; an inherited value is honoured.
#
# Usage: tests/run-lua.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
MAKI_TEST_TOKEN="${MAKI_TEST_TOKEN:-$(date +%Y%m%d%H%M%S)-$$-${RANDOM}${RANDOM}}"
# The token becomes a single path component under metronome-tests/ and the
# cleanup below removes it recursively, so an inherited value must not be able
# to escape that directory (`MAKI_TEST_TOKEN=../..` would otherwise delete
# unrelated state). Refuse anything but one safe component.
if [[ ! "$MAKI_TEST_TOKEN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$MAKI_TEST_TOKEN" == *..* ]]; then
  echo "FAIL: unsafe MAKI_TEST_TOKEN: use letters, digits, '.', '_' or '-' (no '/', no '..')" >&2
  exit 2
fi
export MAKI_TEST_TOKEN
TESTS_ROOT="$STATE_HOME/maki/metronome-tests"
TEST_DIR="$TESTS_ROOT/$MAKI_TEST_TOKEN"
RESULTS="$TEST_DIR/lua-results.txt"
ERRFILE="$TEST_DIR/metronome-harness-error.txt"

if [[ ! -f "$ROOT/.maki/init.lua" ]]; then
  echo "FAIL: missing .maki/init.lua harness entry" >&2
  exit 1
fi

# The token directory and its results file go away at the end of the run,
# success or failure. The journal validation below runs before this trap, so
# the journals are still there when they are judged.
cleanup() {
  # Belt and braces: even though the token is validated above, only ever delete
  # a directory that really sits under metronome-tests/.
  case "$TEST_DIR" in
    "$TESTS_ROOT"/*) rm -rf -- "$TEST_DIR" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$TEST_DIR"

# `maki index` exits non-zero for reasons unrelated to plugins, so the result
# file is the judge, not the exit code.
METRONOME_LUA_TESTS=1 maki --trust index "$ROOT/README.md" >/dev/null 2>&1 || true

if [[ -f "$ERRFILE" ]]; then
  echo "FAIL: harness could not load:" >&2
  cat "$ERRFILE" >&2
  exit 1
fi

if [[ ! -f "$RESULTS" ]]; then
  echo "FAIL: harness produced no results at $RESULTS" >&2
  exit 1
fi

cat "$RESULTS"

if grep -q '^FAIL ' "$RESULTS"; then
  echo "FAIL: at least one Lua assertion failed" >&2
  exit 1
fi

summary="$(grep '^SUMMARY ' "$RESULTS" || true)"
if [[ -z "$summary" ]]; then
  echo "FAIL: no SUMMARY line; the harness did not finish" >&2
  exit 1
fi

if ! grep -q 'failed=0' <<<"$summary"; then
  echo "FAIL: $summary" >&2
  exit 1
fi

echo "PASS: $summary"

# The journal state.lua just wrote must satisfy the schemas. Checking it here,
# on every run, is what stops the code and the contract from drifting apart.
JOURNAL="$TEST_DIR/roundtrip/state.jsonl"
if [[ -f "$JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$JOURNAL" >/dev/null || {
    echo "FAIL: the journal state.lua wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by state.lua satisfies event and task schemas"
fi

# The end-to-end git/PR test writes the same kind of journal, but through the
# whole chain (fetch -> worktree -> commit -> push -> pr_open). Validating it too
# is what proves the PR and the pr_open status are schema-legal, not just that
# the Lua assertions were happy.
E2E_JOURNAL="$TEST_DIR/git-pr-e2e/state/state.jsonl"
if [[ -f "$E2E_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$E2E_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the git/PR e2e test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$E2E_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the git/PR e2e test satisfies event and task schemas ($E2E_JOURNAL)"
fi

# The qualifier writes tasks through the same state module. Its journal is
# validated too: a qualification that produces schema-illegal tasks must not
# pass just because the Lua assertions were happy.
QUALIFY_JOURNAL="$TEST_DIR/qualify/state/state.jsonl"
if [[ -f "$QUALIFY_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$QUALIFY_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the qualify test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$QUALIFY_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the qualify test satisfies event and task schemas ($QUALIFY_JOURNAL)"
fi

# The question loop answers questions and moves tasks back to qualifying. Its
# journal is validated too: an answer written as a schema-illegal field patch
# must not pass just because the Lua assertions were happy.
QUESTIONS_JOURNAL="$TEST_DIR/questions/state/state.jsonl"
if [[ -f "$QUESTIONS_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$QUESTIONS_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the questions test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$QUESTIONS_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the questions test satisfies event and task schemas ($QUESTIONS_JOURNAL)"
fi

# The analyzer gates tasks from qualifying to ready through the same state
# module. Its journal is validated too: a gate that moves a schema-illegal
# task must not pass just because the Lua assertions were happy.
ANALYZE_JOURNAL="$TEST_DIR/analyze/state/state.jsonl"
if [[ -f "$ANALYZE_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$ANALYZE_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the analyze test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$ANALYZE_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the analyze test satisfies event and task schemas ($ANALYZE_JOURNAL)"
fi

# The implementer prepares a worktree, checkpoints the branch and runs a turn.
# Its journal is validated too: a turn that writes a schema-illegal checkpoint
# or worktree path must not pass just because the Lua assertions were happy.
IMPLEMENT_JOURNAL="$TEST_DIR/implement/state/state.jsonl"
if [[ -f "$IMPLEMENT_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$IMPLEMENT_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the implement test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$IMPLEMENT_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the implement test satisfies event and task schemas ($IMPLEMENT_JOURNAL)"
fi

# The checks test writes a task whose last checkpoint is read back for the
# rollback. Validating that journal keeps the checkpoint shape honest too.
CHECKS_JOURNAL="$TEST_DIR/checks/state/state.jsonl"
if [[ -f "$CHECKS_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$CHECKS_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the checks test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$CHECKS_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the checks test satisfies event and task schemas ($CHECKS_JOURNAL)"
fi

# The reviewer stores the exact commit it reviewed and the structured findings
# on the task. Validating that journal keeps the review object schema-legal:
# an empty findings table must be omitted, not encoded as `{}`.
REVIEW_JOURNAL="$TEST_DIR/review/state/state.jsonl"
if [[ -f "$REVIEW_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$REVIEW_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the review test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$REVIEW_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the review test satisfies event and task schemas ($REVIEW_JOURNAL)"
fi

# The merge test moves a task pr_open -> merging -> merged (or failed) and
# rewrites its PR state. Validating that journal keeps the merge path legal:
# a merge that writes a schema-illegal PR or status must not pass just because
# the Lua assertions were happy.
MERGE_JOURNAL="$TEST_DIR/merge/state/state.jsonl"
if [[ -f "$MERGE_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$MERGE_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the merge test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$MERGE_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the merge test satisfies event and task schemas ($MERGE_JOURNAL)"
fi

# The deploy test moves a task merged -> deploying -> deployed (or failed) and
# appends the deploy notes. Validating that journal keeps the deploy path legal:
# a deploy that writes a schema-illegal status or note must not pass just
# because the Lua assertions were happy.
DEPLOY_JOURNAL="$TEST_DIR/deploy/state/state.jsonl"
if [[ -f "$DEPLOY_JOURNAL" ]]; then
  "$ROOT/tools/validate-state.py" "$DEPLOY_JOURNAL" >/dev/null || {
    echo "FAIL: the journal the deploy test wrote violates the schemas:" >&2
    "$ROOT/tools/validate-state.py" "$DEPLOY_JOURNAL" >&2 || true
    exit 1
  }
  echo "PASS: journal written by the deploy test satisfies event and task schemas ($DEPLOY_JOURNAL)"
fi
