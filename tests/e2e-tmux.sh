#!/usr/bin/env bash
# Run the realistic tmux + GitHub end-to-end scenario.
#
# This is the shell test around scripts/e2e-tmux.sh: the script is the judge,
# and its PASS line is the proof. Options are forwarded, so a run can point at
# another repository or keep the temporary directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/e2e-tmux.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: missing $SCRIPT" >&2
  exit 1
fi

exec "$SCRIPT" "$@"
