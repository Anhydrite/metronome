#!/usr/bin/env bash
# T0 — test for tools/sync-findings-to-plan.sh (REQ-20261114-08).
#
# The bridge between measurement and design must (a) refuse an unfinished
# findings document, (b) copy all four decisions into the plan, and (c) be
# idempotent so a second run does not duplicate the block.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/tools/sync-findings-to-plan.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$SYNC" ]]; then
  echo "FAIL: sync tool missing or not executable at $SYNC" >&2
  exit 1
fi

cat >"$TMP/plan.md" <<'DOC'
# Plan

## 7. Risques et decisions ouvertes

| Risque | Impact | Mitigation |
|---|---|---|
| cwd des subagents non controlable | ecriture hors worktree | spike |
DOC

cat >"$TMP/incomplete.md" <<'DOC'
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

cat >"$TMP/complete.md" <<'DOC'
# Spike findings

## Probe 1 — modeles
Observation: parent thinking=high, requested max, verdict capped by the parent ceiling.
Decision: Metronome runs at thinking=max so roles can request what they need.

## Probe 2 — cwd
Observation: subagent inherited the parent cwd, worktree reachable by absolute path.
Decision: the runner passes absolute worktree paths and exposes a workspace tool.

## Probe 3 — permissions
Observation: background write succeeded, file on disk held the marker after the run.
Decision: register_permission_rule on the worktree, plugin.toml grants fs_write.

## Probe 4 — reload
Observation: run started before /reload, session ended with reason=reload, no finish.
Decision: the pipeline resumes from state.jsonl on load, never from the task.
DOC

# (a) an unfinished findings document must be refused, and the plan untouched.
cp "$TMP/plan.md" "$TMP/plan-guard.md"
if "$SYNC" "$TMP/incomplete.md" "$TMP/plan-guard.md" >/dev/null 2>&1; then
  echo "FAIL: sync accepted an unfinished findings document" >&2
  exit 1
fi
if ! cmp -s "$TMP/plan.md" "$TMP/plan-guard.md"; then
  echo "FAIL: sync modified the plan despite refusing" >&2
  exit 1
fi
echo "ok[refuses-incomplete]: refused and left the plan untouched"

# (b) all four decisions land in the plan.
"$SYNC" "$TMP/complete.md" "$TMP/plan.md" >/dev/null
for n in 1 2 3 4; do
  grep -q "Probe $n" "$TMP/plan.md" || { echo "FAIL: Probe $n decision missing from plan" >&2; exit 1; }
done
grep -q "thinking=max so roles can request" "$TMP/plan.md" || { echo "FAIL: decision text not copied" >&2; exit 1; }
echo "ok[all-four]: four decisions copied"

# (c) a second run must not duplicate the block.
"$SYNC" "$TMP/complete.md" "$TMP/plan.md" >/dev/null
count="$(grep -c 'spike-decisions:begin' "$TMP/plan.md")"
if [[ "$count" -ne 1 ]]; then
  echo "FAIL: block duplicated ($count markers after two runs)" >&2
  exit 1
fi
echo "ok[idempotent]: one block after two runs"

# The original plan content must survive the sync.
grep -q "cwd des subagents non controlable" "$TMP/plan.md" || { echo "FAIL: plan content lost" >&2; exit 1; }
echo "ok[preserves-plan]: existing content kept"

echo "PASS"
