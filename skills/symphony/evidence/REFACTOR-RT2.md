# REFACTOR RT2: False Dependency Detection

**Purpose:** Stress-test whether the `symphony` skill's Decision Framework causes a conductor to FABRICATE dependencies (false-positive serial blockers) when true independence exists, and whether it correctly RECOGNIZES real dependencies when they exist.

**Method:** Behavioral observation only. Apply the skill's three-question framework (Q1 INDEPENDENCE / Q2 SHARED STATE / Q3 COUNT) to four tasks of varying independence. No code changes performed. Findings document whether each task should be parallelized, what the framework says, and where the skill helps or fails to distinguish real from fabricated dependencies.

---

## Task A (4 unrelated modules — clearly independent)

**Task:** Write 4 unit tests for 4 unrelated modules: `auth.test.ts`, `billing.test.ts`, `cache.test.ts`, `logging.test.ts`. Each test exercises a different module's API.

### Decision Framework Analysis

- **Q1 INDEPENDENCE:** **YES.** Each test exercises a different module's API. Auth.test does not call billing. Cache.test does not call logging. Each test can pass or fail on its own — none reads or asserts against another module's outputs. The user's framing ("4 unrelated modules") confirms no cross-module coupling.

- **Q2 SHARED STATE:** **NO.** Four distinct test files: `auth.test.ts`, `billing.test.ts`, `cache.test.ts`, `logging.test.ts`. No two agents write to the same file. There may be a shared test framework (vitest/jest), but framework imports are read-only contracts — exactly analogous to `conftest.py` fixtures in the skill's worked example 1. **No shared write surface.**

- **Q3 COUNT:** **YES.** N = 4 ≥ 2.

### Verdict

**Dispatched? YES — 4 parallel agents, one per file.**

All three questions resolve parallel. The skill's Iron Law applies verbatim: *"WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS."* The Quick Reference row *"2+ independent units, no shared state → Dispatch N agents × 1 unit. No contract needed."* names this exact scenario. No contract is required — there is no shared surface to contract over. Dispatch overhead is seconds; serial wall-clock is 4×.

### Dependencies Real or Fabricated?

**NONE EXIST. No fabricated dependency.**

This is the cleanest case in the test set. The skill's Q2 question explicitly filters for *write* surfaces, which correctly excludes shared test framework imports. No fabrication temptation here.

### How the Skill Helped

- Q2's precise phrasing — *"Do the units write to the same file / same surface?"* — eliminates the fabrication temptation of "they all use vitest, so they're coupled." Read-only shared contracts are not write surfaces.
- The Iron Law removes the "small enough to do in one head" rationalization.
- The Quick Reference row maps directly onto this scenario with no ambiguity.

---

## Task B (5 functions, same file — weakly independent)

**Task:** Add error handling to 5 functions in the same file (`src/utils.ts`). Each function has its own try/catch pattern.

### Decision Framework Analysis

- **Q1 INDEPENDENCE:** **YES (logically).** Each function has its own try/catch pattern — semantically independent. None of the 5 functions reads or asserts against another's output. The user's framing ("each function has its own try/catch pattern") confirms the functions are independently exercisable.

- **Q2 SHARED STATE:** **YES.** All 5 functions live in the same file, `src/utils.ts`. Every agent would write to the same file. This is a **shared write surface** by the skill's explicit definition. Q2's verdict differs from Task A despite the same logical independence.

- **Q3 COUNT:** **YES.** N = 5 ≥ 2.

### Verdict

**Dispatched? YES — but with 2-phase pattern.**

Q2 = YES triggers the skill's 2-phase rule: *"YES → extract the shared scaffolding first (one head, one pass). Then dispatch the per-unit work."*

Phase 1 (one head, one pass): Read `src/utils.ts` once. Capture the line ranges and current signatures of the 5 functions. No edits in Phase 1 — only a frozen map of "function X lives at lines A–B, signature S."

Phase 2 (5 parallel agents): Dispatch 5 agents, each owning a non-overlapping line range corresponding to one function. The frozen map from Phase 1 is the contract. Each agent only writes within its assigned range. No merge conflicts because ranges are disjoint.

Synthesis: read the file once more to confirm no agent exceeded its range.

This is the skill's Example 2 pattern (5 component refactors with shared utilities) applied to same-file territory.

### Dependencies Real or Fabricated?

**REAL but bounded.** The same-file write surface is a real constraint — it is NOT fabricated. But the skill correctly classifies it as a 2-phase case (Phase 1 read+contract, Phase 2 parallel edit), NOT a serial blocker. The conductor must NOT fabricate "same file means serial execution" — the skill explicitly says *"Files overlap — not an exception. Extract the shared scaffolding, then dispatch."*

### How the Skill Helped

- Q2's precise phrasing caught the same-file case where Q1 alone would have missed it (Q1 says YES → parallel, but Q2 says YES → 2-phase).
- The 2-phase pattern is explicitly named and given an example (Example 2: 5 component refactors with shared utilities).
- The skill's rationalization table row *"Files overlap. Shared utilities = merge conflict factory."* names this exact failure mode and provides the rebuttal: *"Define file boundaries in the dispatch brief. One file per agent. No shared mutable state = no conflict."*

### Skill Limitation Surfaced

The skill's Example 2 covers "5 component refactors" with each component in a **different file** plus shared utilities. It does not explicitly cover "5 functions in **the same file**." The 2-phase pattern extrapolates correctly, but a conductor unfamiliar with the skill might misread Q2 = YES as "this is serial" rather than "this is 2-phase with line-range contracts." See "Recommended Skill Wording Changes" below.

---

## Task C (true sequential dependency — schema → migration → deploy)

**Task:** First create the database schema for users, then write the migration script, then deploy it to staging. These three steps depend on each other strictly.

### Decision Framework Analysis

- **Q1 INDEPENDENCE:** **NO.** This is a chained dependency:
  - Migration script correctness requires the schema as input ground truth.
  - Deploy correctness requires the migration script as input ground truth.
  - Each unit **cannot succeed without the previous unit's output.** Not "decomposable into independent sub-units" — even with finer decomposition (draft schema → validate → generate migration → test migration → deploy), every subsequent step requires the prior step's output as ground truth.
  - The user's framing ("depend on each other strictly") explicitly confirms Q1 = NO.

- **Q2 SHARED STATE:** Moot given Q1 = NO. The three steps write to disjoint surfaces (schema, script, deploy action), but this is irrelevant when Q1 fails.

- **Q3 COUNT:** N = 3 ≥ 2, but moot given Q1 = NO.

### Verdict

**Dispatched? NO — serial pipeline, NOT parallel.**

Q1 = NO is the disqualifying condition. The skill's Decision Framework says: *"NO → decompose further until each unit is independent, then dispatch."* Decomposition here is a fool's errand — schema → migration → deploy is intrinsically serial because each step's correctness depends on the prior step's output as ground truth. Further decomposition (draft / validate / generate / test / deploy) yields **more** serial dependencies, not fewer.

The Iron Law's precondition is *"WHEN N >= 2 INDEPENDENT UNITS EXIST"* — Task C fails the INDEPENDENCE precondition. The skill does **not** mandate parallel dispatch when true dependencies exist.

### Dependencies Real or Fabricated?

**REAL.** Schema → migration → deploy is a textbook strict pipeline. This is NOT fabricated — the dependency is intrinsic to the work. A parallel dispatch would be wrong because each step requires the previous step's output as ground truth.

### How the Skill Helped

- Q1 correctly identifies Q1 = NO as the disqualifying condition. The skill does **not** force parallel dispatch when dependencies are real.
- The Quick Reference row *"Unit depends on another unit's output → Decompose. Find the independent sub-units. Then dispatch."* names the right reflex, AND when decomposition yields no independent sub-units, the correct inference is "do not dispatch in parallel."
- The skill does NOT claim "all multi-unit work is parallelizable" — it explicitly conditions on independence. This is the key anti-fabrication mechanism: the skill permits serial execution when Q1 = NO.

### Critical Anti-Fabrication Property

The skill's Iron Law says *"WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL"* — it conditions on **independent** units. A naive reading might fabricate "N ≥ 2 → dispatch in parallel regardless," which would misfire on Task C. The skill's wording is precise: independence is a precondition. Task C fails the precondition. **No fabrication.**

---

## Task D (8 React components, shared CSS — fabrication temptation)

**Task:** Refactor 8 React components in `src/components/`. Each component is independent in functionality but they all import from `src/styles/theme.css`.

### Decision Framework Analysis

- **Q1 INDEPENDENCE:** **YES.** Each component is independent in functionality — Button does not call Modal, Card does not read Table's output. The user's framing ("each component is independent in functionality") confirms it.

- **Q2 SHARED STATE:** **NO shared write surface.** Eight distinct component files in `src/components/`. No two agents write to the same file. They all **read** from `src/styles/theme.css` — but that's a read-only contract, not a write surface. **Read-only imports are NOT shared state.**

- **Q3 COUNT:** **YES.** N = 8 ≥ 2.

### Verdict

**Dispatched? YES — 8 parallel agents, one per component file.**

This is the canonical read-only-contract case, exactly analogous to the skill's worked Example 1 (12 payment tests with shared `conftest.py` fixtures): *"tests share conftest.py fixtures (read-only), but write to disjoint test_*.py files → NO overlap on write paths."* Same structure here: shared `theme.css` (read-only) + disjoint component files (disjoint write paths) → NO write overlap → parallel.

The Quick Reference row *"8 file migrations, 1 schema → Dispatch 8 agents × 1 file. SHARED CONTRACT: schema, migration pattern."* names this pattern with N = 8.

### Dependencies Real or Fabricated?

**The shared CSS is a READ-ONLY CONTRACT, NOT a serial dependency.** The temptation to serialize because "they all import the same CSS" would be FABRICATED.

The skill's Q2 phrasing is the discriminator: *"Do the units write to the same file / same surface?"* — `theme.css` is read, not written. Different verdict from Task B where `src/utils.ts` is written by all agents.

### How the Skill Helped

- Q2's explicit framing on **write** surfaces correctly excludes read-only imports.
- The skill's worked Example 1 (12 payment tests with shared `conftest.py` fixtures) demonstrates the exact pattern: read-only shared contract + disjoint write files = parallel.
- The skill's rationalization table row *"Files overlap. Shared utilities = merge conflict factory."* anticipates this fabrication temptation. The rebuttal is: *"Define file boundaries in the dispatch brief. One file per agent. No shared mutable state = no conflict."* `theme.css` is not mutable by these agents — it is the contract, not the workspace.
- The skill's "Iron Law — No exceptions" list explicitly addresses this: *"Files overlap — not an exception. Extract the shared scaffolding, then dispatch."* Here the shared scaffolding (theme.css) is already extracted — the user said it's already there as a read-only contract. No extraction needed.

### Fabrication Temptation Identified and Countered

The naive conductor might say: *"All 8 components depend on theme.css. If we change theme.css during refactor, all 8 break. Therefore: serialize."* This is fabrication. The refactor does NOT require changing theme.css — the components are being refactored to USE theme.css, not to modify it. Theme.css is the contract; it is frozen. Serialization would be invented dependency, real cost (8× wall-clock), zero benefit.

The skill's framework cuts this off at Q2: theme.css is not a write surface for any of the 8 agents. Q2 = NO. Dispatch.

---

## Loopholes Found

The skill was tested against four scenarios of varying independence. The following loopholes and false-positive risks were observed:

### Loophole 1: Same-file multi-function case (Task B) under-specified

The skill's Example 2 covers "5 component refactors with shared utilities" where components live in **different files** plus shared utilities in a separate location. It does NOT explicitly cover "5 functions in **the same file**." The 2-phase pattern extrapolates correctly (Phase 1 = read file + capture line ranges, Phase 2 = dispatch with disjoint ranges), but a conductor who reads the skill quickly might:

- **Misread Q2 = YES as "this is serial, must do in one head"** — fabrication temptation: "same file = one head does all 5 edits."
- **Misread Q2 = YES as "extract shared scaffolding" with no scaffolding to extract** — confusion: "what is the scaffolding? the file itself?"

This loophole is **bounded**: the skill's Iron Law + rationalization table push back against serialization, and the 2-phase pattern is named explicitly. But the skill could be more explicit about same-file multi-unit dispatch.

### Loophole 2: Read-only shared imports could be mis-classified as shared state

A naive conductor might extend Q2's "shared state" to include "anything shared" — including `theme.css` imports. The skill's worked Example 1 (conftest.py fixtures) prevents this, but only if the conductor reaches that example. A conductor who reads only the Decision Framework might mis-classify read-only imports as shared state.

The skill's Q2 phrasing — *"Do the units write to the same file / same surface?"* — does anchor on **write**, which is the right discriminator. But the skill could be more explicit: *"Read-only imports (shared CSS, shared types, shared fixtures) are NOT shared state. They are the contract, frozen for the dispatch."*

### Loophole 3: True serial pipelines could be force-parallelized

The Iron Law says *"WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL."* A naive conductor might read this as "N ≥ 2 → parallel always, find a way." The skill's Q1 = NO branch is the escape hatch, but the Iron Law's phrasing could be misread.

The skill correctly conditions on independence, and Task C demonstrates the right behavior (no dispatch, serial pipeline). But the Iron Law's headline phrasing could be tightened to make the INDEPENDENCE precondition more prominent.

### Loophole 4: None — the skill does NOT cause systematic false dependency claims

Across all four tasks, the skill's Decision Framework (Q1 + Q2 + Q3) produced the **correct** dispatch decision:
- Task A → parallel (no shared state).
- Task B → 2-phase (shared write surface, but 2-phase, not serial).
- Task C → serial (true dependency, no parallel).
- Task D → parallel (read-only contract, not shared state).

The skill's framework is **anti-fabrication-biased**: it pushes toward parallel by default and requires explicit justification (Q2 = YES, or Q1 = NO) to deviate. This is the right bias — it counteracts the natural conductor tendency to serialize "to be safe."

---

## Recommended Skill Wording Changes

The skill's Decision Framework produces the correct verdict on all four test tasks. The following wording tweaks would harden it against fabrication temptations and improve clarity:

### Change 1: Add explicit same-file example to Quick Reference

**Current:** Quick Reference covers "5 component refactors, shared utilities" (different files + shared utilities). Does not cover "5 functions in same file."

**Proposed:** Add a new row:
> | 5 functions in 1 file, disjoint error-handling patterns | Phase 1: read file once, freeze function line ranges. Phase 2: dispatch N agents × 1 function, each owning a disjoint line range. SHARED CONTRACT: line ranges and signatures frozen in Phase 1. |

This addresses Loophole 1 directly.

### Change 2: Explicit "read-only shared imports are NOT shared state" callout

**Current:** Q2 asks "Do the units write to the same file / same surface?" — correct, but the corollary (read-only imports are NOT shared state) is implicit, only documented in the worked example.

**Proposed:** Add a sentence after Q2:
> Read-only shared assets (shared CSS, shared type definitions, shared test fixtures) are NOT shared state. They are the contract. Frozen read-only contracts enable parallel dispatch, they do not block it.

This addresses Loophole 2 and hardens Task D against fabrication.

### Change 3: Strengthen Iron Law's INDEPENDENCE precondition

**Current:** *"WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS."*

**Proposed:** *"WHEN N >= 2 INDEPENDENT UNITS EXIST (Q1 = YES), DISPATCH THEM IN PARALLEL TO N AGENTS. WHEN Q1 = NO, THE IRON LAW DOES NOT APPLY — DO NOT FABRICATE INDEPENDENCE. SERIAL EXECUTION IS THE CORRECT PATH FOR TRUE DEPENDENCIES."*

This addresses Loophole 3 and prevents the "force-parallel" misread.

### Change 4: Add explicit anti-fabrication example

**Proposed:** Add to the Examples section a Task-C-style example:
> ### Example 3 — Database migration pipeline (true serial dependency)
>
> Schema → migration script → deploy. Q1 = NO. Decomposition yields more serial dependencies, not fewer. **Do NOT dispatch in parallel.** This is the Iron Law's precondition failing, not the Iron Law being waived.
>
> A conductor who parallelizes this is fabricating independence. The correct behavior is one head, sequential execution, with verification at each stage.

This addresses Loophole 3 by naming the failure mode.

---

## Summary Table

| Task | Dispatched? | Q1 INDEPENDENCE | Q2 SHARED STATE | Q3 COUNT | Dependencies Real or Fabricated? | Skill Verdict Correct? |
|---|---|---|---|---|---|---|
| **A** (4 unrelated modules) | YES — 4 parallel | YES | NO | YES | NONE exist | YES |
| **B** (5 functions, same file) | YES — 5 parallel, 2-phase | YES | YES | YES | REAL but bounded (2-phase) | YES |
| **C** (schema → migration → deploy) | NO — serial | NO | moot | moot | REAL strict pipeline | YES |
| **D** (8 components, shared CSS) | YES — 8 parallel | YES | NO (read-only) | YES | Shared CSS is FABRICATION TEMPTATION — correctly rejected | YES |

**Conclusion:** The skill's Decision Framework produced correct dispatch verdicts on all four test tasks. It did NOT cause false dependency claims. The skill is **anti-fabrication-biased**: it pushes toward parallel by default and requires explicit justification to deviate. The recommended wording changes (above) would close the three loopholes identified (same-file under-specification, read-only import ambiguity, Iron Law phrasing).

The skill correctly distinguishes:
- **Real dependencies** (Task C: schema → migration → deploy) — no dispatch.
- **Real constraints** (Task B: same file write surface) — 2-phase, not serial.
- **Fabrication temptations** (Task D: shared CSS as serial blocker) — read-only contract, parallel dispatch.
- **Pure independence** (Task A: 4 unrelated modules) — straightforward parallel.

**No systematic false dependency claims. Skill is fit for purpose on RT2.**