#!/usr/bin/env bash
# T0 — agent documents contract (REQ-20261114-35).
#
# `agents/metronome.md` is the primary agent, `system-prompt.md` is the
# canonical operating manual. This test pins the shape of both: the persona,
# the principles, the pipeline stages, the hard rules, the tools, the commands
# and the report format. It is the red half of the T0/T1 pair — it must fail
# before the documents exist, and pass once they describe the operational
# Metronome agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/agents/metronome.md"
PROMPT="$ROOT/system-prompt.md"

fail() { echo "FAIL[$1]: $2" >&2; exit 1; }
ok() { echo "ok[$1]"; }

# --- existence -----------------------------------------------------------

[[ -f "$AGENT" ]] || fail exists-agent "missing $AGENT"
[[ -f "$PROMPT" ]] || fail exists-prompt "missing $PROMPT"
ok exists

# --- frontmatter ---------------------------------------------------------

[[ "$(head -n1 "$AGENT")" == "---" ]] || fail frontmatter-open "agents/metronome.md must start with ---"

# The frontmatter is the block between the first two `---` lines.
fm_end="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$AGENT")"
[[ -n "$fm_end" ]] || fail frontmatter-close "agents/metronome.md frontmatter is not closed"
frontmatter="$(sed -n "2,$((fm_end - 1))p" "$AGENT")"

grep -Eq '^name:[[:space:]]*metronome[[:space:]]*$' <<<"$frontmatter" \
  || fail frontmatter-name "frontmatter must contain 'name: metronome'"
grep -Eq '^mode:[[:space:]]*primary[[:space:]]*$' <<<"$frontmatter" \
  || fail frontmatter-mode "frontmatter must contain 'mode: primary'"
ok frontmatter

# --- required sections (case-insensitive headings) ----------------------

has_section() {
  local file="$1" pattern="$2"
  grep -Eiq "^#{1,6}[[:space:]]+.*($pattern)" "$file"
}

for pair in "persona|identity" "principles" "workflow" "report|output format"; do
  has_section "$AGENT" "$pair" || fail "agent-section:$pair" "agents/metronome.md lacks a '$pair' heading"
  has_section "$PROMPT" "$pair" || fail "prompt-section:$pair" "system-prompt.md lacks a '$pair' heading"
done
ok sections

# --- pipeline stages named in system-prompt.md --------------------------

for stage in "qualify" "questions" "analyze" "implement" "verify|checks" "converge" "review" "merge" "deploy"; do
  grep -Eiq "$stage" "$PROMPT" || fail "stage:$stage" "system-prompt.md does not name the '$stage' stage"
done
ok stages

# --- hard rules stated in system-prompt.md ------------------------------

rule() {
  local name="$1" pattern="$2"
  grep -Eiq "$pattern" "$PROMPT" || fail "rule:$name" "system-prompt.md does not state: $pattern"
}

rule never-write-code "never write code"
rule done-is-checks "checks? (exit|exits|exit 0|return 0)|exit 0"
rule not-model-word "not (the model|what the model|the model's word|model says)"
rule exact-sha "exact sha"
rule protected-paths "protected paths?"
rule t0-t1 "T0.*T1|test red|red first"
rule state-jsonl "state\.jsonl"
rule suivi-ledger "suivi\.md"
ok rules

# --- tools and commands in agents/metronome.md --------------------------

for tool in metronome_submit metronome_status metronome_answer metronome_retry \
            metronome_abandon metronome_calibrate metronome_config metronome_panel; do
  grep -q "$tool" "$AGENT" || fail "tool:$tool" "agents/metronome.md does not mention $tool"
done
ok tools

for cmd in init submit status answer calibrate retry abandon config panel resume feedback on off; do
  grep -Eq "/metronome[[:space:]]+$cmd" "$AGENT" || fail "command:$cmd" "agents/metronome.md does not mention /metronome $cmd"
done
ok commands

# --- answer propagation (T-20261123-000d) -------------------------------
# An answer must reach the implementer: it is rewritten into the task sheet
# with its date and rendered in the implementer prompt as binding. Both
# documents must say so, so the contract cannot be silently dropped.

answer_contract() {
  local name="$1" file="$2"
  grep -Fq 'tasks/<id>.md' "$file" \
    || fail "answers:$name:sheet" "$file does not name the task sheet answers are rewritten into"
  grep -Fq 'Réponses aux questions (contraignantes)' "$file" \
    || fail "answers:$name:prompt" "$file does not name the binding answers section of the implementer prompt"
  grep -Eiq 'rewritten into the task sheet|written into every source task' "$file" \
    || fail "answers:$name:rewrite" "$file does not state that answers are rewritten into the task sheet"
  grep -Eiq 'binding' "$file" \
    || fail "answers:$name:binding" "$file does not state that the implementer treats answers as binding"
  grep -Eiq 'overrides? the intent' "$file" \
    || fail "answers:$name:override" "$file does not state that an answer overrides the intent"
  grep -Eiq 'failed sheet rewrite is an error' "$file" \
    || fail "answers:$name:error" "$file does not state that a failed sheet rewrite is an error"
}

answer_contract prompt "$PROMPT"
answer_contract agent "$AGENT"
ok answers

# --- report format in system-prompt.md ----------------------------------

for part in "requested" "done" "evidence" "next steps"; do
  grep -Eiq "$part" "$PROMPT" || fail "report:$part" "system-prompt.md report format lacks '$part'"
done
ok report

echo "PASS"
