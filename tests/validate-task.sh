#!/usr/bin/env bash
# T0 — task JSON contract (REQ-20261114-24).
#
# The qualifier's answer is constrained by schemas/task.schema.json, and
# tools/validate-task.py is the single authority the Lua side calls. This
# validates a real task JSON plus the cases the schema must refuse.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE="$ROOT/tools/validate-task.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$VALIDATE" ]]; then
  echo "FAIL: validator missing or not executable at $VALIDATE" >&2
  exit 1
fi

[[ -f "$ROOT/schemas/task.schema.json" ]] || { echo "FAIL: missing schemas/task.schema.json" >&2; exit 1; }

accept() {
  local name="$1" file="$2"
  if ! "$VALIDATE" "$file" >/dev/null 2>&1; then
    echo "FAIL[$name]: valid task rejected:" >&2
    "$VALIDATE" "$file" >&2 || true
    return 1
  fi
  echo "ok[$name]: accepted"
}

reject() {
  local name="$1" file="$2" needle="$3"
  local out
  if out="$("$VALIDATE" "$file" 2>&1)"; then
    echo "FAIL[$name]: invalid task accepted" >&2
    return 1
  fi
  if [[ -n "$needle" ]] && ! grep -q "$needle" <<<"$out"; then
    echo "FAIL[$name]: error did not mention '$needle': $out" >&2
    return 1
  fi
  echo "ok[$name]: rejected"
}

# A task shaped exactly like the qualifier projects one.
cat >"$TMP/valid.json" <<'JSON'
{"id":"T-20261114-a3f2","title":"export CSV","intent":"export the invoices","status":"draft","files":["src/export.ts"],"checks":["npm test -- export"],"depends_on":["T-20261113-0001"],"questions":[{"id":"q1","text":"which format?"}]}
JSON
accept valid-task "$TMP/valid.json"

# acceptance is not a task field: the schema forbids it, and this is the exact
# mistake the old hand-copied subset let through.
cat >"$TMP/acceptance.json" <<'JSON'
{"id":"T-20261114-a3f2","title":"x","status":"draft","files":["f"],"checks":["c"],"acceptance":["works"]}
JSON
reject extra-acceptance "$TMP/acceptance.json" "acceptance"

# An id that does not match the pattern is refused.
cat >"$TMP/bad-id.json" <<'JSON'
{"id":"bad","title":"x","status":"draft"}
JSON
reject bad-id "$TMP/bad-id.json" "id"

# A required field is missing.
cat >"$TMP/no-title.json" <<'JSON'
{"id":"T-20261114-a3f2","status":"draft"}
JSON
reject missing-title "$TMP/no-title.json" "title"

# Broken JSON is refused with the parse error.
printf '{"id":' >"$TMP/broken.json"
reject broken-json "$TMP/broken.json" "invalid task JSON"

echo "PASS"
