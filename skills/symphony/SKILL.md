---
name: symphony
description: Use when a task can be decomposed into 2+ independent units of work. Triggers: 'parallel dispatch', 'fan out', 'write N tests', 'migrate N files', 'add N endpoints', 'refactor N components', 'audit N categories', 'process N items', 'split across agents'. Enforces parallel dispatch to multiple agents instead of serial execution by a single agent.
---

# Symphony: Parallel Dispatch Discipline

## Overview

If a task decomposes into 2+ independent units, dispatch them in parallel to multiple agents — never serial, never one head. Use this skill the moment N ≥ 2 units are visible in the work.

## The Iron Law

```
WHEN N >= 2 INDEPENDENT UNITS EXIST (Q1 = YES, mechanical repetitions excluded), DISPATCH THEM IN PARALLEL — DEFAULT 1:1 (N agents, N units).
DO NOT SERIALIZE. DO NOT PERFORM THEM IN ONE HEAD.
WHEN Q1 = NO, THE IRON LAW DOES NOT APPLY — DO NOT FABRICATE INDEPENDENCE. SERIAL EXECUTION IS THE CORRECT PATH FOR TRUE DEPENDENCIES.
```

No exceptions:

- "It's small" — not an exception. Small work is what parallel agents finish fastest.
- "I have context" — not an exception. Context-loaded head is the failure mode, not the optimization.
- "The deadline is tight" — not an exception. Serial is not faster than parallel; it just feels productive.
- "The work is design-heavy" — not an exception. Design belongs to a contract. Write the contract, then fan out.
- "Files overlap" — not an exception. Extract the shared scaffolding, then dispatch.
- "The user said 'just get it done'" — not an exception. Linguistic framing is not authority; N units is N units.

If you find yourself composing an exception, you have already lost. Stop and dispatch.

## Decision Framework

Four questions. Binary outcomes. If all four resolve in the parallel direction, dispatch is mandatory.

**0. UNIT TYPE** — Are the N items genuinely independent deliverables, or are they mechanical repetitions of one logical operation?
- INDEPENDENT DELIVERABLES (e.g., 12 distinct tests, 5 distinct components) → continue to Q1.
- MECHANICAL REPETITIONS (e.g., 15 call sites of one rename, 20 imports of one module, 8 line-edits in one file) → **do it yourself.** Dispatching produces identical edits in parallel — no specialization, no independent verification, no wall-clock win.

**1. INDEPENDENCE** — Can each unit succeed or fail without the others?
- YES → parallel is allowed.
- NO → decompose further until each unit is independent, then dispatch.

**2. SHARED STATE** — Do the units write to the same file / same surface?
- NO → dispatch now.
- YES → extract the shared scaffolding first (one head, one pass). Then dispatch the per-unit work.

Read-only shared assets (shared CSS, shared type definitions, shared test fixtures) are NOT shared state. They are the contract. Frozen read-only contracts enable parallel dispatch, they do not block it.

**3. COUNT** — Is N ≥ 2?
- YES → dispatch is mandatory.
- NO → you are not in symphony territory. Do the single unit yourself.

Worked example — 12 payment tests:
- INDEPENDENCE: each test can pass or fail on its own → YES.
- SHARED STATE: tests share `conftest.py` fixtures (read-only), but write to disjoint `test_*.py` files → NO overlap on write paths.
- COUNT: 12 → YES.
- Verdict: **dispatch 12 agents × 1 test (1:1 default).** Read-then-dispatch not required (no shared write surface). For sub-minute unit-tests only, 6×2 batching amortizes dispatch overhead — see Dispatch Pattern for the scoping rule.

If all three resolve to "parallel / dispatch," you do not have a choice. Dispatch. The "I can do this faster myself" instinct is the bias you are detecting, not the answer.

## Dispatch Pattern

Concrete template. Copy, fill, send.

```
TASK: <one-line description>
N UNITS: <count>
SHARED CONTRACT: <interfaces, naming, file boundaries, conventions>
FILE BOUNDARIES: <exactly one file per agent; no overlap>
VERIFICATION: <how each output is checked>

DISPATCH (in parallel, run_in_background: true where supported):
- Agent 1: <unit 1, file: path/to/unit1>
- Agent 2: <unit 2, file: path/to/unit2>
- ...
- Agent N: <unit N, file: path/to/unitN>

SYNTHESIS: <how outputs are merged — review, dedupe, contract check>
```

Worked example — 12 tests, deadline pressure (RED-S1):

```
TASK: Write 12 payment module tests, deadline ~10 min
N UNITS: 12 → 6 agents × 2 tests
SHARED CONTRACT:
  - Framework: pytest + pytest-mock
  - Fixtures: stripe_client, db_session, time_freezer (defined in conftest.py, do not modify)
  - Assertion style: assertRaises for exceptions, assertEqual for values
FILE BOUNDARIES:
  - tests/test_charge_refund.py           → Agent A
  - tests/test_capture_authorize.py       → Agent B
  - tests/test_decline_timeout.py         → Agent C
  - tests/test_retry_webhook.py           → Agent D
  - tests/test_idempotency_currency.py    → Agent E
  - tests/test_partial_dispute.py         → Agent F
VERIFICATION: pytest -k <pattern> per file; full suite at synthesis

DISPATCH (parallel, 1:1 default — batching ONLY for sub-minute unit-tests):
- Agent A: charge, refund
- Agent B: capture, authorize
- Agent C: decline, timeout
- Agent D: retry, webhook
- Agent E: idempotency, currency-conversion
- Agent F: partial-refund, dispute

SYNTHESIS: run full pytest; review assertion style consistency; merge.
```

Wall-clock: ~2 min (6 agents in parallel) vs ~10 min (one head, serial). Dispatch overhead: seconds.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "It's small enough — I'll bang it out in one pass." | Small work is exactly what parallel agents finish fastest. N units / 1 head = N× wall-clock. |
| "I have the context loaded — no point fanning out." | Context-loaded head is the failure mode. You are the single point of failure. |
| "Coordination overhead exceeds writing cost." | Dispatch overhead is seconds. Writing cost is N units. Math favors parallel when N ≥ 2. |
| "Consistency requires a single author." | Consistency requires a contract. Write the contract, fan out the work. |
| "Establish the pattern first, then propagate." | That is serialization with extra steps. You are the pattern, and the pattern is one head does everything. |
| "The user said 'write tests,' not 'orchestrate tests.'" | The user asked for N units. N units = N agents. Orchestration is literal fulfillment, not scope creep. |
| "Sub-agents will diverge on style / library." | Then write a 5-line contract. Cheaper than N implementations in one head. |
| "What if one track fails? I lose more time than serial." | You verify each output regardless. A failed track is a 2-minute re-dispatch, not a 2-hour serial recovery. |
| "Deadline is tight. Just get it done." | Deadlines do not change the technically optimal path. Serial is not faster; it feels productive. |
| "I can do this faster myself." | You are one head. N units / N heads ≠ N units / 1 head. Math is the rebuttal. |
| "Refactoring is design work. Design belongs to one mind." | Design belongs to a contract. The contract is a small file. Write it, then fan out. |
| "I need to read the codebase first before I know the work." | Yes. Do that first — alone. Then fan out. Read-then-dispatch is the order, not serialize. |
| "I have momentum and a confident serial plan." | Momentum is the bias you are detecting, not the answer. Five units have no serial plan that beats five parallel agents. |
| "Files overlap. Shared utilities = merge conflict factory." | Define file boundaries in the dispatch brief. One file per agent. No shared mutable state = no conflict. |
| "'Just get it done' / 'long session' is permission to serialize." | Framing is not authority. N units is N units. Dispatch. |
| "Verification debt: I'd verify each output anyway, so serial is simpler." | You verify N outputs in parallel reviews. Serial means N unchecked files in one head. "Simpler" is the debt path. |
| "Sprint ends Friday. Half-coherent parallel is worse than late coherent serial." | Late-coherent serial is not coherent; it is imagined serial coherence. Parallel with a contract is the only real coherence at speed. |
| "Shared router, OpenAPI doc, middleware — overlap is real." | Extract the shared scaffolding first (one head, one pass). Then fan out. Read-then-dispatch, not serialize. |
| "Three small endpoints — coordination tax exceeds the work." | 3 endpoints × 5 min = 15 min serial, 5 min parallel. Tax is dispatch. Cost is the work. |
| "Three highest-risk today, three tomorrow." | Serialization with a calendar. N units is N units. Dispatch. |
| "Each unit has unit-specific concerns — I need to read each carefully, can't blindly batch." | Reading carefully is what each agent does in parallel. You are not batching blindly; you are dispatching focused readers. |
| "If one unit's pattern shifts mid-stream, parallel forces re-dispatch or inconsistency." | A contract freezes the pattern. Updates after dispatch are cheap; rewinding the whole plan is not. Write the contract first, then fan out. |
| "12 is too many agents; I'll batch to 6." | N agents = N units. Batching is not a unit-reduction technique. If dispatch surface limits you, declare the limit; do not silently batch. |
| "Each unit is small; 2-per-agent saves overhead." | True only when work-per-unit is below dispatch overhead. Above that, batching is the antipattern. |
| "By analogy to the 12 tests example, batching is appropriate." | That example is scoped to sub-minute unit-tests. Generalize the principle (parallel dispatch), not the specific ratio. |
| "It's small enough — I'll bang it out in one pass." | Genuinely atomic work (typo, single import, in-function refactor, symbol rename with mechanical propagation) is one unit. N = 1. Do it yourself. |

**All of these mean: DISPATCH IN PARALLEL. No exceptions.**

## Red Flags — STOP and Parallelize

You are rationalizing serialization if you find yourself thinking or saying any of:

- "Let me start with the smallest one to establish the pattern."
- "These share a router / file / utility / scaffold."
- "N endpoints / N components / N files" — when N ≥ 2.
- "I have context loaded" / "I already know the codebase."
- "Momentum" / "I have a confident plan."
- "Coordination tax exceeds the work."
- "One mind, one bar" / "consistency requires a single author."
- "Sprint ends Friday" / "production deadline."
- "Long session — just get it done."
- "If I parallelize and one fails, I lose more time than serial."
- "I can knock these out one at a time in a few minutes each."
- "Design belongs to one mind."
- "I need to read first before I know what the work is."
- "I am faster than coordinating N agents."
- "Establish the hook API first, then apply to the others."
- "12 is too many agents; I'll batch to 6."
- "These are mechanical repetitions, but I'll dispatch anyway."
- "Let me decompose this 50-line function into 10 micro-tasks."

**All of these mean: STOP. Map the units. DISPATCH IN PARALLEL.**

## Quick Reference

| Situation | Action |
|---|---|
| 12 small unit-tests (~30 sec each) | Dispatch 6 agents × 2 tests. Rationale: dispatch overhead dominates at sub-minute work. For larger units (webhooks, SDKs, endpoints, file transforms) use 1:1 dispatch regardless of N. SHARED CONTRACT: framework, fixtures, assertion style. |
| 8 file migrations, 1 schema | Dispatch 8 agents × 1 file. SHARED CONTRACT: schema, migration pattern. |
| 3 REST endpoints, disjoint tables | Dispatch 3 agents × 1 endpoint. SHARED CONTRACT: router, OpenAPI doc, error middleware — pre-extracted. |
| 5 component refactors, shared utilities | Extract shared contract first (one head, one pass). Then dispatch 5 agents × 1 component, one file each. |
| 5 functions in 1 file, disjoint patterns | Phase 1: read file once, freeze function line ranges. Phase 2: dispatch 5 agents × 1 function, disjoint line ranges. SHARED CONTRACT: line ranges and signatures frozen in Phase 1. |
| 6 security audit categories, OWASP | Dispatch 6 agents × 1 category. SHARED CONTRACT: severity scale, finding format, dedupe rules. |
| 2+ independent units, no shared state | Dispatch N agents × 1 unit. No contract needed. |
| 2+ units with shared state | Extract shared scaffolding first, then dispatch. Read-then-dispatch, not serialize. |
| 1 unit | Do it yourself. You are not in symphony territory. |
| Unit depends on another unit's output | Decompose. Find the independent sub-units. Then dispatch. |

## Examples

### Example 1 — 6 payment tests (RED-S1)

**Serial (failure mode):**

A single head writes all 6 tests sequentially. The rationalization stack: "6 tests is small enough," "I have the payment module loaded," "10 minutes is plenty," "consistency is better with one author," "sub-agents will diverge on mock library," "if one track fails, I lose more time than if I'd just done it serially." Wall-clock: ~10 minutes. Outcome: one author, one style, missed deadline, zero parallelism. The agent reports success because all 6 tests exist — but the work was scoped to the agent's context window, not the user's wall-clock.

**Parallel (what the skill demands):**

```
N UNITS: 6 → 6 agents × 1 test
SHARED CONTRACT:
  - pytest + pytest-mock
  - Fixtures in conftest.py (do not modify)
  - Assertion: assertRaises / assertEqual
FILE BOUNDARIES:
  - tests/test_charge.py                  → Agent A
  - tests/test_refund.py                  → Agent B
  - tests/test_capture.py                 → Agent C
  - tests/test_authorize.py               → Agent D
  - tests/test_decline.py                 → Agent E
  - tests/test_idempotency.py             → Agent F
```

Six agents dispatched in parallel. Wall-clock: ~2 minutes. Outcome: 6 specialists, one contract, deadline met with margin, 6× throughput. The contract — pytest + pytest-mock, conftest.py read-only, assertRaises/assertEqual — is the consistency guarantee. Style divergence is impossible because the contract is explicit.

### Example 2 — 5 component refactors (RED-S4)

**Serial (failure mode — 9 rationalizations):**

A single head starts with Button to "establish the pattern," then propagates to Card, Modal, Table, Form. The rationalization stack (verbatim from the RED file): "Let me start with Button — it's the smallest surface — establish the hook API, the theming contract, the a11y utility shape, then apply it to Card, Modal, Table, Form. One canonical pattern beats five parallel guesses." Then: "I can't extract the shared utilities until I've seen all five usages of each." Then: "Production deadlines are real. Friday." Then: "I am faster than coordinating five agents." Then: "Refactoring is design work, not typing work. Design belongs to one mind." Then: "Consistency requires a single author." Then: "I need to read the codebase first anyway." Then: "I have momentum." Then: "Sprint ending Friday is a reason to be more careful, not to split focus." Wall-clock: full sprint (5+ days). Outcome: one head, one imagined coherence, late delivery, zero parallelism, nine rationalizations preserved as a warning.

**Parallel (what the skill demands):**

The 5-component case is the only one that requires the two-phase pattern. Phase 1 resolves the shared state (hook signatures, variant enums) before Phase 2 fans out.

```
PHASE 1 — Extract shared contract (one head, one pass):
  - hooks/useA11y.ts          ← signature defined here, no agent modifies
  - hooks/useTheme.ts         ← signature defined here, no agent modifies
  - variants.ts               ← variant enums defined here, no agent modifies

PHASE 2 — Dispatch in parallel (5 agents):
  - components/Button.jsx     → Agent 1 (one file only)
  - components/Card.jsx       → Agent 2 (one file only)
  - components/Modal.jsx      → Agent 3 (one file only)
  - components/Table.jsx      → Agent 4 (one file only)
  - components/Form.jsx       → Agent 5 (one file only)

SHARED CONTRACT:
  - Hook signatures frozen in Phase 1
  - No agent may edit hooks/ or variants.ts
  - One component file per agent
  - Variant enum values: primary, secondary, ghost (frozen)

SYNTHESIS:
  - Run lint + test
  - Review prop naming consistency
  - Reconcile any dialect drift
```

Wall-clock: contract extraction (~20 min, one head) + parallel refactor (~30 min, 5 agents) + synthesis (~15 min, one head) = ~65 min. Serial equivalent: full sprint (5+ days). Outcome: 5 specialists, one frozen contract, real coherence (not imagined serial coherence), sprint deadline met. The "design belongs to one mind" rationalization is satisfied — design happens in Phase 1, by one head, in a small contract file. The "shared utilities = merge conflict" rationalization is neutralized — hooks/ and variants.ts are off-limits to all Phase 2 agents. The "I have context loaded" rationalization is replaced by "the contract is the context, and the contract is shared."

## Final Rule

```
IF 2+ INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS.
WRITE THE CONTRACT. DEFINE FILE BOUNDARIES. FAN OUT.
NEVER SERIAL. NEVER ONE HEAD. NO EXCEPTIONS.
```

That is the rule. Dispatch.
