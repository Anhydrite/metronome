#!/usr/bin/env bash
# T0 — parser test for the Phase 0 write/permissions probe.
#
# REQ-20261114-05 is only proven when the file on disk actually holds the
# probe text. A model saying WRITE=<ok> is not proof; the log records what the
# file held afterwards, and that is what tools/spike-write.sh judges.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER="$ROOT/tools/spike-write.sh"
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

# Background write succeeded: the file holds the marker.
cat >"$TMP/wrote.log" <<'LOG'
[10:00:01] write-bg: mode=background
[10:00:01] write-bg: session_id=abc
[10:00:01] write-bg: target=/tmp/probe-bg.txt
[10:00:01] write-bg: error=nil
[10:00:01] write-bg: reply=WRITE=<ok>
[10:00:01] write-bg: file after run: metronome-probe-bg
LOG

# The model claimed success but the file is empty: a blocked write, and the
# exact failure mode this probe exists to catch.
cat >"$TMP/blocked.log" <<'LOG'
[10:00:01] write-bg: mode=background
[10:00:01] write-bg: error=nil
[10:00:01] write-bg: reply=WRITE=<ok>
[10:00:01] write-bg: file after run: nil
LOG

# No file line at all: nothing can be concluded.
cat >"$TMP/incomplete.log" <<'LOG'
[10:00:01] write-bg: mode=background
[10:00:01] write-bg: open failed: session not live
LOG

expect wrote wrote "$TMP/wrote.log"
expect blocked blocked "$TMP/blocked.log"
expect incomplete incomplete "$TMP/incomplete.log"

# The mode must be reported, since REQ-05 is specifically about background.
out="$("$PARSER" "$TMP/wrote.log")"
grep -q "mode=background" <<<"$out" || { echo "FAIL: mode not reported" >&2; exit 1; }

echo "PASS"
