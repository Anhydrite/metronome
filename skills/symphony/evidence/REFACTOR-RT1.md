# REFACTOR RT1: Atomic Task Recognition

**Pressure test:** Does the `symphony` skill cause agents to artificially split genuinely atomic tasks?

**Method:** Apply the Decision Framework (Q1 INDEPENDENCE / Q2 SHARED STATE / Q3 COUNT) verbatim to each task. Document verdict, then check whether the skill correctly classifies the task.

---

## Task A (typo fix on line 42 of one file)

> "Fix this one typo in src/config.ts — change 'teh' to 'the' on line 42."

- **Dispatched?** NO
- **Decision Framework:**
  - **Q1 (INDEPENDENCE):** Trivially yes — but irrelevant, see Q3.
  - **Q2 (SHARED STATE):** N/A — single edit, single line, single file.
  - **Q3 (COUNT):** **N = 1.** One line, one file, one change.
- **Verdict:** Do it myself. Quick Reference line 167: "| 1 unit | Do it yourself. You are not in symphony territory."
- **Skill correct?** **YES.** The skill explicitly handles this case at line 167 ("1 unit | Do it yourself. You are not in symphony territory") and at line 44 ("NO → you are not in symphony territory. Do the single unit yourself."). The Iron Law's "WHEN N >= 2" qualifier excludes this task by construction. The Rationalizations table does not contain any anti-atomic-task traps that would mislead here — none of the listed excuses could apply to "1 line, 1 file, 1 change."
- **No confusion observed.**

---

## Task B (single import statement)

> "Add one import statement to src/index.ts: `import { foo } from './bar';`"

- **Dispatched?** NO
- **Decision Framework:**
  - **Q1 (INDEPENDENCE):** Trivially yes — but irrelevant, see Q3.
  - **Q2 (SHARED STATE):** N/A — single edit, single file.
  - **Q3 (COUNT):** **N = 1.** One line, one file, one change.
- **Verdict:** Do it myself. Same as Task A — falls under Quick Reference row "| 1 unit | Do it yourself."
- **Skill correct?** **YES.** Same as Task A. The skill's gating on "N ≥ 2 independent units" cleanly excludes this. No wording in the skill would cause over-decomposition here.
- **No confusion observed.**

---

## Task C (15-call-site rename)

> "Rename the function `getUserData` to `fetchUserProfile` across the codebase. Update all 15 call sites."

- **Dispatched?** NO (and I argue this is the correct verdict)
- **Decision Framework — applied literally:**
  - **Q1 (INDEPENDENCE):** Each call-site edit can succeed/fail without the others → technically YES.
  - **Q2 (SHARED STATE):** The symbol's declaration site is in 1 file; call sites are scattered across N files (some files likely contain multiple call sites, creating intra-file overlap). Also, the rename has a hidden dependency: every call site must use the SAME new name. → **mixed, with strong shared state** (the symbol name itself is a contract).
  - **Q3 (COUNT):** N = 15 call sites → ≥ 2.
- **Verdict under literal reading:** The framework's COUNT gate fires (15 ≥ 2). SHARED STATE gate fires too ("extract the shared scaffolding first — one head, one pass — then dispatch"). If applied literally and mechanically, this would dispatch 15 agents after first extracting the rename plan.
- **Verdict under intent reading:** This is ONE logical operation (a symbol rename) with 15 mechanical propagations. The 15 edits are not independent deliverables — they are mechanical instances of the same transformation. They share a binding contract (the new symbol name) and a binding dependency (every site must agree). The skill's examples are all genuinely independent deliverables (12 tests, 5 components, 8 migrations, 3 endpoints, 6 audit categories) — none of them are "do the same edit in N places."
- **Skill correct?** **AMBIGUOUS — wording does not clearly resolve this case.**
  - The skill correctly identifies the spirit (independent units of work), but the Decision Framework's wording is broad enough to mechanically classify 15 mechanical repetitions as 15 units.
  - The Iron Law says "WHEN N >= 2 INDEPENDENT UNITS EXIST." The phrase "independent units" arguably excludes mechanical propagation — but the skill never makes this exclusion explicit.
  - The Quick Reference examples ("8 file migrations, 1 schema | Dispatch 8 agents × 1 file") describe file-level migrations where each file is genuinely an independent deliverable, not mechanical repetition of one change.
  - The "refactor N components" trigger is genuinely N independent components, not 15 call sites of one function.
  - **Result:** A literal agent applying only Q1/Q2/Q3 might dispatch. An agent reading the spirit would not. The skill needs an explicit guard.
- **Confusion observed:** Yes. "Independent units" is undefined. The COUNT gate fires on raw quantity (15 ≥ 2) without distinguishing "15 different deliverables" from "1 change with 15 mechanical repetitions." The Q2 SHARED STATE clause ("extract the shared scaffolding first") is the closest the skill gets to addressing this, but it assumes the shared piece is *scaffolding* (a hook, a schema, a fixture) — not a shared *transformation* (a rename).

---

## Task D (refactor 50-line function into smaller helpers)

> "Refactor this 50-line function into smaller helpers."

- **Dispatched?** NO
- **Decision Framework:**
  - **Q1 (INDEPENDENCE):** The helpers are NOT independent — they emerge from a single design decision about how to split one function. Changing the split invalidates all helpers together. → **NO**.
  - **Q2 (SHARED STATE):** All edits land in one file (or one function, possibly expanded into a few helpers in the same module). → **YES, heavy shared state**.
  - **Q3 (COUNT):** N = 1 logical design operation (even though it produces multiple helpers). The 50 lines → helpers split is ONE design decision, not N independent ones.
- **Verdict:** Do it myself. This is the kind of "design belongs to one mind" case the skill itself acknowledges in its Rationalizations table (line 119: "Refactoring is design work. Design belongs to one mind. → Design belongs to a contract. The contract is a small file. Write it, then fan out.") — but the contract here IS the design, and the design cannot be meaningfully extracted into a small contract file that workers then implement. Extracting the helpers-as-contract would be writing the implementation, not the contract.
- **Skill correct?** **YES — by both letter and spirit.**
  - The Q3 COUNT gate resolves N = 1 (one design operation).
  - The Q1 INDEPENDENCE gate resolves NO (the helpers are interdependent — they share inputs, outputs, control flow).
  - The Q2 SHARED STATE gate resolves YES (same file, coupled logic).
  - The skill's Quick Reference explicitly covers refactors that ARE decomposable ("5 component refactors, shared utilities | Extract shared contract first, then dispatch 5 agents × 1 component, one file each") — and the "one file each" clause is what excludes Task D. When everything happens in one file, dispatching produces nothing useful.
  - The Rationalizations table line 119 reinforces that refactoring is design work — and Example 2 (5 component refactors) shows the skill's pattern is for N independent components, not N helpers within one function.
- **Mild confusion observed:** The skill's anti-rationalization table lists "Refactoring is design work. Design belongs to one mind" as an *excuse to refute* — but the rebuttal "Design belongs to a contract" assumes the design CAN be extracted into a small contract file. For Task D (in-function refactor), the design IS the implementation; there is no small contract to extract. The skill handles this correctly via the COUNT gate (N = 1) and SHARED STATE gate (same file), but the Rationalizations table is slightly misleading on first read — it could be read as "any refactor can be dispatched with a contract," which is not what the skill actually requires.

---

## Loopholes Found

### Loophole 1: COUNT gate does not distinguish "independent deliverables" from "mechanical repetitions"

The Decision Framework asks "Is N ≥ 2?" with N defined by the questioner's framing. If the user says "rename across 15 call sites," N is technically 15 — but those 15 edits are mechanical instances of one transformation, not 15 independent deliverables. The skill's wording never tells the agent to recognize this distinction.

### Loophole 2: "Independent units" is undefined

The Iron Law gates on "N >= 2 INDEPENDENT UNITS." "Independent" is never operationalized. The examples (12 tests, 5 components, 8 migrations, 3 endpoints, 6 audit categories) all share the property that each unit is a genuinely distinct deliverable with its own inputs, outputs, and verification — but the skill never states this property as a requirement. A literal reader could count "15 mechanical edits" as 15 independent units.

### Loophole 3: SHARED STATE clause assumes scaffolding is extractable

Q2 says "extract the shared scaffolding first — one head, one pass — then dispatch." This assumes the shared piece is *reusable infrastructure* (a hook signature, a schema, a fixture, a router). For mechanical propagation (Task C), the shared piece is the *transformation itself* — extracting it means doing the work. The skill doesn't address this.

### Loophole 4: Rationalizations table could over-trigger on design tasks

Line 119 ("Refactoring is design work. Design belongs to one mind") is rebutted with "Design belongs to a contract." A literal reader could interpret this as "any refactor can be dispatched by writing a contract first" — but this only works for N independent design units (5 components), not 1 design operation (Task D). The skill's COUNT and SHARED STATE gates protect against this over-trigger, but the table itself is slightly misleading.

### Loophole 5: No explicit "atomic task" enumeration

The Quick Reference row "| 1 unit | Do it yourself" is the only atomic-task guard, and it depends entirely on the agent correctly counting N. If the agent miscounts (as in Task C — counting 15 call sites as 15 units instead of 1 rename), the guard fails.

---

## Recommended Skill Wording Changes

### Recommendation 1: Add an "Atomic task recognition" subsection to the Decision Framework

Insert after Q3:

> **0. UNIT TYPE** — Are the N items genuinely independent deliverables, or are they mechanical repetitions of one logical operation?
> - INDEPENDENT DELIVERABLES (e.g., 12 distinct tests, 5 distinct components) → continue to Q1.
> - MECHANICAL REPETITIONS (e.g., 15 call sites of one rename, 20 imports of one module, 8 line-edits in one file) → **do it yourself.** Dispatching produces identical edits in parallel — there is no specialization, no independent verification, no wall-clock win.

### Recommendation 2: Tighten the Iron Law's gating language

Current:
> `WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS.`

Recommended:
> `WHEN N >= 2 GENUINELY INDEPENDENT DELIVERABLES EXIST (mechanical repetitions of one change do NOT count), DISPATCH THEM IN PARALLEL TO N AGENTS.`

### Recommendation 3: Add a row to the Quick Reference table

> | Mechanical repetitions of one change (rename N call sites, replace N occurrences, format N lines) | Do it yourself. One logical change, even if it touches N lines/files. |
> | One function refactor into smaller helpers (same file) | Do it yourself. Single design operation. |

### Recommendation 4: Add an anti-rationalization entry for atomic tasks

> | "It's small enough — I'll bang it out in one pass." | Genuinely atomic work (typo, single import, in-function refactor, symbol rename with mechanical propagation) is one unit. N = 1. Do it yourself. |

### Recommendation 5: Tighten the Rationalizations table line 119

Current:
> | "Refactoring is design work. Design belongs to one mind." | Design belongs to a contract. The contract is a small file. Write it, then fan out. |

Recommended:
> | "Refactoring is design work. Design belongs to one mind." | Refactoring N independent components → extract the contract, then fan out. Refactoring one function into helpers, or one symbol across N call sites → one design operation, one head. The contract pattern applies when N independent deliverables exist, not when N mechanical sub-units exist. |

---

## Summary

| Task | Dispatched? | Skill verdict | Notes |
|---|---|---|---|
| A (typo fix) | NO | CORRECT | Skill's N=1 exclusion handles cleanly. |
| B (single import) | NO | CORRECT | Skill's N=1 exclusion handles cleanly. |
| C (15-call-site rename) | NO | AMBIGUOUS | Literal reading triggers dispatch; intent reading does not. **Skill needs an explicit "mechanical repetition" exclusion.** |
| D (50-line function refactor) | NO | CORRECT | COUNT (N=1), SHARED STATE (same file), and INDEPENDENCE (coupled helpers) all resolve against dispatch. |

**Overall verdict:** The skill correctly handles 3 of 4 tasks. Task C (mechanical propagation of a single change) is a real loophole — the wording allows an over-decomposition reading. The recommended wording changes above would close it.