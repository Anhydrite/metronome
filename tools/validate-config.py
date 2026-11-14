#!/usr/bin/env python3
"""Validate a Metronome config.toml against schemas/config.schema.json.

REQ-20261114-10/11: the config is the contract every pipeline run depends on,
so a typo or an unknown model must fail at load time with a message that names
the role, the spec, and what the machine can actually run.

This runs on the host (python3 + tomllib + jsonschema) rather than inside maki,
because the machine has no Lua runtime; it is the same contract the Lua loader
will enforce, pinned by tests either way.

Usage:
    tools/validate-config.py <config.toml> [schema.json] [--available FILE]

`--available FILE` is a newline-separated list of model specs, exactly what
`maki models` prints. With it, a role whose model is not in that list is an
error that names the role, the spec, and the closest alternatives.
"""

import difflib
import json
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    print("error: python3.11+ required (tomllib)", file=sys.stderr)
    sys.exit(2)

try:
    import jsonschema
except ModuleNotFoundError:
    print("error: jsonschema not installed", file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA = ROOT / "schemas" / "config.schema.json"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)


def load_available(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def suggest(spec: str, available: list[str], limit: int = 3) -> list[str]:
    """Closest specs by name, so a typo lands on the intended model."""
    close = difflib.get_close_matches(spec, available, n=limit, cutoff=0.4)
    if close:
        return close
    # Nothing close: fall back to the same provider, which is what a user
    # usually mistyped.
    provider = spec.split("/", 1)[0]
    same = [s for s in available if s.split("/", 1)[0] == provider]
    return same[:limit] or available[:limit]


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    available_path = None
    for i, a in enumerate(sys.argv[1:]):
        if a == "--available" and i + 2 <= len(sys.argv[1:]):
            available_path = Path(sys.argv[1:][i + 1])
            args = [x for x in args if x != str(available_path)]

    if not args:
        print(__doc__, file=sys.stderr)
        return 2

    config_path = Path(args[0])
    schema_path = Path(args[1]) if len(args) > 1 else DEFAULT_SCHEMA

    if not config_path.is_file():
        fail(f"missing config {config_path}")
        return 2
    if not schema_path.is_file():
        fail(f"missing schema {schema_path}")
        return 2

    try:
        config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        fail(f"{config_path} is not valid TOML: {exc}")
        return 1

    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    validator = jsonschema.Draft7Validator(schema)
    errors = sorted(validator.iter_errors(config), key=lambda e: list(e.absolute_path))

    if errors:
        for err in errors:
            where = ".".join(str(p) for p in err.absolute_path) or "<root>"
            # Name the role explicitly: "roles.implementer.model" is what a user
            # needs to see, not a JSON pointer.
            fail(f"{where}: {err.message}")
        return 1

    # Schema-valid, so every model spec is syntactically right. Now check it
    # against what this machine can actually run.
    if available_path is not None:
        try:
            available = load_available(available_path)
        except OSError as exc:
            fail(f"cannot read available-models list {available_path}: {exc}")
            return 2
        if not available:
            fail(f"{available_path} lists no models")
            return 2
        unknown = 0
        for role, spec in sorted(config.get("roles", {}).items()):
            model = spec.get("model")
            if model not in available:
                picks = ", ".join(suggest(model, available))
                fail(
                    f"roles.{role}.model: unknown model spec \"{model}\" "
                    f"(available: {picks})"
                )
                unknown += 1
        if unknown:
            return 1

    roles = ", ".join(sorted(config.get("roles", {})))
    print(f"PASS: {config_path} is valid (roles: {roles})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
