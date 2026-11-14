#!/usr/bin/env bash
# T0 — config contract test (REQ-20261114-10/11).
#
# A config is the contract every run depends on. This pins what must be
# accepted and what must be refused, with the role named in the message.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE="$ROOT/tools/validate-config.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$VALIDATE" ]]; then
  echo "FAIL: validator missing or not executable at $VALIDATE" >&2
  exit 1
fi

base() {
  cat <<'CFG'
[project]
repo = "/tmp/repo"
base_ref = "master"

[roles.qualifier]
model = "ocgo/deepseek-v4.1-flash"
thinking = "high"

[roles.analyst]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"

[roles.implementer]
model = "opencode-go/kimi-k3"
thinking = "max"

[roles.reviewer]
model = "ocgo/deepseek-v4-pro"
thinking = "high"

[roles.deployer]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"
CFG
}

accept() {
  local name="$1" file="$2"
  if ! "$VALIDATE" "$file" >/dev/null 2>&1; then
    echo "FAIL[$name]: valid config rejected:" >&2
    "$VALIDATE" "$file" >&2 || true
    return 1
  fi
  echo "ok[$name]: accepted"
}

reject() {
  local name="$1" file="$2" needle="$3"
  local out
  if out="$("$VALIDATE" "$file" 2>&1)"; then
    echo "FAIL[$name]: invalid config accepted" >&2
    return 1
  fi
  if [[ -n "$needle" ]] && ! grep -q "$needle" <<<"$out"; then
    echo "FAIL[$name]: error did not mention '$needle': $out" >&2
    return 1
  fi
  echo "ok[$name]: rejected"
}

# The shipped template must be valid.
accept template "$ROOT/templates/config.toml"

# A minimal valid config.
base >"$TMP/minimal.toml"
accept minimal "$TMP/minimal.toml"

# A role missing entirely: the pipeline would fail mid-run, so refuse at load.
base | grep -v '^\[roles.deployer\]' | sed '/^model = "ocgo\/deepseek-v4.1-flash"$/d; /^thinking = "medium"$/d' >"$TMP/no-deployer.toml"
reject missing-role "$TMP/no-deployer.toml" "deployer"

# An unknown model spec: must name the role, not just the field.
base | sed 's|model = "ocgo/deepseek-v4-pro"|model = "not a spec"|' >"$TMP/bad-model.toml"
reject bad-model "$TMP/bad-model.toml" "roles.reviewer.model"

# An unknown thinking level.
base | sed 's|thinking = "max"|thinking = "ultra"|' >"$TMP/bad-thinking.toml"
reject bad-thinking "$TMP/bad-thinking.toml" "roles.implementer.thinking"

# A typo'd key must not be silently ignored.
base | sed 's|^base_ref = "master"|base_ref = "master"\nbase_refs = "typo"|' >"$TMP/typo.toml"
reject unknown-key "$TMP/typo.toml" "project"

# A negative limit must be refused.
base | sed 's|^\[project\]|[project]\nmax_parallel = 0|' >"$TMP/bad-parallel.toml"
reject bad-parallel "$TMP/bad-parallel.toml" "max_parallel"

# Malformed TOML is a parse error, not a schema error.
printf '[project\nrepo = "/tmp"\n' >"$TMP/broken.toml"
reject broken-toml "$TMP/broken.toml" "not valid TOML"

echo "PASS"
