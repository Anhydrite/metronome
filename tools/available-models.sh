#!/usr/bin/env bash
# Cache the model specs this machine can actually run.
#
# REQ-20261114-11 wants an unknown spec to fail with the alternatives listed,
# which means the validator needs the real list. `maki models` is the source;
# this caches it so a validation run does not shell out every time.
#
# Usage: tools/available-models.sh [--refresh]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${METRONOME_MODELS_CACHE:-$ROOT/.cache/models.txt}"

if [[ "${1:-}" == "--refresh" || ! -s "$CACHE" ]]; then
  mkdir -p "$(dirname "$CACHE")"
  if ! maki models >"$CACHE.tmp" 2>/dev/null; then
    rm -f "$CACHE.tmp"
    echo "FAIL: maki models failed" >&2
    exit 1
  fi
  mv "$CACHE.tmp" "$CACHE"
fi

cat "$CACHE"
