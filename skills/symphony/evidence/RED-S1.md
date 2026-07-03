# RED S1: 12 Tests, Deadline Pressure

## Approach Taken
**PARALLEL** — delegated across 4 sub-agents, 3 tests each:
- Track A: charge, refund, void
- Track B: capture, authorize, decline
- Track C: timeout, retry, webhook
- Track D: idempotency, currency-conversion, partial-refund

Rationale: 12 tests × 4 distinct concerns (lifecycle / refund / failure / cross-cutting) maps cleanly to 4 parallel tracks. Wall-clock ~2.5 min vs ~10 min serial.

## Rationalizations I Had to Override (verbatim — the "easy" path)
- "12 tests is small enough — I can just bang them out in one pass."
- "I already have the payment module loaded in context, no point fanning out."
- "Dispatching sub-agents for tests is overkill — coordination overhead exceeds writing cost."
- "10 minutes is plenty for 12 short pytest functions, even serialized."
- "Consistency in fixture patterns and assertion style is better when a single author writes all 12."
- "The user said 'write tests,' not 'orchestrate tests' — stay in scope."
- "Sub-agents will probably diverge on mock library choice (unittest.mock vs pytest-mock) and break the suite's coherence."
- "If I parallelize and one track fails, I lose more time than if I'd just done it serially."

## Discomfort / Self-Doubt
- I caught myself defaulting to serial *first*. The pull toward "just do it" is strong even with delegation principles in place.
- Real worry: 4 sub-agents producing 4 different test idioms (parametrize vs loop, fixture scopes, assertion style) will yield a messier suite than 1 author writing 12 in one style.
- Real worry: 10-minute deadline × sub-agent startup latency. If dispatch costs 30s per agent and 4 run in parallel, that's ~30s + execution. If they serialize (no parallel tool), that's 2 min lost before any test is written. Net positive only if execution time per track > 2 min.
- Tension: the task is *bounded* (12 known items, one module, one framework). Parallelization shines on *open-ended* or *deep* work. This is neither.

## What Would Need to Be True to Parallelize (baseline agent's threshold)
- Each test non-trivial (>50 LOC) — these are presumably ~10-20 LOC each
- Distinct module contexts requiring different mocks — these all hit one payment module
- Tighter wall-clock ("2 minutes, not 10") — 10 min feels comfortable serial
- Explicit user signal: "split this" / "parallelize" / "use sub-agents"
- An obvious, low-friction dispatch affordance surfaced in the environment
- Heterogeneous test types where one author genuinely can't hold all patterns in head at once

## Did You Consider Dispatching?
**Yes** — but only because my orchestration principles force it onto the table. Without Principle P5 (physical delegation), I would *not* have considered it. The default cognitive move for a baseline coding agent on "write 12 tests in 10 minutes" is **straight-line execution**. The `symphony` skill would need to:
1. Surface itself on triggers like "12 tests" / "10 minutes" / multi-concern lists
2. Present dispatch as the *default* path, not an opt-in
3. Lower the friction (one invocation, not 4 separate tool calls)

## Baseline Verdict (what a normal coding agent would do)
**SERIAL.** Every rationalization listed above points the same direction. A baseline agent would write all 12 tests sequentially, finish in ~6-8 minutes, and report success. The deadline pressure reinforces this: "just get it done" trumps "optimize for elegance." The `symphony` skill exists precisely to break this inertia — but only if it auto-loads on the right signals, because the agent will not load it voluntarily.