#!/usr/bin/env bash
# Parse a Metronome Phase 0 thinking probe log.
#
# The probe (REQ-20261114-03) is only proven when findings.log carries the
# parent's thinking ceiling AND the level the subagent asked for. This reads
# that log and prints the verdict the test asserts on.
#
# Usage: tools/spike-thinking.sh <findings.log>
set -euo pipefail

path="${1:-}"
if [[ -z "$path" || ! -f "$path" ]]; then
  echo "usage: spike-thinking.sh <findings.log>" >&2
  exit 2
fi

parent_thinking=""
requested_model=""
requested_thinking=""

while IFS= read -r line; do
  if [[ "$line" =~ parent\ model=([^ ]+)\ thinking=([^ ]+) ]]; then
    [[ "${BASH_REMATCH[2]}" != "nil" ]] && parent_thinking="${BASH_REMATCH[2]}"
  fi
  if [[ "$line" =~ requested\ model=([^ ]+)\ thinking=([^ ]+) ]]; then
    requested_model="${BASH_REMATCH[1]}"
    [[ "${BASH_REMATCH[2]}" != "nil" ]] && requested_thinking="${BASH_REMATCH[2]}"
  fi
done <"$path"

rank() {
  case "$1" in
    off) echo 0 ;;
    minimal) echo 1 ;;
    low) echo 2 ;;
    medium|adaptive) echo 3 ;;
    high) echo 4 ;;
    xhigh) echo 5 ;;
    max) echo 6 ;;
    *) echo "" ;;
  esac
}

verdict="honoured"
if [[ -z "$parent_thinking" || -z "$requested_thinking" ]]; then
  verdict="incomplete"
else
  pr="$(rank "$parent_thinking")"
  rr="$(rank "$requested_thinking")"
  if [[ -n "$pr" && -n "$rr" && "$rr" -gt "$pr" ]]; then
    verdict="capped"
  fi
fi

echo "parent_thinking=${parent_thinking:-unknown} requested_model=${requested_model:-unknown} requested_thinking=${requested_thinking:-unknown} verdict=${verdict}"
[[ "$verdict" == "incomplete" ]] && exit 1
exit 0
