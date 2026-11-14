#!/usr/bin/env bash
# T0 — unknown-model detection (REQ-20261114-11).
#
# A spec that is syntactically valid but not installed must fail, and the
# message must name the role, the spec, and a usable alternative.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE="$ROOT/tools/validate-config.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$VALIDATE" ]]; then
  echo "FAIL: validator missing or not executable at $VALIDATE" >&2
  exit 1
fi

cat >"$TMP/available.txt" <<'MODELS'
ocgo/deepseek-v4.1-flash
ocgo/deepseek-v4-pro
opencode-go/kimi-k3
opencode-go/kimi-k3.1-pro
MODELS

cat >"$TMP/good.toml" <<'CFG'
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

# A near-miss typo: the suggestion must land on the intended model.
sed 's|model = "opencode-go/kimi-k3"|model = "opencode-go/kimi-k4"|' "$TMP/good.toml" >"$TMP/typo.toml"

# A spec that exists nowhere and has no same-provider sibling.
sed 's|model = "ocgo/deepseek-v4-pro"|model = "ghost/nowhere"|' "$TMP/good.toml" >"$TMP/ghost.toml"

# (a) every model installed: accepted.
if ! "$VALIDATE" "$TMP/good.toml" --available "$TMP/available.txt" >/dev/null 2>&1; then
  echo "FAIL: valid config rejected with a full model list" >&2
  "$VALIDATE" "$TMP/good.toml" --available "$TMP/available.txt" >&2 || true
  exit 1
fi
echo "ok[all-installed]: accepted"

# (b) a typo must be refused, naming the role, the spec and a suggestion.
out="$("$VALIDATE" "$TMP/typo.toml" --available "$TMP/available.txt" 2>&1 || true)"
grep -q "roles.implementer.model" <<<"$out" || { echo "FAIL: role not named: $out" >&2; exit 1; }
grep -q "kimi-k4" <<<"$out" || { echo "FAIL: offending spec not named: $out" >&2; exit 1; }
grep -q "kimi-k3" <<<"$out" || { echo "FAIL: no usable suggestion: $out" >&2; exit 1; }
echo "ok[typo]: refused with role, spec and suggestion"

# (c) an unknown provider must still produce a suggestion from the list.
out="$("$VALIDATE" "$TMP/ghost.toml" --available "$TMP/available.txt" 2>&1 || true)"
grep -q "roles.reviewer.model" <<<"$out" || { echo "FAIL: role not named: $out" >&2; exit 1; }
grep -q "ghost/nowhere" <<<"$out" || { echo "FAIL: offending spec not named: $out" >&2; exit 1; }
grep -q "available:" <<<"$out" || { echo "FAIL: no alternatives offered: $out" >&2; exit 1; }
echo "ok[ghost]: refused with role, spec and alternatives"

# (d) an empty model list is a setup error, not a silent pass.
: >"$TMP/empty.txt"
if "$VALIDATE" "$TMP/good.toml" --available "$TMP/empty.txt" >/dev/null 2>&1; then
  echo "FAIL: empty model list accepted" >&2
  exit 1
fi
echo "ok[empty-list]: refused"

# (e) without --available, a syntactically valid spec is still accepted.
if ! "$VALIDATE" "$TMP/typo.toml" >/dev/null 2>&1; then
  echo "FAIL: schema-only validation rejected a syntactically valid spec" >&2
  exit 1
fi
echo "ok[schema-only]: accepted"

echo "PASS"
