#!/usr/bin/env bash
# T0 — checker test for docs/spike-findings.md (REQ-20261114-07).
#
# The document is only finished when each probe carries a raw observation and
# a decision. tools/check-findings.sh must reject placeholders and empty
# fields, and accept a filled document.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/tools/check-findings.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$CHECKER" ]]; then
  echo "FAIL: checker missing or not executable at $CHECKER" >&2
  exit 1
fi

reject() {
  local name="$1" file="$2"
  if "$CHECKER" "$file" >/dev/null 2>&1; then
    echo "FAIL[$name]: checker accepted a document it should reject" >&2
    return 1
  fi
  echo "ok[$name]: rejected"
}

accept() {
  local name="$1" file="$2"
  if ! "$CHECKER" "$file" >/dev/null 2>&1; then
    echo "FAIL[$name]: checker rejected a valid document:" >&2
    "$CHECKER" "$file" >&2 || true
    return 1
  fi
  echo "ok[$name]: accepted"
}

# Placeholders left in: not finished.
cat >"$TMP/placeholder.md" <<'DOC'
# Spike findings

## Probe 1 — modeles
Observation: TODO
Decision: TODO

## Probe 2 — cwd
Observation: TODO
Decision: TODO

## Probe 3 — permissions
Observation: TODO
Decision: TODO

## Probe 4 — reload
Observation: TODO
Decision: TODO
DOC

# A probe section missing entirely.
cat >"$TMP/missing.md" <<'DOC'
# Spike findings

## Probe 1 — modeles
Observation: parent thinking=high, requested max, verdict capped by the parent ceiling.
Decision: Metronome runs at thinking=max so roles can request what they need.

## Probe 2 — cwd
Observation: subagent inherited the parent cwd, worktree reachable by absolute path.
Decision: the runner passes absolute worktree paths and a workspace tool.

## Probe 3 — permissions
Observation: background write succeeded, file on disk held the marker after the run.
Decision: register_permission_rule on the worktree, plugin.toml grants fs_write.
DOC

# A complete document.
cat >"$TMP/complete.md" <<'DOC'
# Spike findings

## Probe 1 — modeles
Observation: parent thinking=high, requested max, verdict capped by the parent ceiling.
Decision: Metronome runs at thinking=max so roles can request what they need.

## Probe 2 — cwd
Observation: subagent inherited the parent cwd, worktree reachable by absolute path.
Decision: the runner passes absolute worktree paths and a workspace tool.

## Probe 3 — permissions
Observation: background write succeeded, file on disk held the marker after the run.
Decision: register_permission_rule on the worktree, plugin.toml grants fs_write.

## Probe 4 — reload
Observation: run started before /reload, session ended with reason=reload, no finish.
Decision: the pipeline must resume from state.jsonl on load, never rely on the task.
DOC

# A decision that is too short to be evidence.
cat >"$TMP/thin.md" <<'DOC'
# Spike findings

## Probe 1 — modeles
Observation: parent thinking=high, requested max, verdict capped by the parent ceiling.
Decision: ok

## Probe 2 — cwd
Observation: subagent inherited the parent cwd, worktree reachable by absolute path.
Decision: the runner passes absolute worktree paths and a workspace tool.

## Probe 3 — permissions
Observation: background write succeeded, file on disk held the marker after the run.
Decision: register_permission_rule on the worktree, plugin.toml grants fs_write.

## Probe 4 — reload
Observation: run started before /reload, session ended with reason=reload, no finish.
Decision: the pipeline must resume from state.jsonl on load, never rely on the task.
DOC

reject placeholder "$TMP/placeholder.md"
reject missing "$TMP/missing.md"
reject thin "$TMP/thin.md"
accept complete "$TMP/complete.md"

echo "PASS"
