#!/usr/bin/env bash
# T0 — journal/schema contract (REQ-20261114-14).
#
# The schemas are only worth anything if the code that writes the journal
# satisfies them. This validates a journal produced by state.lua itself, plus
# the cases the schema must refuse.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE="$ROOT/tools/validate-state.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$VALIDATE" ]]; then
  echo "FAIL: validator missing or not executable at $VALIDATE" >&2
  exit 1
fi

for s in task event; do
  [[ -f "$ROOT/schemas/$s.schema.json" ]] || { echo "FAIL: missing schemas/$s.schema.json" >&2; exit 1; }
done

accept() {
  local name="$1" file="$2"
  if ! "$VALIDATE" "$file" >/dev/null 2>&1; then
    echo "FAIL[$name]: valid journal rejected:" >&2
    "$VALIDATE" "$file" >&2 || true
    return 1
  fi
  echo "ok[$name]: accepted"
}

reject() {
  local name="$1" file="$2" needle="$3"
  local out
  if out="$("$VALIDATE" "$file" 2>&1)"; then
    echo "FAIL[$name]: invalid journal accepted" >&2
    return 1
  fi
  if [[ -n "$needle" ]] && ! grep -q "$needle" <<<"$out"; then
    echo "FAIL[$name]: error did not mention '$needle': $out" >&2
    return 1
  fi
  echo "ok[$name]: rejected"
}

# A journal shaped exactly like state.lua writes it.
cat >"$TMP/real.jsonl" <<'JSONL'
{"kind":"task_created","task_id":"T-20261114-a3f2","at":"2026-11-14T10:00:00Z","task":{"id":"T-20261114-a3f2","title":"export CSV","status":"draft","created_at":"2026-11-14T10:00:00Z","updated_at":"2026-11-14T10:00:00Z"}}
{"kind":"status","task_id":"T-20261114-a3f2","status":"qualifying","at":"2026-11-14T10:01:00Z"}
{"kind":"field","task_id":"T-20261114-a3f2","at":"2026-11-14T10:02:00Z","fields":{"branch":"metronome/T-20261114-a3f2","files":["src/export.ts"],"checks":["npm test -- export"]}}
{"kind":"note","task_id":"T-20261114-a3f2","at":"2026-11-14T10:03:00Z","text":"qualifier asked two questions"}
{"kind":"status","task_id":"T-20261114-a3f2","status":"ready","at":"2026-11-14T10:04:00Z"}
JSONL
accept real-journal "$TMP/real.jsonl"

# A torn final line is what a crash leaves behind: tolerated.
cp "$TMP/real.jsonl" "$TMP/torn.jsonl"
printf '{"kind":"status","task_id":"T-20261114-a3f2","sta' >>"$TMP/torn.jsonl"
accept torn-tail "$TMP/torn.jsonl"

# Corruption in the middle is not tolerated.
head -2 "$TMP/real.jsonl" >"$TMP/mid.jsonl"
printf 'not json at all\n' >>"$TMP/mid.jsonl"
tail -2 "$TMP/real.jsonl" >>"$TMP/mid.jsonl"
reject mid-corruption "$TMP/mid.jsonl" "corruption before the tail"

# An unknown event kind must be refused.
cat >"$TMP/bad-kind.jsonl" <<'JSONL'
{"kind":"teleport","task_id":"T-20261114-a3f2","at":"2026-11-14T10:00:00Z"}
JSONL
reject bad-kind "$TMP/bad-kind.jsonl" "kind"

# task_created without its task payload must be refused.
cat >"$TMP/no-task.jsonl" <<'JSONL'
{"kind":"task_created","task_id":"T-20261114-a3f2","at":"2026-11-14T10:00:00Z"}
JSONL
reject missing-task "$TMP/no-task.jsonl" "task"

# A status event without a status must be refused.
cat >"$TMP/no-status.jsonl" <<'JSONL'
{"kind":"task_created","task_id":"T-20261114-a3f2","at":"2026-11-14T10:00:00Z","task":{"id":"T-20261114-a3f2","title":"x","status":"draft"}}
{"kind":"status","task_id":"T-20261114-a3f2","at":"2026-11-14T10:01:00Z"}
JSONL
reject missing-status "$TMP/no-status.jsonl" "status"

# A task with an unknown status must be refused at the task layer.
cat >"$TMP/bad-task.jsonl" <<'JSONL'
{"kind":"task_created","task_id":"T-20261114-a3f2","at":"2026-11-14T10:00:00Z","task":{"id":"T-20261114-a3f2","title":"x","status":"vibing"}}
JSONL
reject bad-task-status "$TMP/bad-task.jsonl" "status"

# A task id that does not match the pattern must be refused.
cat >"$TMP/bad-id.jsonl" <<'JSONL'
{"kind":"task_created","task_id":"task-one","at":"2026-11-14T10:00:00Z","task":{"id":"task-one","title":"x","status":"draft"}}
JSONL
reject bad-task-id "$TMP/bad-id.jsonl" "id"

echo "PASS"
