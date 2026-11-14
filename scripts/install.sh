#!/usr/bin/env bash
# install.sh — Install the Metronome maki plugin.
#
# Usage:
#   ./scripts/install.sh [--dry-run] [--force] [--help]
#
# Target:
#   $MAKI_CONFIG_DIR, else $XDG_CONFIG_HOME/maki, else ~/.config/maki.
#
# What it does:
#   - copies maki/lua/ into <target>/lua/, updating the plugin modules;
#   - merges maki/init.lua into <target>/init.lua inside a managed block,
#     preserving any code the user already has;
#   - merges the permissions of maki/plugin.toml into <target>/plugin.toml,
#     preserving existing keys, values and sections. A key the user already
#     set is never overwritten; a key set to false is left alone with a warning.
#
# --force replaces init.lua and plugin.toml instead of merging them. The lua
# modules are always updated, because they are the plugin itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/maki"
TARGET="${MAKI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/maki}"
BEGIN_MARK="-- >>> metronome (managed by scripts/install.sh) >>>"
END_MARK="-- <<< metronome <<<"

DRY_RUN=false
FORCE=false

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--force] [--help]

  --dry-run   Print what would change; write nothing.
  --force     Replace init.lua and plugin.toml instead of merging them.
  --help      Show this help.

Environment:
  MAKI_CONFIG_DIR   Target directory (default: \$XDG_CONFIG_HOME/maki or ~/.config/maki)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force|-f) FORCE=true ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "error: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  echo "  $*"
}

# Merge the source init.lua into the destination inside a managed block. The
# block is replaced on a rerun, never duplicated, and code outside it is kept.
merge_init() {
  local src="$1" dest="$2"

  if [[ "$FORCE" == true || ! -f "$dest" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "would write $dest"
      return
    fi
    mkdir -p "$(dirname "$dest")"
    {
      echo "$BEGIN_MARK"
      cat "$src"
      echo "$END_MARK"
    } > "$dest"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "would merge $src into $dest"
    return
  fi

  local tmp="$dest.metronome.$$"
  local in_block=false
  local found=false
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$BEGIN_MARK" ]]; then
      found=true
      in_block=true
      {
        echo "$BEGIN_MARK"
        cat "$src"
        echo "$END_MARK"
      } >> "$tmp"
      continue
    fi
    if [[ "$in_block" == true ]]; then
      if [[ "$line" == "$END_MARK" ]]; then
        in_block=false
      fi
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$dest"

  if [[ "$found" == false ]]; then
    {
      echo ""
      echo "$BEGIN_MARK"
      cat "$src"
      echo "$END_MARK"
    } >> "$tmp"
  fi
  mv "$tmp" "$dest"
}

# Merge the source permissions into the destination TOML. Existing keys are
# preserved, including explicit false values; missing keys are inserted at the
# end of the [permissions] section, or in a new section when there is none.
merge_toml() {
  local src="$1" dest="$2"

  if [[ "$FORCE" == true || ! -f "$dest" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "would write $dest"
      return
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "would merge permissions into $dest"
    return
  fi

  local keys=()
  local in_perm=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[([^]]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "permissions" ]]; then
        in_perm=true
      else
        in_perm=false
      fi
      continue
    fi
    if [[ "$in_perm" == true && "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*true[[:space:]]*$ ]]; then
      keys+=("${BASH_REMATCH[1]}")
    fi
  done < "$src"

  local missing=()
  local key
  for key in "${keys[@]}"; do
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$dest"; then
      if grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*false" "$dest"; then
        echo "  ! $key is false in $dest; leaving it untouched" >&2
      fi
    else
      missing+=("$key")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  if grep -qE '^\[permissions\]' "$dest"; then
    local tmp="$dest.metronome.$$"
    local inserted=false
    in_perm=false
    : > "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^\[([^]]+)\] ]]; then
        if [[ "$in_perm" == true && "$inserted" == false ]]; then
          for key in "${missing[@]}"; do
            echo "$key = true" >> "$tmp"
          done
          inserted=true
        fi
        if [[ "${BASH_REMATCH[1]}" == "permissions" ]]; then
          in_perm=true
        else
          in_perm=false
        fi
        printf '%s\n' "$line" >> "$tmp"
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$dest"
    if [[ "$in_perm" == true && "$inserted" == false ]]; then
      for key in "${missing[@]}"; do
        echo "$key = true" >> "$tmp"
      done
    fi
    mv "$tmp" "$dest"
  else
    {
      echo ""
      echo "[permissions]"
      for key in "${missing[@]}"; do
        echo "$key = true"
      done
    } >> "$dest"
  fi
}

# Validate the payload before touching anything.
[[ -d "$SRC/lua/metronome" ]] || {
  echo "error: missing $SRC/lua/metronome" >&2
  exit 1
}
[[ -f "$SRC/init.lua" ]] || {
  echo "error: missing $SRC/init.lua" >&2
  exit 1
}
[[ -f "$SRC/plugin.toml" ]] || {
  echo "error: missing $SRC/plugin.toml" >&2
  exit 1
}

echo "Metronome installer"
echo "  source: $SRC"
echo "  target: $TARGET"
if [[ "$DRY_RUN" == true ]]; then
  echo "  mode:   dry run"
fi
echo ""

if [[ "$DRY_RUN" == true ]]; then
  log "would copy $SRC/lua/ -> $TARGET/lua/"
else
  mkdir -p "$TARGET/lua"
  cp -R "$SRC/lua/." "$TARGET/lua/"
  log "copied lua modules -> $TARGET/lua/"
fi

merge_init "$SRC/init.lua" "$TARGET/init.lua"
merge_toml "$SRC/plugin.toml" "$TARGET/plugin.toml"

echo ""
echo "Done. Run /reload in maki to load the plugin."
