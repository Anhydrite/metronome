#!/usr/bin/env bash
# Copy the four spike decisions from docs/spike-findings.md into the plan.
#
# REQ-20261114-08 is the bridge between measurement and design: once a probe
# has a decision, the plan's risk table must say what was decided instead of
# what was feared. This writes a "Decisions du spike" block into the plan and
# replaces it on every run, so it is idempotent.
#
# It refuses to run while the findings document is unfinished: syncing a
# placeholder would put a guess into the plan, which is the one thing the
# spike exists to prevent.
#
# Usage: tools/sync-findings-to-plan.sh [findings] [plan]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
findings="${1:-$ROOT/docs/spike-findings.md}"
plan="${2:-$HOME/.local/state/maki/plans/quality-top-llama.md}"

for f in "$findings" "$plan"; do
  [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# Refuse placeholders: an unfinished document must not reach the plan.
if ! "$ROOT/tools/check-findings.sh" "$findings" >/dev/null 2>&1; then
  echo "FAIL: findings document is not finished; run the probes first" >&2
  "$ROOT/tools/check-findings.sh" "$findings" >&2 || true
  exit 1
fi

BEGIN_MARK="<!-- spike-decisions:begin -->"
END_MARK="<!-- spike-decisions:end -->"

block="$(
  printf '%s\n' "$BEGIN_MARK"
  printf '### Decisions du spike (Phase 0)\n\n'
  for n in 1 2 3 4; do
    decision="$(awk -v p="Probe $n" '
      $0 ~ "^##+ .*" p { inside=1; next }
      inside && /^##+ / { inside=0 }
      inside && tolower($0) ~ /^decision/ { sub(/^[Dd]ecision[[:space:]]*:[[:space:]]*/, ""); print; exit }
    ' "$findings")"
    printf -- '- **Probe %s** — %s\n' "$n" "$decision"
  done
  printf '\n%s\n' "$END_MARK"
)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Drop a previous block, then append the fresh one.
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { skip=1; next }
  index($0, e) { skip=0; next }
  !skip { print }
' "$plan" >"$tmp"

printf '\n%s\n' "$block" >>"$tmp"
mv "$tmp" "$plan"
trap - EXIT

echo "synced four decisions into $plan"
