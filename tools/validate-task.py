#!/usr/bin/env python3
"""Validate one task JSON file against schemas/task.schema.json.

REQ-20261114-24: the qualifier's answer is constrained by the real schema, not
a hand-copied subset. The Lua side projects a task onto the object the schema
actually governs and calls this tool, so the schema file stays the authority.

Usage:
    tools/validate-task.py <task.json>

Exit 0 when valid, 1 when invalid, 2 on a usage error.
"""

import json
import sys
from pathlib import Path

try:
    import jsonschema
except ModuleNotFoundError:
    print("error: jsonschema not installed", file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
TASK_SCHEMA = ROOT / "schemas" / "task.schema.json"


def fail(msg: str) -> None:
    print(msg, file=sys.stderr)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    task_path = Path(sys.argv[1])
    if not task_path.is_file():
        fail(f"invalid task JSON: missing file {task_path}")
        return 1

    try:
        task = json.loads(task_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail(f"invalid task JSON: {e}")
        return 1

    schema = json.loads(TASK_SCHEMA.read_text(encoding="utf-8"))
    validator = jsonschema.Draft7Validator(schema)

    errors = sorted(validator.iter_errors(task), key=lambda e: list(e.absolute_path))
    if errors:
        for err in errors:
            where = ".".join(str(p) for p in err.absolute_path) or "<root>"
            fail(f"{where}: {err.message}")
        return 1

    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
