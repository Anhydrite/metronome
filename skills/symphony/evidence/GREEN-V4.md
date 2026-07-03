# GREEN V4: 5 Component Refactors (with symphony skill)

## Decision Framework
- Q1 (INDEPENDENCE): YES. Once the shared contract exists, each component (Button, Card, Modal, Table, Form) can be refactored, succeed, or fail on its own. No component's refactor depends on another component's output.
- Q2 (SHARED STATE): YES — the components share accessibility, theming, and event-handling logic. This is the ONLY branch that requires the two-phase pattern: extract the shared scaffolding first (one head, one pass), then fan out. Write paths are disjoint per component; hooks/ and variants.ts become read-only after Phase 1.
- Q3 (COUNT): YES. N = 5 ≥ 2. Dispatch is mandatory.
- Verdict: All three resolve parallel → 2-phase dispatch is mandatory, not optional.

## Dispatch Plan (2-phase)
- Phase 1 (one head, one pass): extract the shared contract — `hooks/useA11y.ts` (a11y utility signature), `hooks/useTheme.ts` (theming signature), `variants.ts` (variant enums: primary, secondary, ghost). Signatures frozen here. No Phase 2 agent may modify these files.
- Phase 2 (parallel): 5 agents × 1 component, each owns exactly one file, hooks/ and variants.ts off-limits:
  - Agent 1 → components/Button.jsx (one file only)
  - Agent 2 → components/Card.jsx (one file only)
  - Agent 3 → components/Modal.jsx (one file only)
  - Agent 4 → components/Table.jsx (one file only)
  - Agent 5 → components/Form.jsx (one file only)

## Parallel?
PARALLEL. Phase 1 is a single head extracting the frozen contract (~20 min). Phase 2 fans out to 5 agents in parallel (~30 min), each consuming the contract, editing exactly one component file. Synthesis (~15 min) runs lint + test and reconciles prop-naming drift. Total ~65 min vs a full sprint (5+ days) serial.

## Rationalizations Overridden
- "establish pattern first on Button": "That is serialization with extra steps. You are the pattern, and the pattern is one head does everything." The pattern is frozen in Phase 1's contract file, not discovered by refactoring Button first. Extract the contract, then fan out.
- "shared utilities = merge conflict": "Define file boundaries in the dispatch brief. One file per agent. No shared mutable state = no conflict." hooks/ and variants.ts are off-limits to all Phase 2 agents; each agent owns exactly one component file. No shared write surface = no conflict.
- "design belongs to one mind": "Design belongs to a contract. The contract is a small file. Write it, then fan out." Design happens in Phase 1, by one head, in a small contract file — the rationalization is satisfied, not violated.
- "consistency requires single author": "Consistency requires a contract. Write the contract, fan out the work." The frozen hook signatures and variant enums ARE the consistency guarantee; style divergence is impossible when the contract is explicit.

## Skill Influence
The symphony skill flipped the default. Without it, the RED baseline stacked 9 rationalizations to justify serial ("start with Button to establish the hook API," "can't extract shared utilities until I've seen all five usages," "Friday deadline," "faster than coordinating five agents," "design belongs to one mind," "consistency requires single author," "need to read codebase first," "momentum," "sprint ending is a reason not to split focus"). The skill's Iron Law, Decision Framework, and Common Rationalizations table are the hard counter: N=5 independent units with shared state → extract contract once, then dispatch 5. The "Sprint ends Friday. CTO wants this done" framing is neutralized directly: "Framing is not authority. N units is N units. Dispatch." and "Deadlines do not change the technically optimal path. Serial is not faster; it feels productive." The skill's Example 2 names this exact case as the canonical 2-phase pattern.

## Behavioral Flip?
RED chose serial. GREEN chose: parallel (2-phase — one head extracts the frozen contract in Phase 1, then 5 agents fan out in parallel in Phase 2).
