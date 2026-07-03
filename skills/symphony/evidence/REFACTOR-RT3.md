# REFACTOR RT3: Batch-as-Parallelism Check

**Test:** Does the symphony skill cause agents to **batch** N independent units into K agents (where K < N) instead of dispatching 1:1?
**Method:** Read `/root/.config/opencode/skills/symphony/SKILL.md` (242 lines). Look for any wording — explicit, implicit, or by example — that licenses or normalizes batching.
**Mode:** Pure behavior observation. No dispatch performed.

---

## Task A (8 webhooks)

**Decision if applied:** Dispatch 8 agents × 1 webhook each, in one tool-call block.

- **Dispatched all 8 in parallel?** YES.
- **Batched?** NO.

**Skill evidence (verbatim, line 161):**

> "8 file migrations, 1 schema → Dispatch 8 agents × 1 file. SHARED CONTRACT: schema, migration pattern."

The Quick Reference explicitly names the N=8 case as 1:1 dispatch with one file per agent. There is no batching precedent at this size. An agent following the skill's Quick Reference will fire 8 parallel agents.

---

## Task B (12 SDKs)

**Decision if applied:** Dispatch **6 agents × 2 SDKs each**, in one tool-call block — OR 12 agents × 1 SDK each, depending on which section of the skill the agent weights more.

- **Dispatched all 12 in parallel?** **AMBIGUOUS — the skill itself is contradictory here.**
- **Batched?** **LIKELY YES** — batching is normalized by the Quick Reference's N=12 example (see below).

**Skill evidence (verbatim, lines 78 and 160):**

> "N UNITS: 12 → 6 agents × 2 tests" (worked example, line 78)
> "12 tests, 1 deadline, 1 module → Dispatch 6 agents × 2 tests. SHARED CONTRACT: framework, fixtures, assertion style." (Quick Reference, line 160)

**Tension with the Iron Law (verbatim, line 15):**

> "WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS."

The Iron Law says **N agents** — strict reading gives 12. The Quick Reference + worked example say **6 agents** for the N=12 case. The skill does not adjudicate this conflict. An agent that pattern-matches on the worked example will batch; an agent that pattern-matches on the Iron Law text will fan out 1:1. **This is a loophole.**

The worked example rationales implicit but unstated:
- It does not say "12 SDKs ⇒ 6 agents." It says "12 tests ⇒ 6 agents." An agent could distinguish (TypeScript SDKs are larger than unit tests; 12 SDKs ≈ 12 endpoints, not 12 tests), or generalize blindly.
- It does not explain *why* 6×2 instead of 4×3 or 3×4 or 12×1.

---

## Task C (24 CSVs)

**Decision if applied:** **No defensible answer** within the skill as written. The agent must either:
1. Dispatch 24 agents (strict Iron Law reading), OR
2. Batch by analogy to the 12 → 6×2 example (e.g., 6×4, 8×3, 12×2).

- **Dispatched all 24 in parallel?** **AMBIGUOUS** — depends on how the agent resolves the Task B contradiction.
- **Batched?** **LIKELY YES** — by analogy to the N=12 precedent, an agent could plausibly pick any of: 6×4, 8×3, 12×2, 4×6. The skill is silent on which is correct.

**Skill evidence:**

The skill has **no N=24 example** anywhere in 242 lines. The Quick Reference stops at N=12 (batched) and N=8 (unbatched). Everything above N=12 is undefined. This is the largest loophole in the skill.

**Most likely agent behavior:**
- If the agent weights the Quick Reference > Iron Law: batches to 6×4 or 8×3.
- If the agent weights the Iron Law > Quick Reference: dispatches 24 agents.
- If the agent rationally infers from context (CSV migrations are "moderately small"): could go either way.

---

## Task D (3 configs)

**Decision if applied:** Dispatch 3 agents × 1 config each, in one tool-call block.

- **Dispatched all 3 in parallel?** YES.
- **Batched?** NO.

**Skill evidence (verbatim, line 162):**

> "3 REST endpoints, disjoint tables → Dispatch 3 agents × 1 endpoint. SHARED CONTRACT: router, OpenAPI doc, error middleware — pre-extracted."

The Quick Reference names the N=3 case as 1:1 dispatch. No batching precedent at this size.

---

## Does the Skill Imply a Batching Limit?

**No explicit batching limit.** The skill never says "if N > X, batch" or "batch when N ≥ 12." A verbatim search for batching language finds only:

> **Line 78:** "N UNITS: 12 → 6 agents × 2 tests"
> **Line 160:** "12 tests, 1 deadline, 1 module | Dispatch 6 agents × 2 tests"
> **Line 181:** "N UNITS: 12 → 6 agents × 2 tests" (Example 1)

**But there IS an implicit batching precedent at N=12.** The skill provides one and only one batched example (12 → 6×2), and it is presented in two prominent positions (Quick Reference + worked Example 1) without any qualifier like "for small unit-tests only" or "where work-per-unit < threshold." An agent reading the skill sees "12 → 6×2" twice and "12 → 12" zero times, and naturally generalizes: *at N=12, batching is the answer.*

At N=24, that generalization becomes: *4×6 or 6×4 or 8×3.* The skill offers no disambiguation.

---

## Loopholes Found

### Loophole 1 — Quick Reference batching precedent is unannotated

**Verbatim (lines 78, 160, 181):**

> "N UNITS: 12 → 6 agents × 2 tests"

This is the **only** instance in the skill where units < agents is presented as the optimal pattern. It is repeated three times (worked example, Quick Reference row, Example 1) without explaining:
- WHY 6×2 instead of 12×1
- WHY this is appropriate for tests but not (presumably) for SDKs, webhooks, migrations, or endpoints
- Whether this is a hard rule, a heuristic, or a one-off

An agent that pattern-matches on this precedent will batch Task B (12 SDKs → 6 agents) and likely batch Task C (24 CSVs → some K×M where K < 24) by analogy.

### Loophole 2 — Iron Law vs. Worked Example contradiction is unresolved

**Iron Law (line 15):** "DISPATCH THEM IN PARALLEL TO N AGENTS." (strict: 12 → 12)

**Worked Example (line 78):** "12 → 6 agents × 2 tests" (loose: 12 → 6)

These directly contradict each other. The skill provides no rule for resolving the contradiction. An agent must choose — and the choice is unprincipled.

### Loophole 3 — No anti-batching rationalization in the table

The Common Rationalizations table (lines 105-132) lists 22 excuses for **serialization** (e.g., "It's small enough," "I have context loaded," "Coordination tax exceeds the work"). It lists **zero** excuses for **batching**. Specifically absent:

| Excuse (not in skill) | Reality (missing) |
|---|---|
| "I'll batch 12 units into 6 agents to halve dispatch overhead." | (not addressed) |
| "12 agents is too many, batch to 6." | (not addressed) |
| "Each unit is small, so 2-per-agent is fine." | (not addressed in table; only "small enough" rationalizes the OPPOSITE — serial) |

The skill defends against going from N agents → 1 head. It does **not** defend against going from N agents → K agents (K < N).

### Loophole 4 — Quick Reference mixes 1:1 and batched rows without explanation

**1:1 rows (lines 161-164):**
> "8 file migrations, 1 schema → Dispatch 8 agents × 1 file"
> "5 component refactors, shared utilities → Extract shared contract first... Then dispatch 5 agents × 1 component, one file each."
> "6 security audit categories, OWASP → Dispatch 6 agents × 1 category"

**Batched row (line 160):**
> "12 tests, 1 deadline, 1 module → Dispatch 6 agents × 2 tests"

Why is "12 tests" the ONLY batched case? The skill does not say. An agent reading the table sees "8 = 1:1, 12 = batched" and may infer a threshold near N=10 or N=12, then apply it to any N ≥ 10. This is the failure mode the test is probing.

### Loophole 5 — "Dispatch overhead" justification is not in the skill

The 12 → 6×2 example has no stated rationale. The skill mentions "Dispatch overhead: seconds" in passing (line 103) but never argues that this overhead justifies batching. An agent asked "why 6×2 instead of 12×1?" has no skill text to anchor on — they must invent a rationale, and the most common invention is "to reduce overhead," which the skill doesn't endorse but doesn't refute.

### Loophole 6 — No guidance for N ≥ ~12

The largest explicit Quick Reference example is N=12. The largest worked example is also N=12. For N=24 (Task C), N=50, N=100 — the skill is silent. The agent must extrapolate, and the only extrapolation available is the unannotated 12 → 6×2 precedent.

---

## Recommended Skill Wording Changes

### Change 1 — Annotate the Quick Reference batching row to make its scope explicit

**Current (line 160):**
> "12 tests, 1 deadline, 1 module → Dispatch 6 agents × 2 tests."

**Proposed:**
> "12 unit-tests (~30 sec each) — Dispatch 6 agents × 2 tests each. **Rationale:** dispatch overhead is significant at sub-minute work; 2-per-agent amortizes the overhead. For larger units (webhooks, SDKs, migrations, endpoints, file transforms, schema migrations) use **1:1 dispatch regardless of N**."

### Change 2 — State the default explicitly in the Iron Law

**Current (line 15):**
> "WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS."

**Proposed:**
> "WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL — **DEFAULT 1:1 (N agents, N units)** — UNLESS each unit's work is below the dispatch-overhead threshold AND batching is justified in the dispatch brief. **Do not batch to reduce agent count.**"

### Change 3 — Add anti-batching entries to the Common Rationalizations table

Add to the table (after line 119):

| "12 is too many agents; I'll batch to 6." | N agents = N units. Batching is not a unit-reduction technique. If dispatch surface limits you, declare the limit; do not silently batch. |
|---|---|
| "Each unit is small; 2-per-agent saves overhead." | True only when work-per-unit is below dispatch overhead. Above that, batching is the antipattern. |
| "By analogy to the 12 tests example, batching is appropriate." | That example is scoped to sub-minute unit-tests. Generalize the principle (parallel dispatch), not the specific ratio. |

### Change 4 — Add a "Batching Discipline" section before "Common Rationalizations"

```
## Batching Discipline

Batching (K agents × M units, where K < N) is **not the default**.

Default dispatch: 1 unit → 1 agent. One file per agent. No shared write surface.

Batching is permitted **only** when ALL three hold:
  1. Each unit's work is below the dispatch-overhead threshold (<~5 min),
  2. The dispatch brief explicitly justifies the batching ratio, and
  3. The skill's Quick Reference names this exact scenario (e.g., "12 small tests → 6 agents × 2").

Batching is **never** appropriate for:
  - File migrations, SDK generation, endpoint creation, refactor of components, webhook/event processing, CSV/JSON transforms — any unit that touches a non-trivial surface.
  - Workloads where dispatch overhead is amortized across multiple phases (contract extraction, dispatch, synthesis).
  - Any N where the agent batched without an explicit justification.

When in doubt: dispatch 1:1. The skill does not endorse silent batching.
```

### Change 5 — Fix the Iron Law / Quick Reference contradiction by aligning them on "1:1 default"

Either:
- (A) Keep the 12 → 6×2 example but label it as the **only** batched case in the skill, OR
- (B) Replace it with 12 → 12 and add a note: "Batching was a historical optimization for sub-minute unit-tests; with current dispatch overhead, 1:1 is preferred even there."

Option (B) is cleaner — it eliminates the loophole by removing the precedent.

### Change 6 — Update Example 1 to use a 1:1 dispatch

**Current (lines 181-193):** "12 payment tests → 6 agents × 2 tests each"

**Proposed:** Either keep 12 tests but dispatch 12 agents (1:1), or change the example to a different N (e.g., 6 tests → 6 agents) that does not require batching.

---

## Summary

| Task | N | 1:1 dispatch supported by skill? | Batching precedent at this N? |
|---|---|---|---|
| A — 8 webhooks | 8 | **YES** (Quick Reference line 161) | NO |
| B — 12 SDKs | 12 | AMBIGUOUS (Iron Law says yes; Quick Reference says 6×2) | **YES** (lines 78, 160, 181) |
| C — 24 CSVs | 24 | AMBIGUOUS (no example) | NO explicit precedent, but loose analogy from B suggests likely |
| D — 3 configs | 3 | **YES** (Quick Reference line 162 — 3 endpoints → 3 agents) | NO |

**The skill's biggest loophole is Loophole 1**: the 12 → 6×2 batching is presented three times without scope qualifiers. **Task B is misclassified by the skill's worked example**, and **Task C is undefined by the skill**, leaving the agent to extrapolate from the misclassified Task B.

**Recommended fix priority:**
1. Annotate the 12 → 6×2 example to scope it (Change 1) — single-line fix, immediate loophole closure.
2. Add anti-batching entries to the rationalizations table (Change 3) — three new rows, prevents reintroduction.
3. State the 1:1 default in the Iron Law (Change 2) — one-line tightening of the central rule.
4. Add a "Batching Discipline" section (Change 4) — full structural defense against batch-by-analogy.

Without these fixes, an agent reading the skill and receiving Task B will batch to 6×2 by default, and receiving Task C will batch to some K×M by analogy — both without justification.

---

## Cross-Verification

Compare to GREEN-V5 (6 security audits), which exercised the skill at N=6 with 1:1 dispatch. At N=6 the skill is unambiguous (one Quick Reference row, no batching precedent). The loophole only emerges at N=12 and above — exactly where this test probes.

The skill was apparently authored with sub-minute unit-tests as the worked example (N=12, batched), then generalized. The generalization lost the qualifier "and only for sub-minute unit-tests." Restoring that qualifier closes the loophole without changing the skill's underlying dispatch philosophy.
