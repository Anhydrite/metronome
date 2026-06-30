#!/usr/bin/env bash
# install.sh — Install Metronome agents and skills into oh-my-openagent
#
# Usage:
#   ./scripts/install.sh              # Install everything (agents + skills)
#   ./scripts/install.sh agents      # Install only agents
#   ./scripts/install.sh skills      # Install only skills
#   ./scripts/install.sh agents my-agent  # Install a specific agent
#   ./scripts/install.sh skills my-skill  # Install a specific skill
#
# What it does:
#   - Copies agents/*.md to ~/.config/opencode/agents/ (or $OPENCODE_GLOBAL_DIR)
#   - Copies skills/<name>/ to ~/.config/opencode/skills/ (or $OPENCODE_GLOBAL_DIR)
#   - Skips files that already exist (use --force to overwrite)

set -euo pipefail

# Configurable: where oh-my-openagent looks for global agents/skills
GLOBAL_DIR="${OPENCODE_GLOBAL_DIR:-$HOME/.config/opencode}"
AGENTS_SRC="$(cd "$(dirname "$0")/.." && pwd)/agents"
SKILLS_SRC="$(cd "$(dirname "$0")/.." && pwd)/skills"

FORCE=false
WHAT="all"
SPECIFIC=""

# Parse args
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    --help|-h)
      echo "Usage: $0 [agents|skills] [name] [--force]"
      echo ""
      echo "  agents           Install only agents (default: all)"
      echo "  skills           Install only skills (default: all)"
      echo "  name             Install a specific agent or skill by name"
      echo "  --force, -f      Overwrite existing files"
      echo ""
      echo "Environment:"
      echo "  OPENCODE_GLOBAL_DIR   Where to install (default: ~/.config/opencode)"
      exit 0
      ;;
    agents|skills|all)
      WHAT="$arg"
      ;;
    *)
      SPECIFIC="$arg"
      ;;
  esac
done

# Ensure target dirs exist
mkdir -p "$GLOBAL_DIR/agents" "$GLOBAL_DIR/skills"

install_agent() {
  local src="$1"
  local name
  name=$(basename "$src" .md)
  local dest="$GLOBAL_DIR/agents/$name.md"

  if [[ -f "$dest" && "$FORCE" != "true" ]]; then
    echo "  ⊘  skip  $name (already exists, use --force to overwrite)"
    return
  fi

  cp "$src" "$dest"
  echo "  ✓  install  $name → $dest"
}

install_skill() {
  local src="$1"
  local name
  name=$(basename "$src")
  local dest="$GLOBAL_DIR/skills/$name"

  if [[ -d "$dest" && "$FORCE" != "true" ]]; then
    echo "  ⊘  skip  $name (already exists, use --force to overwrite)"
    return
  fi

  rm -rf "$dest"
  cp -r "$src" "$dest"
  echo "  ✓  install  $name → $dest"
}

echo "Metronome installer"
echo "  source: $(cd "$(dirname "$0")/.." && pwd)"
echo "  target: $GLOBAL_DIR"
echo ""

# Install agents
if [[ "$WHAT" == "all" || "$WHAT" == "agents" ]]; then
  echo "→ Agents"
  if [[ -n "$SPECIFIC" ]]; then
    src="$AGENTS_SRC/$SPECIFIC.md"
    if [[ ! -f "$src" ]]; then
      echo "  ✗  error  agent not found: $src" >&2
      exit 1
    fi
    install_agent "$src"
  else
    if [[ -d "$AGENTS_SRC" ]]; then
      for f in "$AGENTS_SRC"/*.md; do
        [[ -f "$f" ]] || continue
        install_agent "$f"
      done
    fi
  fi
  echo ""
fi

# Install skills
if [[ "$WHAT" == "all" || "$WHAT" == "skills" ]]; then
  echo "→ Skills"
  if [[ -n "$SPECIFIC" ]]; then
    src="$SKILLS_SRC/$SPECIFIC"
    if [[ ! -d "$src" ]]; then
      echo "  ✗  error  skill not found: $src" >&2
      exit 1
    fi
    install_skill "$src"
  else
    if [[ -d "$SKILLS_SRC" ]]; then
      for d in "$SKILLS_SRC"/*/; do
        [[ -d "$d" ]] || continue
        install_skill "$d"
      done
    fi
  fi
  echo ""
fi

echo "Done. Restart oh-my-openagent to pick up changes."