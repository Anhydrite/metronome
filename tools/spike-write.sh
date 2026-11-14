#!/usr/bin/env bash
# Parse a Metronome Phase 0 write/permissions probe log.
#
# REQ-20261114-05 asks whether a BACKGROUND subagent can write into the
# worktree with the declared permission rules, without a prompt blocking it.
# The probe logs the mode, the reply marker, and what the file actually holds
# afterwards; the file is the proof, not the model's claim.
#
# Usage: tools/spike-write.sh <findings.log>
set -euo pipefail

path="${1:-}"
if [[ -z "$path" || ! -f "$path" ]]; then
  echo "usage: spike-write.sh <findings.log>" >&2
  exit 2
fi

mode=""
marker=""
file_content=""
had_error=""

while IFS= read -r line; do
  [[ "$line" =~ mode=(background|foreground) ]] && mode="${BASH_REMATCH[1]}"
  [[ "$line" =~ WRITE=\<ok\>|WRITE=ok ]] && marker="ok"
  [[ "$line" =~ WRITE=\<fail\>|WRITE=fail ]] && marker="fail"
  [[ "$line" =~ file\ after\ run:\ (.*)$ ]] && file_content="${BASH_REMATCH[1]}"
  [[ "$line" =~ error=(.+) ]] && [[ "${BASH_REMATCH[1]}" != "nil" ]] && had_error="${BASH_REMATCH[1]}"
done <"$path"

# The file on disk is the only proof that survives a lying model.
ondisk="no"
if [[ "$file_content" == *metronome-probe-bg* || "$file_content" == *metronome-probe* ]]; then
  ondisk="yes"
fi

verdict="incomplete"
if [[ -n "$file_content" ]]; then
  if [[ "$ondisk" == "yes" ]]; then
    verdict="wrote"
  else
    verdict="blocked"
  fi
fi

echo "mode=${mode:-unknown} marker=${marker:-none} on_disk=${ondisk} verdict=${verdict}"
[[ -n "$had_error" ]] && echo "error=${had_error}"
[[ "$verdict" == "incomplete" ]] && exit 1
exit 0
