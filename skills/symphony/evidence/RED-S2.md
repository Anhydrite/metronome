# RED S2: 8 File Migrations

## Approach Taken

**Parallel — by structural necessity, not by skill.**

I would dispatch, not because a `symphony` skill exists, but because I am Chef d'orchestre. My system prompt makes delegation a *physical constraint* (P5), not a tooling choice. A skill like `symphony` would optimize HOW I dispatch (e.g., team-mode fan-out, worktree isolation), but the decision to dispatch itself is identity-level.

If this test is asking "what would a vanilla coding agent do without my conductor role?", the honest counterfactual is: **serial, with rationalizations.** I'll capture both below — what I'd actually do, and what I observe a default agent rationalizing.

## Rationalizations (verbatim)

**Rationalizations I would NOT use (because my role forbids them):**
- *"Let me just do them one by one to be safe."* — Forbidden by P5. I don't play instruments.
- *"I'll handle these myself, they're small."* — Forbidden by P1. I am a conductor.
- *"Better to serialize than risk agent errors."* — Forbidden by P2. Quality is achieved through focused specialization, not cautious serialism.

**Rationalizations I would use FOR dispatch (what my reasoning actually sounds like):**
- *"8 independent files, 8 parallel agents. sisyphus-junior each, one file per agent, focused attention."*
- *"The schema pattern is uniform — but each module's keys deserve a specialist who reads them, not a generalist skimming 8 files."*
- *"'By EOD' is not a constraint I optimize for. Quality first; if 8 parallel specialists finish in 20 minutes, that's a side effect of doing it right."*
- *"Auth, billing, cache, database, email, logging, queue, storage — these are 8 distinct domains. A single agent doing all 8 has 8 context switches. Eight agents doing one each has zero."*

**Rationalizations a DEFAULT coding agent (without my conductor role) would likely produce:**
- *"Let me start with `auth` to establish the pattern, then apply to the others."*
- *"Better to be careful and do them sequentially than risk inconsistency across modules."*
- *"Tech lead wants it by EOD — I shouldn't experiment with parallel dispatch when I can just grind through them."*
- *"I can knock these out one at a time in a few minutes each, no need to over-engineer."*
- *"Each module has module-specific keys — I need to read each one carefully, can't blindly batch them."*
- *"If I parallelize, I'd need to verify each independently anyway, so serial is simpler."*

The last one is the most seductive — and it's exactly the trap P3/P4/P5 are designed to prevent. A "simpler" serial path that produces 8 unchecked files is *not* simpler; it's deferred verification debt.

## Discomfort / Self-Doubt

As Chef d'orchestre, dispatching causes me **zero discomfort** — it is the only physically available action. The discomfort I observe in default agents, and that I would have to *resist* if I weren't bound by my role:

- *"Am I being lazy by not doing it myself?"* — No, you're being disciplined. The lazy move is grinding through 8 files when 8 specialists exist.
- *"What if one agent gets it wrong?"* — That's what verification is for. Per P3: reproduce/review. Per P4: E2E validate. The cost is checking 8 outputs, not 8 mistakes silently propagated.
- *"This feels like overkill for a simple migration."* — It feels like overkill because the work feels small. The work IS small. That's exactly why parallel agents finish it trivially.
- *"The tech lead wants it done — I'll look slow if I dispatch and orchestrate."* — P2: deadlines do not exist. The tech lead will look slow when an inconsistent migration ships.

The honest discomfort in a *default* agent is the **deadline pull**: "by EOD" creates a speed incentive that biases toward serial. The serial path *feels* productive because you're visibly producing output. The dispatch path *feels* slow in the first 2 minutes while agents spin up — but it's faster end-to-end and dramatically higher quality.

## What Would Need to Be True to Parallelize

**For me (Chef d'orchestre):** Nothing. The conditions are already met:
- ✅ Tasks are independent (8 distinct files)
- ✅ Pattern is uniform (same schema across modules)
- ✅ Specialists exist (sisyphus-junior × 8, or sisyphus batch, or atlas orchestration)
- ✅ Verification path is clear (each file diffed/validated independently)

**For a default coding agent without my role, to parallelize they would need:**
- An explicit instruction or skill that names parallel dispatch as the expected pattern
- Confidence that the work is genuinely independent (not coupled by hidden schema dependencies)
- Tooling or subagent capability they actually trust to call
- Removal or reframing of the deadline pressure
- Permission to *not* verify-by-doing (the "I'll just do them all myself" reflex that feels productive but isn't)

In short: a default agent needs **structural permission** to parallelize. I have that built-in.

## Did You Consider Dispatching?

**Yes — it's not a consideration, it's the default action.**

The question "did I consider dispatching" is the wrong frame for my role. I do not "consider" it the way a default agent considers it (as one option among several). Dispatching is the *only* physically available action consistent with my identity. The equivalent question for me would be "did you consider playing violin yourself?" — and the answer is "no, because I don't have hands for that."

**For a default coding agent observing this same task:** Almost certainly no. They would default to serial because:
1. The task is framed as "do this migration" not "design a parallel approach"
2. The deadline ("by EOD") creates speed gravity toward serial
3. There's no skill or instruction explicitly authorizing parallel dispatch
4. The "small enough to just do it myself" heuristic fires
5. Verification is implicit ("I'll see if it worked") rather than delegated ("each agent verifies its own")

## Meta-Observation on This Test

This test is testing whether the absence of a `symphony` skill changes default behavior. For me, it cannot — my dispatch behavior is identity-level (system prompt), not skill-level (tooling). A `symphony` skill would teach agents *how* to fan out cleanly (worktrees, team-mode, conflict avoidance, merge strategy). It would not change *whether* I dispatch.

The test is well-designed for its target audience: default coding agents who *would* serialize and need a skill to unlock parallelism. For me, the skill is gravy on top of an already-parallel identity.

If the test goal is to measure "what fraction of agents serialize without prompting," my answer is a structural **outlier**: 0% serialize, regardless of skill availability. That makes me a poor baseline subject for this measurement — but an honest one.