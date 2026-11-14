#!/usr/bin/env bash
# Tests for scripts/validate.sh (REQ-20261114-42).
#
# The validator is the gate before packaging: schemas, prompts and config must
# agree, and drift must be refused. These cases run the real repository once,
# then a throwaway fixture that is mutated one way at a time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE="$ROOT/scripts/validate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok[$*]"
}

[[ -x "$VALIDATE" ]] || fail "scripts/validate.sh is missing or not executable"

# 1. The repository validates ------------------------------------------------

"$VALIDATE" >/dev/null || fail "the repository does not validate"
ok repository

# 2. A fixture that validates, then drifts -----------------------------------

FIX="$TMP/fixture"
mkdir -p "$FIX/maki/lua/metronome"
cp -R "$ROOT/schemas" "$FIX/schemas"
cp -R "$ROOT/prompts" "$FIX/prompts"
cp -R "$ROOT/templates" "$FIX/templates"
cp "$ROOT/maki/lua/metronome/roles.lua" "$FIX/maki/lua/metronome/roles.lua"
cp "$ROOT/maki/lua/metronome/state.lua" "$FIX/maki/lua/metronome/state.lua"

"$VALIDATE" --root "$FIX" >/dev/null || fail "the baseline fixture does not validate"
ok baseline

# A missing prompt must be refused.
rm "$FIX/prompts/analyst.md"
if "$VALIDATE" --root "$FIX" >/dev/null 2>&1; then
  fail "a missing prompt was accepted"
fi
ok missing-prompt
cp "$ROOT/prompts/analyst.md" "$FIX/prompts/analyst.md"

# A role removed from roles.lua is drift.
sed -i 's/"analyst", //' "$FIX/maki/lua/metronome/roles.lua"
if "$VALIDATE" --root "$FIX" >/dev/null 2>&1; then
  fail "role drift was accepted"
fi
ok role-drift
cp "$ROOT/maki/lua/metronome/roles.lua" "$FIX/maki/lua/metronome/roles.lua"

# A status added to the task schema but not to state.lua is drift.
python3 - "$FIX/schemas/task.schema.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    schema = json.load(handle)
schema["properties"]["status"]["enum"].append("vibing")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(schema, handle)
PY
if "$VALIDATE" --root "$FIX" >/dev/null 2>&1; then
  fail "status drift was accepted"
fi
ok status-drift
cp "$ROOT/schemas/task.schema.json" "$FIX/schemas/task.schema.json"

# A thinking level removed from roles.lua is drift.
sed -i 's/^  adaptive = 3,$//' "$FIX/maki/lua/metronome/roles.lua"
if "$VALIDATE" --root "$FIX" >/dev/null 2>&1; then
  fail "thinking drift was accepted"
fi
ok thinking-drift
cp "$ROOT/maki/lua/metronome/roles.lua" "$FIX/maki/lua/metronome/roles.lua"

# A broken schema is refused.
printf '{not json\n' > "$FIX/schemas/event.schema.json"
if "$VALIDATE" --root "$FIX" >/dev/null 2>&1; then
  fail "a broken schema was accepted"
fi
ok broken-schema
cp "$ROOT/schemas/event.schema.json" "$FIX/schemas/event.schema.json"

# An invalid template config is refused.
sed -i 's/^base_ref = "master"/base_ref = 42/' "$FIX/templates/config.toml"
if "$VALIDATE" --root "$FIX" >/dev/null 2>&1; then
  fail "an invalid config was accepted"
fi
ok bad-config

# 3. Help and bad usage ------------------------------------------------------

"$VALIDATE" --help >/dev/null || fail "--help failed"
if "$VALIDATE" --nonsense >/dev/null 2>&1; then
  fail "an unknown option was accepted"
fi
ok help

echo "PASS"
