#!/usr/bin/env bash
# Check that docs/spike-findings.md is actually finished.
#
# REQ-20261114-07 asks for one section per probe, the raw observation, then the
# decision. A document that keeps its placeholders is not that document, and a
# decision written before the probe ran is a guess. This refuses both.
#
# Usage: tools/check-findings.sh [path]
#   path defaults to docs/spike-findings.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
path="${1:-$ROOT/docs/spike-findings.md}"

if [[ ! -f "$path" ]]; then
  echo "FAIL: missing $path" >&2
  exit 1
fi

text="$(cat "$path")"
fail=0

# Every probe must have its own section.
for n in 1 2 3 4; do
  if ! grep -qE "^##+ .*Probe $n" <<<"$text"; then
    echo "FAIL: no section for Probe $n" >&2
    fail=1
  fi
done

# A placeholder means the section was never filled in.
placeholders='TODO|à remplir|a remplir|XXX|<\?|TBD'
if grep -qE "$placeholders" <<<"$text"; then
  echo "FAIL: placeholders left in the document:" >&2
  grep -nE "$placeholders" <<<"$text" | sed 's/^/  /' >&2
  fail=1
fi

# Each probe section needs an observation and a decision, each with real text.
check_field() {
  local probe="$1" field="$2" pattern="$3"
  local block
  block="$(awk -v p="Probe $probe" '
    $0 ~ "^##+ .*" p { inside=1; next }
    inside && /^##+ / { inside=0 }
    inside { print }
  ' "$path")"
  if ! grep -qiE "$pattern" <<<"$block"; then
    echo "FAIL: Probe $probe has no $field" >&2
    return 1
  fi
  # The field must be followed by something that is not blank.
  local value
  value="$(grep -iE "$pattern" <<<"$block" | head -1 | sed -E "s/.*($pattern)[^:]*:[[:space:]]*//I")"
  if [[ "${#value}" -lt 20 ]]; then
    echo "FAIL: Probe $probe $field is too short to be evidence (${#value} chars)" >&2
    return 1
  fi
  return 0
}

for n in 1 2 3 4; do
  check_field "$n" "observation" "observation" || fail=1
  check_field "$n" "decision" "decision" || fail=1
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "PASS: all four probes documented with an observation and a decision"
