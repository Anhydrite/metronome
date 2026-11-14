#!/usr/bin/env bash
# Tests for scripts/install.sh (REQ-20261114-41).
#
# The installer copies the maki plugin tree and merges the two files a user may
# already own (init.lua, plugin.toml) without overwriting what is there. These
# cases run against throwaway targets, so no real ~/.config/maki is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok[$*]"
}

[[ -x "$INSTALL" ]] || fail "scripts/install.sh is missing or not executable"

# 1. Fresh install -----------------------------------------------------------

TARGET="$TMP/fresh"
MAKI_CONFIG_DIR="$TARGET" "$INSTALL" >/dev/null
[[ -f "$TARGET/lua/metronome/state.lua" ]] || fail "the lua tree was not copied"
[[ -f "$TARGET/lua/metronome/ui/panel.lua" ]] || fail "nested lua files were not copied"
[[ -f "$TARGET/init.lua" ]] || fail "init.lua was not created"
grep -q "metronome" "$TARGET/init.lua" || fail "init.lua does not load metronome"
grep -q "managed by scripts/install.sh" "$TARGET/init.lua" || fail "init.lua has no managed block"
[[ -f "$TARGET/plugin.toml" ]] || fail "plugin.toml was not created"
grep -q '^fs_read = true' "$TARGET/plugin.toml" || fail "plugin.toml is missing fs_read"
grep -q '^run = true' "$TARGET/plugin.toml" || fail "plugin.toml is missing run"
ok fresh

# 2. Existing init.lua is merged, not overwritten ----------------------------

TARGET="$TMP/merge-init"
mkdir -p "$TARGET"
printf -- '-- user code\nprint("hi")\n' > "$TARGET/init.lua"
MAKI_CONFIG_DIR="$TARGET" "$INSTALL" >/dev/null
grep -q 'user code' "$TARGET/init.lua" || fail "the user init.lua was overwritten"
grep -q 'print("hi")' "$TARGET/init.lua" || fail "the user init.lua lost a line"
grep -q 'managed by scripts/install.sh' "$TARGET/init.lua" || fail "the managed block was not added"

# A second run must replace the block, not append a second one.
MAKI_CONFIG_DIR="$TARGET" "$INSTALL" >/dev/null
count="$(grep -c 'managed by scripts/install.sh' "$TARGET/init.lua")"
[[ "$count" == "1" ]] || fail "the managed block was duplicated ($count)"
ok merge-init

# 3. Existing plugin.toml is merged, not overwritten -------------------------

TARGET="$TMP/merge-toml"
mkdir -p "$TARGET"
cat > "$TARGET/plugin.toml" <<'EOF'
[permissions]
fs_read = false
run = true

[custom]
foo = "bar"
EOF
MAKI_CONFIG_DIR="$TARGET" "$INSTALL" >/dev/null
grep -q '^fs_read = false' "$TARGET/plugin.toml" || fail "fs_read was overwritten"
grep -q '^run = true' "$TARGET/plugin.toml" || fail "run was lost"
grep -q '^fs_write = true' "$TARGET/plugin.toml" || fail "a missing permission was not added"
grep -q '^\[custom\]' "$TARGET/plugin.toml" || fail "the custom section was lost"
grep -q '^foo = "bar"' "$TARGET/plugin.toml" || fail "the custom key was lost"
ok merge-toml

# 4. A plugin.toml without a permissions section gets one --------------------

TARGET="$TMP/no-perm"
mkdir -p "$TARGET"
printf '[custom]\nfoo = "bar"\n' > "$TARGET/plugin.toml"
MAKI_CONFIG_DIR="$TARGET" "$INSTALL" >/dev/null
grep -q '^\[permissions\]' "$TARGET/plugin.toml" || fail "the permissions section was not added"
grep -q '^fs_read = true' "$TARGET/plugin.toml" || fail "the added permissions are empty"
grep -q '^\[custom\]' "$TARGET/plugin.toml" || fail "the custom section was lost"
ok no-perm

# 5. Dry run writes nothing --------------------------------------------------

TARGET="$TMP/dry"
MAKI_CONFIG_DIR="$TARGET" "$INSTALL" --dry-run >/dev/null
[[ ! -e "$TARGET/lua" ]] || fail "the dry run copied the lua tree"
[[ ! -e "$TARGET/init.lua" ]] || fail "the dry run wrote init.lua"
[[ ! -e "$TARGET/plugin.toml" ]] || fail "the dry run wrote plugin.toml"
ok dry-run

# 6. Help and bad usage ------------------------------------------------------

"$INSTALL" --help >/dev/null || fail "--help failed"
if "$INSTALL" --nonsense >/dev/null 2>&1; then
  fail "an unknown option was accepted"
fi
ok help

echo "PASS"
