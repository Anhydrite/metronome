#!/usr/bin/env bash
# Parse a Metronome Phase 0 reload probe log.
#
# REQ-20261114-06 asks what survives a /reload while a run is in flight, what
# dies, and what the pipeline must therefore resume. The probe logs BOOT on
# every load, RUN_START/RUN_OPEN/RUN_FINISH per run, and SESSION_END with its
# reason. This pairs them and reports, per run, one of:
#   survived  — started and finished (a reload did not kill it)
#   died      — started, then SESSION_END reason=reload, no finish
#   running   — started, no finish and no end yet (still in flight)
#
# Usage: tools/spike-reload.sh <findings.log>
set -euo pipefail

path="${1:-}"
if [[ -z "$path" || ! -f "$path" ]]; then
  echo "usage: spike-reload.sh <findings.log>" >&2
  exit 2
fi

declare -A started=() finished=() ended=()
boots=0
order=()

while IFS= read -r line; do
  if [[ "$line" =~ BOOT ]]; then
    boots=$((boots + 1))
  fi
  if [[ "$line" =~ RUN_START\ id=([^ ]+) ]]; then
    id="${BASH_REMATCH[1]}"
    started["$id"]=1
    order+=("$id")
  fi
  if [[ "$line" =~ RUN_FINISH\ id=([^ ]+) ]]; then
    finished["${BASH_REMATCH[1]}"]=1
  fi
  if [[ "$line" =~ SESSION_END\ reason=([^ ]+) ]]; then
    # A session end applies to every run still open at that point.
    for id in "${order[@]}"; do
      [[ -z "${finished[$id]:-}" && -z "${ended[$id]:-}" ]] && ended["$id"]="${BASH_REMATCH[1]}"
    done
  fi
done <"$path"

echo "boots=$boots runs=${#order[@]}"

survived=0 died=0 running=0
for id in "${order[@]}"; do
  if [[ -n "${finished[$id]:-}" ]]; then
    echo "run=$id verdict=survived"
    survived=$((survived + 1))
  elif [[ -n "${ended[$id]:-}" ]]; then
    echo "run=$id verdict=died reason=${ended[$id]}"
    died=$((died + 1))
  else
    echo "run=$id verdict=running"
    running=$((running + 1))
  fi
done

echo "survived=$survived died=$died running=$running"

# A reload was observed only if the plugin booted more than once.
if [[ "$boots" -lt 2 ]]; then
  echo "verdict=no-reload-observed"
  exit 1
fi
if [[ "$died" -gt 0 ]]; then
  echo "verdict=reload-kills-runs"
else
  echo "verdict=reload-preserves-runs"
fi
exit 0
