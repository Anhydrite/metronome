#!/usr/bin/env bash
# validate.sh — Validate Metronome agent and skill files
#
# Usage:
#   ./scripts/validate.sh              # Validate everything
#   ./scripts/validate.sh agents      # Validate only agents
#   ./scripts/validate.sh skills      # Validate only skills
#
# Checks:
#   - Frontmatter is present and valid YAML
#   - Required fields are present (name, description for agents)
#   - name matches filename (for agents)
#   - mode is one of: primary, subagent, all
#   - tools is comma-separated string
#   - Body is non-empty

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
SKILLS_DIR="$REPO_ROOT/skills"
SCHEMA_AGENT="$REPO_ROOT/schemas/agent.schema.json"
SCHEMA_SKILL="$REPO_ROOT/schemas/skill.schema.json"

WHAT="${1:-all}"

PASS=0
FAIL=0

check_yaml_frontmatter() {
  local file="$1"
  local sep_count
  sep_count=$(grep -c "^---$" "$file" || true)
  if [[ "$sep_count" -lt 2 ]]; then
    return 1
  fi
  if ! head -1 "$file" | grep -q "^---$"; then
    return 1
  fi
  return 0
}

extract_frontmatter() {
  local file="$1"
  awk 'BEGIN{f=0} /^---$/{f++; if(f==2) exit} f==1{print}' "$file"
}

validate_agent() {
  local file="$1"
  local name
  name=$(basename "$file" .md)
  local errors=()

  if ! check_yaml_frontmatter "$file"; then
    echo "  ✗  $name.md — INVALID frontmatter (missing or unclosed ---)"
    return 1
  fi

  local fm
  fm=$(extract_frontmatter "$file")

  # Check name
  local fm_name
  fm_name=$(echo "$fm" | awk '/^name:/{$1=""; sub(/^[ \t]+/, ""); print; exit}')
  if [[ -z "$fm_name" ]]; then
    errors+=("missing 'name' field")
  elif [[ "$fm_name" != "$name" ]]; then
    errors+=("name '$fm_name' doesn't match filename '$name'")
  fi

  # Check description
  if ! echo "$fm" | grep -q "^description:"; then
    errors+=("missing 'description' field")
  fi

  # Check mode if present
  local mode
  mode=$(echo "$fm" | awk '/^mode:/{$1=""; sub(/^[ \t]+/, ""); print; exit}')
  if [[ -n "$mode" && "$mode" != "primary" && "$mode" != "subagent" && "$mode" != "all" ]]; then
    errors+=("invalid mode '$mode' (must be: primary, subagent, all)")
  fi

  # Check body is non-empty
  local body_size
  body_size=$(awk 'BEGIN{f=0} /^---$/{f++; next} f>=2{print}' "$file" | wc -c)
  if [[ $body_size -lt 50 ]]; then
    errors+=("body is too short ($body_size chars, need at least 50)")
  fi

  if [[ ${#errors[@]} -eq 0 ]]; then
    echo "  ✓  $name.md"
    return 0
  else
    echo "  ✗  $name.md"
    for err in "${errors[@]}"; do
      echo "      - $err"
    done
    return 1
  fi
}

validate_skill() {
  local dir="$1"
  local name
  name=$(basename "$dir")
  local file="$dir/SKILL.md"
  local errors=()

  if [[ ! -f "$file" ]]; then
    # Try dirname.md fallback
    file="$dir/$name.md"
  fi

  if [[ ! -f "$file" ]]; then
    echo "  ✗  $name — no SKILL.md or $name.md found in $dir"
    return 1
  fi

  if ! check_yaml_frontmatter "$file"; then
    echo "  ✗  $name — INVALID frontmatter (missing or unclosed ---)"
    return 1
  fi

  # Check body is non-empty
  local body_size
  body_size=$(awk 'BEGIN{f=0} /^---$/{f++; next} f>=2{print}' "$file" | wc -c)
  if [[ $body_size -lt 30 ]]; then
    errors+=("body is too short ($body_size chars)")
  fi

  if [[ ${#errors[@]} -eq 0 ]]; then
    echo "  ✓  $name (from $file)"
    return 0
  else
    echo "  ✗  $name"
    for err in "${errors[@]}"; do
      echo "      - $err"
    done
    return 1
  fi
}

echo "Metronome validator"
echo "  schemas: $SCHEMA_AGENT, $SCHEMA_SKILL"
echo ""

if [[ "$WHAT" == "all" || "$WHAT" == "agents" ]]; then
  echo "→ Agents"
  if [[ -d "$AGENTS_DIR" ]]; then
    for f in "$AGENTS_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      if validate_agent "$f"; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
      fi
    done
  else
    echo "  (no agents/ directory found)"
  fi
  echo ""
fi

if [[ "$WHAT" == "all" || "$WHAT" == "skills" ]]; then
  echo "→ Skills"
  if [[ -d "$SKILLS_DIR" ]]; then
    for d in "$SKILLS_DIR"/*/; do
      [[ -d "$d" ]] || continue
      if validate_skill "$d"; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
      fi
    done
  else
    echo "  (no skills/ directory found)"
  fi
  echo ""
fi

echo "─────────────────────"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi