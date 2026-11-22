#!/usr/bin/env bash
# Tests for README, docs/architecture.md and docs/configuration.md
# (REQ-20261114-44).
#
# The docs are part of the product: they must describe the maki plugin that
# exists, not the retired oh-my-openagent layer, and every module and config
# section must be named.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
ARCH="$ROOT/docs/architecture.md"
CONFIG="$ROOT/docs/configuration.md"
PROMPT="$ROOT/system-prompt.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok[$*]"
}

need() {
  local file="$1" needle="$2" label="$3"
  grep -qF "$needle" "$file" || fail "$label: missing '$needle' in ${file#"$ROOT/"}"
}

# README ---------------------------------------------------------------------

[[ -f "$README" ]] || fail "README.md is missing"
[[ -s "$README" ]] || fail "README.md is empty"
head -1 "$README" | grep -q '^# Metronome$' || fail "README.md must start with '# Metronome'"
need "$README" "maki" "README"
need "$README" "scripts/install.sh" "README"
need "$README" "docs/architecture.md" "README"
need "$README" "docs/configuration.md" "README"
need "$README" "## Installation" "README"
need "$README" "## Commands" "README"
need "$README" "## Architecture" "README"
need "$README" "## Configuration" "README"
if grep -qi "oh-my-openagent" "$README"; then
  fail "README.md still describes the retired oh-my-openagent layer"
fi
if grep -qi "chef-dorchestre" "$README"; then
  fail "README.md still names the retired chef-dorchestre agent"
fi
# The mandatory init preflight is part of the contract: its five verification
# themes, its refusal semantics and its reach to /metronome config must be
# documented, or the change silently disappears.
for needle in "preflight" "git identity" "declared checks" "origin" \
  "jsonschema" "/metronome config"; do
  need "$README" "$needle" "readme preflight"
done
ok readme

# docs/architecture.md -------------------------------------------------------

[[ -f "$ARCH" ]] || fail "docs/architecture.md is missing"
[[ -s "$ARCH" ]] || fail "docs/architecture.md is empty"
head -1 "$ARCH" | grep -q '^# Architecture' || fail "docs/architecture.md must start with '# Architecture'"
for section in "## Modules" "## State" "## Pipeline" "## Scheduler" "## Security"; do
  need "$ARCH" "$section" "architecture"
done
need "$ARCH" "state.jsonl" "architecture"
need "$ARCH" "state.json" "architecture"

# Every module must be named, so the map cannot silently fall behind.
while IFS= read -r module; do
  name="$(basename "$module" .lua)"
  grep -qF "$name" "$ARCH" || fail "architecture does not name the module '$name'"
done < <(find "$ROOT/maki/lua/metronome" -type f -name '*.lua' | sort)
ok architecture

# docs/configuration.md ------------------------------------------------------

[[ -f "$CONFIG" ]] || fail "docs/configuration.md is missing"
[[ -s "$CONFIG" ]] || fail "docs/configuration.md is empty"
head -1 "$CONFIG" | grep -q '^# Configuration' || fail "docs/configuration.md must start with '# Configuration'"
for needle in "config.toml" "[project]" "[roles.qualifier]" "max_parallel" \
  "stall_minutes" "protected_paths" "auto_merge" "auto_deploy" "scripts/validate.sh"; do
  need "$CONFIG" "$needle" "configuration"
done

# Every top-level section of the shipped template must be documented.
while IFS= read -r section; do
  need "$CONFIG" "[$section]" "configuration"
done < <(grep -oE '^\[[a-z]+\]' "$ROOT/templates/config.toml" | tr -d '[]' | sort -u)

# The Preflight subsection must name the five verifications and the refusal
# contract, and state that /metronome config runs the same preflight.
for needle in "## Preflight" "preflight" "git identity" "declared checks" \
  "origin" "jsonschema" "/metronome config"; do
  need "$CONFIG" "$needle" "configuration preflight"
done
ok configuration

# system-prompt.md -------------------------------------------------------------

[[ -f "$PROMPT" ]] || fail "system-prompt.md is missing"
[[ -s "$PROMPT" ]] || fail "system-prompt.md is empty"
for needle in "preflight" "refused when the preflight fails" \
  "relay the reported check, command and remedy verbatim"; do
  need "$PROMPT" "$needle" "system-prompt"
done
ok system-prompt

echo "PASS"
