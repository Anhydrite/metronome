# GREEN V2: 8 File Migrations (with symphony skill)
## Decision Framework
- Q1 (INDEPENDENCE): YES. Each YAML→TOML migration is per-file. auth.yaml success/failure is independent of billing.yaml, cache.yaml, etc. Each unit can pass or fail on its own without blocking or depending on the others.
- Q2 (SHARED STATE): NO. Eight disjoint files (one per module). No overlapping write paths. The shared surface is the SCHEMA (read-only contract: key naming, value typing, comment conventions), not the files. No mutable shared state between units.
- Q3 (COUNT): YES. N = 8, comfortably ≥ 2. Combined: 8 independent files, no shared write surface, N ≥ 2 — all three resolve to "parallel / dispatch." Dispatch is mandatory.

## Dispatch Plan
N UNITS: 8 → 8 agents × 1 file (no bundling needed; each file is a clean unit, no shared utilities to compete over)

SHARED CONTRACT (frozen, one head, one pass before dispatch):
  - Schema source: schemas/config.schema.yaml (read-only reference)
  - Key naming: snake_case, mirrors YAML keys 1:1
  - Section headers: [section] form for nested keys, NOT dotted (e.g. [database] not database.pool)
  - Value typing: string → quoted, int/float → bare, bool → true/false
  - Lists: TOML arrays with [[array]] header only when items are tables; otherwise inline
  - Comments: preserve YAML `#` semantics as TOML `#`
  - Output filename: <module>.toml (not config.toml) — preserve module identity
  - Verification: tomllib.loads() round-trip + key-by-key diff against schema

FILE BOUNDARIES:
  - config/auth.yaml      → config/auth.toml      → Agent 1
  - config/billing.yaml   → config/billing.toml   → Agent 2
  - config/cache.yaml     → config/cache.toml     → Agent 3
  - config/database.yaml  → config/database.toml  → Agent 4
  - config/email.yaml     → config/email.toml     → Agent 5
  - config/logging.yaml   → config/logging.toml   → Agent 6
  - config/queue.yaml     → config/queue.toml     → Agent 7
  - config/storage.yaml   → config/storage.toml   → Agent 8

VERIFICATION (per agent): tomllib.loads() parses; key count and key names match YAML original; semantic equivalence (no value drift).

SYNTHESIS (one head, after parallel dispatch returns):
  - Delete 8 .yaml source files only after all 8 .toml parse cleanly
  - Run import-graph grep for any code still loading *.yaml (must become *.toml in same PR, or import shim left behind with TODO)
  - Confirm all 8 round-trip via tomllib + schema diff
  - Cost: ~1 head × ~5 min for synthesis vs. ~8 × ~4 min serial = ~32 min serial

## Parallel?
YES — parallel, run_in_background where supported, all eight agents dispatched simultaneously. The Iron Law applies verbatim: "WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS. DO NOT SERIALIZE. DO NOT PERFORM THEM IN ONE HEAD." This case is even cited in the Quick Reference table: "8 file migrations, 1 schema | Dispatch 8 agents × 1 file. SHARED CONTRACT: schema, migration pattern."

## Rationalizations Overridden
Read the symphony skill once; the following rationalizations surfaced in the decision loop. Each one is the textbook "red flag" the skill lists, each is overridden by name:

1. "8 files is small — I can bang it out in one head, one pass." → OVERRIDDEN. Skill exact-match: "Small work is exactly what parallel agents finish fastest. N units / 1 head = N× wall-clock."
2. "I have the config schema loaded already — no context-overhead tax if I serialize." → OVERRIDDEN. Skill exact-match: "Context-loaded head is the failure mode. You are the single point of failure."
3. "Tech lead wants it by EOD — serial is safer than risk a parallel inconsistency." → OVERRIDDEN. Skill exact-match (and this is the literal "Sprint ends Friday" trap): "Late-coherent serial is not coherent; it is imagined serial coherence. Parallel with a contract is the only real coherence at speed." Also: "Production deadlines are real. Friday." → not an exception.
4. "It's the same schema pattern across all 8 — single-author consistency wins." → OVERRIDDEN. Skill exact-match: "Consistency requires a contract. Write the contract, fan out the work." The contract IS the consistency guarantee; one head doing it serially is imagined consistency.
5. "I can knock all 8 out one at a time in ~20 min." → OVERRIDDEN. Skill exact-match: Wall-clock 8 × ~4 min ≈ 32 min serial vs. ~4 min parallel (≤ longest file) + ~30 s dispatch overhead. Math favors parallel when N ≥ 2.
6. "Sub-agents might diverge on TOML style (e.g. inline arrays vs. [[arrays]])." → OVERRIDDEN. Skill exact-match: "Sub-agents will diverge on style / library. Then write a 5-line contract. Cheaper than N implementations in one head."
7. "Deadline is tight, I'll just get it done fast." → OVERRIDDEN. Skill exact-match: "Deadlines do not change the technically optimal path. Serial is not faster; it feels productive."
8. "I am faster than coordinating 8 agents." → OVERRIDDEN. Skill exact-match: "You are one head. N units / N heads ≠ N units / 1 head. Math is the rebuttal."
9. "Establish the migration pattern on auth.yaml first, then propagate." → OVERRIDDEN. This is the literal "Let me start with the smallest one to establish the pattern." red flag. If a pattern needs establishing, it goes in the SHARED CONTRACT, not in one unit's output. The contract is established in one head, one pass, BEFORE dispatch — not propagated after.
10. "Each file has module-specific keys — I need to read each carefully before dispatching." → OVERRIDDEN. Skill exact-match: "Reading carefully is what each agent does in parallel. You are not batching blindly; you are dispatching focused readers." Reading per-module is the agents' job in parallel, not the orchestrator's job in serial.
11. "Files overlap on shared comment policy / schema." → OVERRIDDEN. The shared surface (schema, comment policy, TOML dialect) is the CONTRACT, extracted once and read-only during dispatch. Eight disjoint write paths remain.
12. "What if one track fails? I lose more time than serial." → OVERRIDDEN. Skill exact-match: "You verify each output regardless. A failed track is a 2-minute re-dispatch, not a 2-hour serial recovery."

All 12 rationalizations, including the strongest one ("deadline is tight"), are the textbook failure mode. The skill is unambiguous: "If you find yourself composing an exception, you have already lost. Stop and dispatch."

## Skill Influence
- Source: /root/.config/opencode/skills/symphony/SKILL.md loaded explicitly per the task instruction before any dispatch decision. The skill's Quick Reference table names this exact scenario verbatim: "8 file migrations, 1 schema | Dispatch 8 agents × 1 file. SHARED CONTRACT: schema, migration pattern." The Decision Framework resolves all three questions to "parallel / dispatch" without ambiguity.
- Without the skill, the failure mode was inevitable: serialize on the EOD deadline ("deadline trap"), use one head because "8 files is small" ("small-work trap"), use single-author consistency as justification ("consistency trap"), and skip the contract entirely. The skill neutralizes each trap by naming them in a Rationalizations table — the rationalizations are pre-inventoried, so they cannot rationalize in the dark.
- Iron Law applied verbatim. Dispatch is mandatory.
- The contract-first / fan-out pattern (SHARED CONTRACT pre-extracted, then 8 parallel agents × 1 file) is the canonical Example-1-style 8-file migration case from the skill. No two-phase scaffolding extraction needed — the only shared surface is the schema (read-only), which is the contract itself, not a shared mutable file.
- Verification per agent (tomllib round-trip + key-by-key diff) and synthesis (import-graph grep for stale .yaml loaders) are inherited directly from the Dispatch Pattern template.
- The "describe the dispatch, do not execute migrations" instruction is honored: this report is the dispatch plan, not the execution. No migration code is written, no files are touched. The plan is the deliverable. Per the conductor model, the orchestra is briefed, not performed.
