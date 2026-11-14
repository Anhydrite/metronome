#!/usr/bin/env bash
# T0 — parser test for the Phase 0 thinking probe.
#
# REQ-20261114-03 is only proven when findings.log carries BOTH the parent's
# thinking ceiling and the level the subagent asked for. tools/spike-thinking.sh
# turns that log into a verdict; these fixtures pin the three outcomes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER="$ROOT/tools/spike-thinking.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$PARSER" ]]; then
  echo "FAIL: parser missing or not executable at $PARSER" >&2
  exit 1
fi

expect() {
  local name="$1" want="$2" log="$3"
  local out
  out="$("$PARSER" "$log" 2>&1 || true)"
  if ! grep -q "verdict=$want" <<<"$out"; then
    echo "FAIL[$name]: want verdict=$want, got: $out" >&2
    return 1
  fi
  echo "ok[$name]: $out"
}

# Requested at or below the parent ceiling: honoured verbatim.
cat >"$TMP/honoured.log" <<'LOG'
[10:00:01] thinking: parent model=ocgo/deepseek-v4.1-flash thinking=max shown=max
[10:00:01] thinking: requested model=ocgo/deepseek-v4-pro thinking=high
[10:00:01] thinking: reply: PONG
LOG

# Requested above the parent ceiling: the cap is what we are measuring.
cat >"$TMP/capped.log" <<'LOG'
[10:00:01] thinking: parent model=ocgo/deepseek-v4.1-flash thinking=high shown=high
[10:00:01] thinking: requested model=ocgo/deepseek-v4-pro thinking=max
[10:00:01] thinking: reply: PONG
LOG

# No parent line at all: nothing can be concluded.
cat >"$TMP/incomplete.log" <<'LOG'
[10:00:01] thinking: requested model=ocgo/deepseek-v4-pro thinking=max
LOG

expect honoured honoured "$TMP/honoured.log"
expect capped capped "$TMP/capped.log"
expect incomplete incomplete "$TMP/incomplete.log"

echo "PASS"
