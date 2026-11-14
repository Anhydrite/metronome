#!/usr/bin/env bash
# T0 — parser test for the Phase 0 reload probe.
#
# REQ-20261114-06 asks what survives a /reload, what dies, and what must be
# resumed. tools/spike-reload.sh pairs RUN_START with RUN_FINISH/SESSION_END
# and reports a verdict. These fixtures pin the three outcomes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER="$ROOT/tools/spike-reload.sh"
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
  echo "ok[$name]: $(grep '^verdict=' <<<"$out")"
}

# The run outlived the reload: started before, finished after.
cat >"$TMP/survived.log" <<'LOG'
[10:00:00] boot: BOOT spike loaded
[10:00:01] reload: RUN_START id=run-1 session=abc
[10:00:02] reload: RUN_OPEN id=run-1 task=t1
[10:00:09] boot: BOOT spike loaded
[10:00:20] reload: RUN_FINISH id=run-1 err=nil text=done
LOG

# The reload killed the run: a session end with reason=reload, no finish.
cat >"$TMP/died.log" <<'LOG'
[10:00:00] boot: BOOT spike loaded
[10:00:01] reload: RUN_START id=run-2 session=abc
[10:00:02] reload: RUN_OPEN id=run-2 task=t2
[10:00:05] session_end: SESSION_END reason=reload
[10:00:06] boot: BOOT spike loaded
LOG

# No second boot: no reload happened, so nothing can be concluded.
cat >"$TMP/noreload.log" <<'LOG'
[10:00:00] boot: BOOT spike loaded
[10:00:01] reload: RUN_START id=run-3 session=abc
[10:00:20] reload: RUN_FINISH id=run-3 err=nil text=done
LOG

expect survived reload-preserves-runs "$TMP/survived.log"
expect died reload-kills-runs "$TMP/died.log"
expect noreload no-reload-observed "$TMP/noreload.log"

# Per-run detail must be reported, not just the global verdict.
out="$("$PARSER" "$TMP/died.log" 2>&1 || true)"
grep -q "run=run-2 verdict=died reason=reload" <<<"$out" || { echo "FAIL: per-run detail missing" >&2; exit 1; }

echo "PASS"
