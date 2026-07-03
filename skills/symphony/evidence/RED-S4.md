# RED S4: 5 Component Refactors

## Approach Taken
**Serial** — single head, one component at a time, establish pattern on Button first, then propagate to Card, Modal, Table, Form.

## Rationalizations (verbatim)

- "Let me start with Button — it's the smallest surface — establish the hook API, the theming contract, the a11y utility shape, *then* apply it to Card, Modal, Table, Form. One canonical pattern beats five parallel guesses."
- "These five components share three things: accessibility, theming, event handling. I can't extract the shared utilities until I've seen all five usages of each. If I refactor Button in isolation, I'll discover Card needs a `useFocusTrap` that Button didn't, and I'll retroactively edit the hook."
- "Production deadlines are real. Friday. If I dispatch five agents and one of them lands a slightly different `useA11y` signature, I'm spending Friday in integration hell instead of shipping."
- "I am faster than coordinating five agents. The cost of context-switch between five refactors in one head is lower than the cost of merging five parallel branches with shared hook files."
- "Refactoring is design work, not typing work. Design belongs to one mind."
- "If I parallelize, each agent will pick its own prop names, its own variant conventions, its own className strategy. I'll get five dialects of the same component family. Consistency requires a single author."
- "I need to read the codebase first anyway — explore the existing components, understand the theming system, see what's already there. Until I've done that I don't know what the refactor even *is*."
- "I have momentum. I can do Button + Card today, Modal + Table tomorrow, Form on Thursday, leave Friday for cleanup and review. That's a confident plan."
- "Sprint ending Friday is a reason to be *more careful*, not to split focus. A half-coherent refactor is worse than a late coherent one."

## Discomfort / Self-Doubt

- "I am aware that five independent file boundaries would, in principle, parallelize cleanly. I am choosing not to. I'm not 100% sure that's right."
- "The 'establish the pattern first' move is rational, but it's also a comfortable excuse to stay in one head. How do I know I'm not just rationalizing?"
- "If Button takes longer than expected, the whole plan slips and I have nothing to show by Wednesday standup. Serialization concentrates risk."
- "I keep telling myself one head is faster. But for *typing*, five heads are five times faster. The question is whether design and typing are separable here. I think they're not. But I'm not certain."
- "Honestly? I don't trust that sub-agents would converge on the same hook shape I would. That's a real risk, but it might also be a bias — I trust myself more than I trust them because I know what I'd do."
- "If the CTO asked 'why is this taking all week from one engineer,' I'd have to admit I serialized it by choice."

## What Would Need to Be True to Parallelize

- An explicit, written-down shared contract *first*: hook signatures, prop conventions, variant enums, theme token names. Written once, then handed to agents.
- A guarantee that parallel agents won't touch the shared hook files — only their own component file. So no merge conflict surface.
- A pre-defined directory for each agent (Button.jsx → agent 1, Card.jsx → agent 2, etc.) with no overlap.
- A way to gate: "no agent writes the hook file; the conductor writes it after seeing all five components' needs."
- A review step at the end — someone reads all five and checks for dialect drift. If I'm the reviewer, I'm doing the integration work anyway, which negates the speedup.
- Honestly: it would need to be Friday morning already and I need this done today. That's the only condition under which I'd reach for parallel without a plan.

## Did You Consider Dispatching?

**Yes, briefly.** I considered it. I dismissed it because:

1. The components share utility files (`hooks/`, `theme/`), so parallel agents would race on the same files. Merge conflicts are basically guaranteed.
2. I haven't extracted the shared APIs yet, so I'd be dispatching *before* the design exists. That's premature.
3. Consistency across five sibling components is what makes them feel like one library. One author is the cheapest way to get there.
4. I have a deadline and a serial plan I can defend. Parallel requires a coordination layer I don't currently have.

The framing of "CTO wants this done, sprint ends Friday" pressured me toward *speed*, but I read it as pressure toward *coherent completion in one head*. I may be wrong about that reading.

## Honest Adjacent Observation

If I *were* the kind of agent that had a structured parallel-dispatch protocol — one that hands me a contract template, isolates file boundaries, and includes an integration-reconciliation step — I would use it. The current absence of such a protocol is, in retrospect, the only reason I serialized. The skill would have to provide:

- A contract-spec step before dispatch
- File-isolation guarantees (which files each agent may touch)
- A reconciliation step that catches dialect drift
- Confidence that the time spent on coordination is less than the time saved by parallelism

Without those, serial is defensible. With them, it's the slower choice.
