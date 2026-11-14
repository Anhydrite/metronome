#!/usr/bin/env bash
# Tests for the e-commerce end-to-end scenario (REQ-20261114-47).
#
# The scenario is the test: it creates a throwaway shop repository, splits the
# intention into products/accounts/orders tasks, drives them through the real
# pipeline, retries a red check, merges, deploys, and validates the delivered
# server over HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/e2e-shop.sh"

[[ -x "$SCRIPT" ]] || {
  echo "FAIL: scripts/e2e-shop.sh is missing or not executable" >&2
  exit 1
}

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

if ! "$SCRIPT" >"$OUT" 2>&1; then
  echo "FAIL: the shop scenario failed:" >&2
  tail -40 "$OUT" >&2
  exit 1
fi

cat "$OUT"
grep -q '^PASS$' "$OUT" || {
  echo "FAIL: the shop scenario did not print PASS" >&2
  exit 1
}

echo "PASS"
