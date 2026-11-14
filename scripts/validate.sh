#!/usr/bin/env bash
# validate.sh — Validate the Metronome schemas, prompts and config coherence.
#
# Usage:
#   ./scripts/validate.sh [--root DIR] [--help]
#
# Checks:
#   - every schemas/*.schema.json is valid JSON and a valid JSON Schema;
#   - every role has a non-empty prompts/<role>.md whose heading names it, and
#     prompts/_global.md exists;
#   - the role set is identical in roles.lua, prompts/, the config schema and
#     templates/config.toml;
#   - the thinking levels in roles.lua match the config schema enum;
#   - the statuses in state.lua match the task schema enum, and every
#     transition target is a known status;
#   - templates/config.toml satisfies schemas/config.schema.json.
#
# --root validates another tree (used by tests/validate.sh to prove that drift
# is refused). The validator tool itself always comes from this repository.
set -euo pipefail

SELF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SELF_ROOT"

usage() {
  cat <<EOF
Usage: $0 [--root DIR] [--help]

  --root DIR   Validate another tree (default: this repository).
  --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || {
        echo "error: --root needs a directory" >&2
        exit 2
      }
      ROOT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$ROOT" ]] || {
  echo "error: no such directory: $ROOT" >&2
  exit 2
}
ROOT="$(cd "$ROOT" && pwd)"

FAILED=0

ok() {
  echo "ok[$*]"
}

fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

echo "Metronome validation"
echo "  root: $ROOT"
echo ""

# Schemas, roles, prompts, thinking levels and statuses ----------------------

if python3 - "$ROOT" <<'PY'
import json
import re
import sys
from pathlib import Path

try:
    import jsonschema
except ModuleNotFoundError:
    print("FAIL: jsonschema is not installed", file=sys.stderr)
    sys.exit(1)

root = Path(sys.argv[1])
failed = False


def fail(msg):
    global failed
    failed = True
    print(f"FAIL: {msg}", file=sys.stderr)


def ok(name):
    print(f"ok[{name}]")


# 1. Schemas ---------------------------------------------------------------

expected = ["config", "task", "event"]
schemas = {}
for name in expected:
    path = root / "schemas" / f"{name}.schema.json"
    if not path.is_file():
        fail(f"missing schema: {path}")
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        jsonschema.Draft7Validator.check_schema(data)
        schemas[name] = data
    except Exception as exc:  # noqa: BLE001 - report the exact failure
        fail(f"{path.name}: {exc}")
if len(schemas) == len(expected):
    ok("schemas")

# 2. Roles and prompts -----------------------------------------------------

roles_lua_path = root / "maki" / "lua" / "metronome" / "roles.lua"
state_lua_path = root / "maki" / "lua" / "metronome" / "state.lua"
prompts_dir = root / "prompts"
template_path = root / "templates" / "config.toml"

known = set()
if roles_lua_path.is_file():
    text = roles_lua_path.read_text(encoding="utf-8")
    match = re.search(r"local KNOWN = \{([^}]*)\}", text)
    if match:
        known = set(re.findall(r'"([^"]+)"', match.group(1)))
    else:
        fail("roles.lua: cannot find the KNOWN role list")
else:
    fail(f"missing {roles_lua_path}")

prompt_roles = set()
if prompts_dir.is_dir():
    prompt_roles = {p.stem for p in prompts_dir.glob("*.md") if p.stem != "_global"}
    global_prompt = prompts_dir / "_global.md"
    if not global_prompt.is_file():
        fail("missing prompts/_global.md")
    elif not global_prompt.read_text(encoding="utf-8").strip():
        fail("prompts/_global.md is empty")
else:
    fail(f"missing {prompts_dir}")

for role in sorted(prompt_roles | known):
    path = prompts_dir / f"{role}.md"
    if not path.is_file():
        fail(f"missing prompt for role: {role}")
        continue
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        fail(f"prompts/{role}.md is empty")
    else:
        first = text.splitlines()[0]
        if not first.startswith("# Role — ") or f"({role})" not in first:
            fail(
                f"prompts/{role}.md must start with '# Role — <orchestra name> ({role})'"
            )

schema_roles = set()
if "config" in schemas:
    roles_schema = schemas["config"].get("properties", {}).get("roles", {})
    schema_roles = set(roles_schema.get("required", []))

template_roles = set()
try:
    import tomllib

    with open(template_path, "rb") as handle:
        template = tomllib.load(handle)
    template_roles = set(template.get("roles", {}).keys())
except Exception as exc:  # noqa: BLE001 - a broken template is a finding
    fail(f"templates/config.toml: {exc}")

reference = known or prompt_roles or schema_roles or template_roles
role_sets = {
    "roles.lua": known,
    "prompts/": prompt_roles,
    "config schema": schema_roles,
    "templates/config.toml": template_roles,
}
drifted = False
for label, value in role_sets.items():
    if value != reference:
        drifted = True
        fail(f"role drift: {label} has {sorted(value)}, expected {sorted(reference)}")
if not drifted and reference:
    ok("roles")

# 3. Thinking levels -------------------------------------------------------

if "config" in schemas and roles_lua_path.is_file():
    enum = set(
        schemas["config"]
        .get("definitions", {})
        .get("role", {})
        .get("properties", {})
        .get("thinking", {})
        .get("enum", [])
    )
    text = roles_lua_path.read_text(encoding="utf-8")
    match = re.search(r"local THINKING_RANK = \{(.*?)\n\}", text, re.S)
    if not match:
        fail("roles.lua: cannot find THINKING_RANK")
    else:
        ranks = set(re.findall(r"(\w+)\s*=\s*\d+", match.group(1)))
        if ranks != enum:
            fail(f"thinking drift: roles.lua has {sorted(ranks)}, schema has {sorted(enum)}")
        else:
            ok("thinking")

# 4. Statuses --------------------------------------------------------------

if "task" in schemas and state_lua_path.is_file():
    statuses = set(
        schemas["task"].get("properties", {}).get("status", {}).get("enum", [])
    )
    text = state_lua_path.read_text(encoding="utf-8")
    match = re.search(r"local TRANSITIONS = \{(.*?)\n\}", text, re.S)
    if not match:
        fail("state.lua: cannot find TRANSITIONS")
    else:
        block = match.group(1)
        keys = set(re.findall(r"^\s*(\w+)\s*=\s*\{", block, re.M))
        targets = set(re.findall(r"(\w+)\s*=\s*true", block))
        if keys != statuses:
            fail(f"status drift: state.lua keys {sorted(keys)} vs schema {sorted(statuses)}")
        elif not targets <= statuses:
            fail(
                "status drift: state.lua targets "
                f"{sorted(targets - statuses)} are not in the schema"
            )
        else:
            ok("statuses")

sys.exit(1 if failed else 0)
PY
then
  :
else
  FAILED=1
fi

# Config -------------------------------------------------------------------

if python3 "$SELF_ROOT/tools/validate-config.py" \
  "$ROOT/templates/config.toml" \
  "$ROOT/schemas/config.schema.json" >/dev/null; then
  ok "config"
else
  fail "templates/config.toml does not satisfy schemas/config.schema.json"
  python3 "$SELF_ROOT/tools/validate-config.py" \
    "$ROOT/templates/config.toml" \
    "$ROOT/schemas/config.schema.json" >&2 || true
fi

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "FAIL: validation found problems" >&2
  exit 1
fi
echo "PASS"
