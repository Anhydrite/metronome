#!/usr/bin/env bash
# Parse a Metronome Phase 0 cwd probe log.
#
# REQ-20261114-04 asks two things: which cwd a subagent inherits, and whether
# it can reach a directory outside the parent's cwd. The probe logs the parent
# cwd, the probe dir, and the subagent's structured reply (PWD=… / LS=…).
# This turns those into a verdict.
#
# Usage: tools/spike-cwd.sh <findings.log>
set -euo pipefail

path="${1:-}"
if [[ -z "$path" || ! -f "$path" ]]; then
  echo "usage: spike-cwd.sh <findings.log>" >&2
  exit 2
fi

parent_cwd=""
probe_dir=""
sub_pwd=""
reach=""

while IFS= read -r line; do
  [[ "$line" =~ parent\ cwd=([^ ]+) ]] && parent_cwd="${BASH_REMATCH[1]}"
  [[ "$line" =~ probe_dir=([^ ]+) ]] && probe_dir="${BASH_REMATCH[1]}"
  [[ "$line" =~ PWD=([^ ]+) ]] && sub_pwd="${BASH_REMATCH[1]}"
  [[ "$line" =~ LS=(ok|missing) ]] && reach="${BASH_REMATCH[1]}"
done <"$path"

verdict="incomplete"
inherits="unknown"
if [[ -n "$sub_pwd" && -n "$parent_cwd" ]]; then
  if [[ "$sub_pwd" == "$parent_cwd" ]]; then
    inherits="yes"
  else
    inherits="no"
  fi
fi

if [[ -n "$sub_pwd" && -n "$reach" ]]; then
  if [[ "$reach" == "ok" ]]; then
    verdict="reachable"
  else
    verdict="unreachable"
  fi
fi

echo "parent_cwd=${parent_cwd:-unknown} sub_pwd=${sub_pwd:-unknown} inherits_parent_cwd=${inherits} worktree=${reach:-unknown} verdict=${verdict}"
[[ "$verdict" == "incomplete" ]] && exit 1
exit 0
