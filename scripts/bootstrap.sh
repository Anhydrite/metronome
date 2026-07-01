#!/usr/bin/env bash
# bootstrap.sh — One-shot installer for Metronome
#
# What it does:
#   1. Verifies oh-my-openagent is installed (installs it if not)
#   2. Deploys Metronome agents to ~/.config/opencode/agents/
#   3. Deploys Metronome skills to ~/.config/opencode/skills/
#   4. Validates the installation
#
# Usage:
#   ./scripts/bootstrap.sh              # Full bootstrap (installs OmO if missing)
#   ./scripts/bootstrap.sh --skip-omo   # Skip oh-my-openagent install check
#   ./scripts/bootstrap.sh --force      # Overwrite existing Metronome files
#   ./scripts/bootstrap.sh --uninstall  # Remove Metronome files
#
# Environment:
#   OPENCODE_GLOBAL_DIR   Where OmO looks for global config (default: ~/.config/opencode)
#   OMO_INSTALL_CMD       Command to install OmO (default: auto-detect bunx/npx)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_DIR="${OPENCODE_GLOBAL_DIR:-$HOME/.config/opencode}"
SKIP_OMO=false
FORCE=false
UNINSTALL=false

for arg in "$@"; do
  case "$arg" in
    --skip-omo) SKIP_OMO=true ;;
    --force|-f) FORCE=true ;;
    --uninstall) UNINSTALL=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-omo] [--force] [--uninstall]"
      echo ""
      echo "  --skip-omo     Skip oh-my-openagent install check"
      echo "  --force, -f    Overwrite existing Metronome files"
      echo "  --uninstall    Remove Metronome files from OmO"
      echo ""
      echo "Environment:"
      echo "  OPENCODE_GLOBAL_DIR   Where OmO looks for config (default: ~/.config/opencode)"
      exit 0
      ;;
  esac
done

# ─── Uninstall mode ────────────────────────────────────────────────────────
if [[ "$UNINSTALL" == "true" ]]; then
  echo "Uninstalling Metronome from $GLOBAL_DIR..."
  for f in "$GLOBAL_DIR/agents/chef-dorchestre.md"; do
    if [[ -f "$f" ]]; then
      rm "$f" && echo "  ✓  removed  $f"
    fi
  done
  for d in "$GLOBAL_DIR/skills/metronome-validator" "$GLOBAL_DIR/skills/create-agent"; do
    if [[ -d "$d" ]]; then
      rm -rf "$d" && echo "  ✓  removed  $d"
    fi
  done
  echo "Done. Metronome files removed. oh-my-openagent remains installed."
  exit 0
fi

# ─── Step 1: Check / install oh-my-openagent ──────────────────────────────
if [[ "$SKIP_OMO" == "true" ]]; then
  echo "→ Skipping oh-my-openagent check (--skip-omo)"
  echo ""
else
  echo "→ Checking oh-my-openagent installation"
  OMO_INSTALLED=false
  OMO_CONFIG="$GLOBAL_DIR/opencode.json"
  if [[ -f "$OMO_CONFIG" ]] && grep -q "oh-my-opencode\|oh-my-openagent" "$OMO_CONFIG" 2>/dev/null; then
    OMO_INSTALLED=true
    echo "  ✓  oh-my-openagent is registered in $OMO_CONFIG"
  else
    echo "  ⚠  oh-my-openagent is not installed"
    echo ""
    echo "  Metronome requires oh-my-openagent. Installing now..."
    echo ""

    if command -v bunx >/dev/null 2>&1; then
      INSTALL_CMD=(bunx oh-my-opencode@latest install)
      echo "  Using bunx to install..."
    elif command -v npx >/dev/null 2>&1; then
      INSTALL_CMD=(npx oh-my-opencode@latest install)
      echo "  Using npx to install..."
    else
      echo "  ✗  Neither bunx nor npx found. Please install Bun or Node.js first." >&2
      echo "     Bun: https://bun.sh"
      echo "     Node: https://nodejs.org"
      exit 1
    fi

    if "${INSTALL_CMD[@]}"; then
      echo "  ✓  oh-my-openagent installed"
      OMO_INSTALLED=true
    else
      echo "  ✗  Failed to install oh-my-openagent" >&2
      echo "  Run manually: ${INSTALL_CMD[*]}" >&2
      exit 1
    fi
  fi
  echo ""
fi

# ─── Step 2: Deploy Metronome agents ───────────────────────────────────────
echo "→ Deploying agents to $GLOBAL_DIR/agents/"
mkdir -p "$GLOBAL_DIR/agents"
for f in "$REPO_ROOT/agents"/*.md; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f" .md)
  dest="$GLOBAL_DIR/agents/$name.md"
  if [[ -f "$dest" && "$FORCE" != "true" ]]; then
    echo "  ⊘  skip   $name (exists, use --force to overwrite)"
  else
    cp "$f" "$dest" && echo "  ✓  install  $name → $dest"
  fi
done
echo ""

# ─── Step 3: Deploy Metronome skills ───────────────────────────────────────
echo "→ Deploying skills to $GLOBAL_DIR/skills/"
mkdir -p "$GLOBAL_DIR/skills"
for d in "$REPO_ROOT/skills"/*/; do
  [[ -d "$d" ]] || continue
  name=$(basename "$d")
  dest="$GLOBAL_DIR/skills/$name"
  if [[ -d "$dest" && "$FORCE" != "true" ]]; then
    echo "  ⊘  skip   $name (exists, use --force to overwrite)"
  else
    rm -rf "$dest"
    cp -r "$d" "$dest" && echo "  ✓  install  $name → $dest"
  fi
done
echo ""

# ─── Step 4: Validate ──────────────────────────────────────────────────────
echo "→ Validating installation"
VALIDATE="$REPO_ROOT/scripts/validate.sh"
if [[ -x "$VALIDATE" ]]; then
  "$VALIDATE"
else
  echo "  ⚠  validate.sh not found or not executable"
fi

echo ""
echo "─────────────────────"
echo "✓ Bootstrap complete"
echo ""
echo "Next steps:"
echo "  1. Restart oh-my-openagent to pick up new agents and skills"
echo "  2. Switch to the 'chef-dorchestre' agent from the UI"
  echo "  3. Use the 'create-agent' skill to add your own, or OmO's built-in 'writing-skills' for skills"