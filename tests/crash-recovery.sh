#!/usr/bin/env bash
# T0 — crash recovery (REQ-20261114-18).
#
# The journal is appended before the projection is rewritten, so a kill in
# between leaves a projection that is behind. This reproduces exactly what a
# killed process leaves on disk — a torn tail, a stale projection, or both —
# then runs the recovery path through maki and checks what comes back.
#
# The "restart" is a real maki process: the test writes a request file, runs
# `maki index`, and reads the result the plugin wrote.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REQUEST="$ROOT/tests/recover-request.txt"
RESULT="$ROOT/tests/recover-result.txt"

recover() {
  local root="$1"
  rm -f "$RESULT"
  printf '%s\n' "$root" >"$REQUEST"
  maki --trust index "$ROOT/README.md" >/dev/null 2>&1 || true
  rm -f "$REQUEST"
  if [[ ! -f "$RESULT" ]]; then
    echo "FAIL: recovery produced no result for $root" >&2
    return 1
  fi
  cat "$RESULT"
}

journal() {
  cat >"$1" <<'JSONL'
{"kind":"task_created","task_id":"T-20261114-a3f2","task":{"id":"T-20261114-a3f2","title":"crash","status":"draft"}}
{"kind":"status","task_id":"T-20261114-a3f2","status":"qualifying"}
{"kind":"status","task_id":"T-20261114-a3f2","status":"ready"}
JSONL
}

# (1) A torn tail with no projection: the journal is the only truth.
mkdir -p "$TMP/torn"
journal "$TMP/torn/state.jsonl"
printf '{"kind":"status","task_id":"T-20261114-a3f2","sta' >>"$TMP/torn/state.jsonl"
out="$(recover "$TMP/torn")"
grep -q "events=3" <<<"$out" || { echo "FAIL[torn]: expected 3 events, got: $out" >&2; exit 1; }
grep -q "status=ready" <<<"$out" || { echo "FAIL[torn]: state lost: $out" >&2; exit 1; }
echo "ok[torn-tail]: $out"

# (2) A stale projection: the kill landed between append and projection write.
mkdir -p "$TMP/stale"
journal "$TMP/stale/state.jsonl"
cat >"$TMP/stale/state.json" <<'JSON'
{"events":1,"tasks":{"T-20261114-a3f2":{"id":"T-20261114-a3f2","title":"crash","status":"draft"}}}
JSON
out="$(recover "$TMP/stale")"
grep -q "events=3" <<<"$out" || { echo "FAIL[stale]: stale projection served, got: $out" >&2; exit 1; }
grep -q "status=ready" <<<"$out" || { echo "FAIL[stale]: lost the events behind the projection: $out" >&2; exit 1; }
echo "ok[stale-projection]: $out"

# (3) Both at once: torn tail and a stale projection.
mkdir -p "$TMP/both"
journal "$TMP/both/state.jsonl"
printf '{"kind":"status","task_id":"T-20261114-a3f2","sta' >>"$TMP/both/state.jsonl"
cp "$TMP/stale/state.json" "$TMP/both/state.json"
out="$(recover "$TMP/both")"
grep -q "events=3" <<<"$out" || { echo "FAIL[both]: expected 3 events, got: $out" >&2; exit 1; }
grep -q "status=ready" <<<"$out" || { echo "FAIL[both]: state lost: $out" >&2; exit 1; }
echo "ok[torn-and-stale]: $out"

# (4) A matching projection is still trusted, and yields the same state.
mkdir -p "$TMP/clean"
journal "$TMP/clean/state.jsonl"
cat >"$TMP/clean/state.json" <<'JSON'
{"events":3,"tasks":{"T-20261114-a3f2":{"id":"T-20261114-a3f2","title":"crash","status":"ready"}}}
JSON
out="$(recover "$TMP/clean")"
grep -q "events=3" <<<"$out" || { echo "FAIL[clean]: expected 3 events, got: $out" >&2; exit 1; }
grep -q "status=ready" <<<"$out" || { echo "FAIL[clean]: state wrong: $out" >&2; exit 1; }
echo "ok[matching-projection]: $out"

# (5) An empty root is not a crash: it recovers to nothing.
mkdir -p "$TMP/empty"
out="$(recover "$TMP/empty")"
grep -q "events=0" <<<"$out" || { echo "FAIL[empty]: expected 0 events, got: $out" >&2; exit 1; }
echo "ok[empty]: $out"

echo "PASS"
