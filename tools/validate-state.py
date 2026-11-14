#!/usr/bin/env python3
"""Validate a Metronome journal against the event and task schemas.

REQ-20261114-14: state.lua writes the journal, and these schemas are the
contract it must honour. Validating a real journal — not a hand-written
fixture — is what keeps the code and the schema from drifting apart.

Usage:
    tools/validate-state.py <state.jsonl>

Checks, in order:
  * every non-blank line is a JSON object matching event.schema.json
  * replaying the events yields tasks matching task.schema.json
  * a torn final line is tolerated (it is what a crash leaves behind)

Exit 0 when valid, 1 when not, 2 on a usage error.
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
EVENT_SCHEMA = ROOT / "schemas" / "event.schema.json"
TASK_SCHEMA = ROOT / "schemas" / "task.schema.json"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)


def replay(events: list[dict]) -> dict[str, dict]:
    """Same rules as state.lua's replay, kept deliberately small."""
    tasks: dict[str, dict] = {}
    for event in events:
        tid = event.get("task_id")
        if not tid:
            continue
        kind = event.get("kind")
        if kind == "task_created":
            task = dict(event.get("task") or {})
            task["id"] = tid
            tasks[tid] = task
        elif tid in tasks:
            task = tasks[tid]
            if kind == "status":
                task["status"] = event.get("status")
                if "phase" in event:
                    task["phase"] = event["phase"]
            elif kind == "field":
                task.update(event.get("fields") or {})
            elif kind == "note":
                task.setdefault("notes", []).append(event.get("text"))
            if "at" in event:
                task["updated_at"] = event["at"]
    return tasks


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    journal_path = Path(sys.argv[1])
    if not journal_path.is_file():
        fail(f"missing journal {journal_path}")
        return 2

    event_schema = json.loads(EVENT_SCHEMA.read_text(encoding="utf-8"))
    task_schema = json.loads(TASK_SCHEMA.read_text(encoding="utf-8"))
    event_validator = jsonschema.Draft7Validator(event_schema)
    task_validator = jsonschema.Draft7Validator(task_schema)

    lines = journal_path.read_text(encoding="utf-8").splitlines()
    events: list[dict] = []
    problems = 0
    torn_tail = 0

    for lineno, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            # Only the final line may be torn: that is what a crash mid-append
            # leaves behind. A torn line in the middle means real corruption.
            if lineno == len(lines):
                torn_tail += 1
                continue
            fail(f"line {lineno}: not valid JSON (corruption before the tail)")
            problems += 1
            continue

        if not isinstance(event, dict):
            fail(f"line {lineno}: event is not an object")
            problems += 1
            continue

        errors = sorted(event_validator.iter_errors(event), key=lambda e: list(e.absolute_path))
        for err in errors:
            where = ".".join(str(p) for p in err.absolute_path) or "<root>"
            fail(f"line {lineno}: {where}: {err.message}")
            problems += 1
        events.append(event)

    tasks = replay(events)
    for tid, task in sorted(tasks.items()):
        errors = sorted(task_validator.iter_errors(task), key=lambda e: list(e.absolute_path))
        for err in errors:
            where = ".".join(str(p) for p in err.absolute_path) or "<root>"
            fail(f"task {tid}: {where}: {err.message}")
            problems += 1

    if problems:
        return 1

    suffix = f", {torn_tail} torn tail line ignored" if torn_tail else ""
    print(f"PASS: {len(events)} events, {len(tasks)} tasks{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
