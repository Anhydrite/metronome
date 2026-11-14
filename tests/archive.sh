#!/usr/bin/env bash
# Tests for the OmO removal (REQ-20261114-45).
#
# The owner asked for the retired oh-my-openagent layer to be deleted outright,
# with no archive left behind. The active tree must contain only the maki
# plugin, and no live document may still point at the old layer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok[$*]"
}

# Nothing from the retired layer remains, and no archive was left behind.
for item in \
  "agents/chef.md" \
  "skills" \
  "templates/AGENT-TEMPLATE.md" \
  "templates/SKILL-TEMPLATE.md" \
  "scripts/bootstrap.sh" \
  "oh-my-openagent-rapport.md" \
  "schemas/agent.schema.json" \
  "schemas/skill.schema.json" \
  "docs/archive"; do
  [[ ! -e "$ROOT/$item" ]] || fail "still present: $item"
done
ok removed

# The live plugin is untouched.
for item in \
  "agents/metronome.md" \
  "scripts/install.sh" \
  "scripts/validate.sh" \
  "scripts/e2e.sh" \
  "scripts/e2e-shop.sh" \
  "scripts/e2e-tmux.sh" \
  "templates/config.toml" \
  "schemas/config.schema.json" \
  "schemas/task.schema.json" \
  "schemas/event.schema.json"; do
  [[ -e "$ROOT/$item" ]] || fail "live file removed: $item"
done
ok live

# scripts/ holds exactly the five live scripts.
count="$(find "$ROOT/scripts" -maxdepth 1 -type f | wc -l | tr -d ' ')"
[[ "$count" == "5" ]] || fail "scripts/ has $count files, expected 5"
ok scripts

# The active docs no longer point at the retired layer.
if grep -qiE "oh-my-openagent|chef-dorchestre|bootstrap\.sh" \
  "$ROOT/README.md" \
  "$ROOT/docs/architecture.md" \
  "$ROOT/docs/configuration.md" \
  "$ROOT/system-prompt.md" \
  "$ROOT/agents/metronome.md" 2>/dev/null; then
  fail "an active document still mentions the retired layer"
fi
ok references

echo "PASS"
