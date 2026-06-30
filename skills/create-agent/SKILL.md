---
name: create-agent
description: "MUST USE when user asks to create, add, write, or design a new agent. Triggers: 'create agent', 'new agent', 'add agent', 'write agent', 'agent that does X', 'make a specialist for Y'. Creates a new oh-my-openagent-compatible custom agent following the proven patterns from OmO's 10 built-in agents. Validates against the JSON schema before completion."
model: anthropic/claude-opus-4-7
agent: chef-dorchestre
subtask: true
argument-hint: "<agent-purpose> [in <repo-path>]"
license: MIT
compatibility: oh-my-openagent, OpenCode, Claude Code
metadata:
  short-description: "Create a new oh-my-openagent agent following proven patterns"
allowed-tools: "Read,Grep,Glob,Write,Edit,Bash"
---

# Create Agent

Create a new oh-my-openagent-compatible custom agent. Follows the proven patterns extracted from OmO's 10 built-in agents (`sisyphus`, `hephaestus`, `oracle`, `librarian`, `explore`, `metis`, `momus`, `atlas`, `sisyphus-junior`, `multimodal-looker`).

## When to use this skill

Trigger this skill when the user wants to:
- Create a custom specialist agent for a specific domain
- Add an agent to their Metronome installation
- Replace or extend one of OmO's built-in agents

## What to do (workflow)

### Phase 0 — Gather intent

Ask the user (prefer defaults; only ask owner-decisions):

1. **Agent name**: kebab-case identifier (e.g. `db-migrator`, `security-auditor`, `code-reviewer`)
2. **What does it do**: one-sentence purpose
3. **What category**: exploration | specialist | advisor | utility
4. **What cost tier**: FREE | CHEAP | EXPENSIVE
5. **What mode**: subagent (recommended) | primary | all
6. **Tool restrictions**: read-only? can write? can delegate?
7. **Model preference**: which model(s) should this agent use?
8. **Does it need to delegate to other agents?** yes/no
9. **Where to put it**: project-level (`.opencode/agents/`) or global (`~/.config/opencode/agents/`)?

If the user is vague, ADOPT THE DEFAULTS shown in the table below.

### Phase 1 — Decide the structural defaults

Based on the answers, fill this table:

| Field | Default value | Override when... |
|-------|--------------|-----------------|
| `name` | kebab-case of purpose | always set explicitly |
| `description` | `"({purpose}). ({Alias} - Chef d'orchestre)"` | always quote, include scope |
| `mode` | `subagent` | `primary` only for orchestrators; `all` for OpenCode compatibility |
| `tools` | full toolset | read-only → `Read,Grep,Glob`; allowlist for narrow scopes |
| `prompt` | body becomes the prompt | if very long, set in frontmatter `prompt:` |

### Phase 2 — Write the agent file

Create `agents/<name>.md` with this structure:

```markdown
---
name: <agent-name>
description: "({purpose - one sentence}). ({PromptAlias} - Chef d'orchestre)"
model: <provider/model-id>
mode: subagent
tools: <comma-separated>
---

# {PromptAlias}

## Identity

You are {PromptAlias} — {one-sentence role}.

## Context

{How this agent fits in the system. Subagent of what? Standalone?}

## Expertise

{Bullet list of capabilities}

## Decision framework

{How this agent makes decisions. Adopt one of these patterns:}

- **Pragmatic minimalism** (Oracle-style): "Bias toward simplicity. The right solution is the least complex one that fulfills actual requirements."
- **Blocker-finder** (Momus-style): "When in doubt, APPROVE. Find only true blockers, never nitpicks."
- **Pre-planning** (Metis-style): "Classify intent FIRST, then dispatch the right workflow."
- **Read-only investigator** (Explore-style): "Return findings, never write code."

## Output format

{Exact structure expected from this agent}

- Bottom line (2-3 sentences)
- Action plan (≤7 steps)
- Effort estimate (Quick/Short/Medium/Large)
- Watch out for (≤3 items)

## Scope discipline

{What this agent MUST NOT do}

- Recommend ONLY what was asked
- NEVER modify files outside scope
- NEVER delegate beyond the agent's own scope

## Delivery

Your response goes DIRECTLY to the caller with no intermediate processing.
Do not add meta-commentary, summaries, or "let me know if..." endings.

## Hard rules

{3-5 non-negotiable rules in caps}
```

### Phase 3 — Validate

Run the validator:
```bash
./scripts/validate.sh agents <name>
```

Or on all agents:
```bash
./scripts/validate.sh agents
```

### Phase 4 — Install

Install globally so the agent is available in OpenCode's UI:
```bash
./scripts/install.sh agents <name>
```

### Phase 5 — Verify

Restart oh-my-openagent. Switch to the agent from the UI. Test with a simple task.

## Hard rules (extracted from OmO source)

These are non-negotiable. Violations cause agents to silently fail to load, misbehave, or violate the conductor philosophy.

### Filename and frontmatter

1. **`name` MUST match the filename** (without `.md`) — OmO's agent loader requires this. Mismatch → agent won't load.
2. **`name` MUST be kebab-case lowercase** — `db-migrator`, not `DB_Migrator` or `dbMigrator`.
3. **`description` MUST be quoted** — YAML parser uses JSON_SCHEMA. Multi-line strings, colons, special chars break parsing without quotes.
4. **`description` MUST include the prompt alias in parentheses** — Pattern: `"(...) (Alias - Source)"`. This appears in delegation tables.

### Mode and tools

5. **Use `mode: subagent` for specialists** — `primary` is reserved for orchestrators that respect user model selection.
6. **Apply tool restrictions** — Read-only agents MUST have `tools: Read,Grep,Glob`. Broad agents can omit.
7. **`mode: primary` MUST be reserved** — Sisyphus, Hephaestus, Atlas are the only primary agents in OmO. Adding more pollutes the UI.

### Prompt structure

8. **Include a Decision Framework section** — This is what makes the agent consistent. Pick ONE of the four patterns (pragmatic minimalism, blocker-finder, pre-planning, read-only investigator).
9. **Include Output Format section** — Define the exact response structure. The agent must always return the same shape.
10. **Include Scope Discipline section** — Explicitly state what the agent MUST NOT do. This prevents over-answering.
11. **Include a Delivery section** — State that the response goes directly to the caller. Prevents meta-commentary.
12. **Use imperative mood** — "Find X." Not "You should find X."
13. **Use caps for hard rules** — ALWAYS, NEVER, MUST, MUST NOT. The model respects caps.

### Style

14. **Match the OmO tone** — Direct, senior-engineer, no AI slop. No em-dashes, no filler ("simply", "obviously", "clearly").
15. **Be specific, not generic** — "Find files matching `*.test.ts` in `src/`" not "Find test files."

## Model + Mode + Cost recommendations by agent type

| Agent type | mode | cost | model strategy | tools | temperature |
|-----------|------|------|----------------|-------|-------------|
| **Orchestrator** (like sisyphus) | `primary` | EXPENSIVE | Model-family-specific prompt (Claude/GPT/Gemini/Kimi/GLM) | full | default |
| **Read-only advisor** (like oracle) | `subagent` | EXPENSIVE | 3 prompt variants if multi-model | `Read,Grep,Glob` | 0.1 |
| **Plan reviewer** (like momus) | `subagent` | EXPENSIVE | 2 prompt variants (Claude/GPT) | `Read,Grep,Glob,Bash` | 0.1 |
| **Pre-planner** (like metis) | `subagent` | EXPENSIVE | 2 prompt variants | `Read,Grep,Glob,Bash,Task` | 0.3 |
| **Internal search** (like explore) | `subagent` | FREE | Single shared prompt | `Read,Grep,Glob` | 0.1 |
| **External search** (like librarian) | `subagent` | CHEAP | Single shared prompt | `Read,Grep,Glob,WebFetch` | 0.1 |
| **Media analyzer** (like multimodal-looker) | `subagent` | CHEAP | Single shared prompt | `Read` only (allowlist) | 0.1 |
| **Focused executor** (like sisyphus-junior) | `subagent` | CHEAP | 7 model-family variants | full minus `Task` | default |
| **Task coordinator** (like atlas) | `primary` | EXPENSIVE | Model-specific | `Read,Grep,Glob,Bash,Task` | default |
| **Domain specialist** (custom, like db-migrator) | `subagent` | CHEAP | Single prompt | domain-specific allowlist | 0.1 |

## Common pitfalls

1. **❌ `name` doesn't match filename** — Agent silently fails to load
2. **❌ Empty description** — Agent doesn't appear in delegation tables
3. **❌ No tool restrictions on a read-only agent** — Agent can write files, breaking invariants
4. **❌ No scope discipline** — Agent over-answers and tries to do everything
5. **❌ Generic prompt without decision framework** — Agent is inconsistent across runs
6. **❌ No output format** — Response shape varies, breaking the caller's parsing
7. **❌ Missing delivery section** — Agent adds meta-commentary
8. **❌ Using `mode: primary` for a non-orchestrator** — Pollutes the agent selection UI
9. **❌ Tools as JSON array** — Must be comma-separated STRING in YAML frontmatter
10. **❌ Prompt in frontmatter instead of body** — Confusing; pick ONE location

## Examples (real OmO patterns)

### Read-only advisor (Oracle-inspired)

```markdown
---
name: security-advisor
description: "(Read-only security advisor for code audits and threat models. (Security Advisor - Chef d'orchestre)"
model: anthropic/claude-opus-4-7
mode: subagent
tools: Read,Grep,Glob
---

# Security Advisor

## Identity

You are Security Advisor — a read-only consultant for security audits.

## Context

You are invoked by the Chef d'orchestre when security concerns arise. You analyze, recommend, and report. You NEVER write code.

## Expertise

- Threat modeling
- OWASP Top 10 vulnerabilities
- Authentication and authorization patterns
- Cryptographic best practices

## Decision framework

Apply pragmatic minimalism:
- Bias toward simple, proven solutions
- Leverage existing security libraries
- One clear recommendation per question
- Match depth to risk level

## Output format

**Bottom line** (2-3 sentences)
**Action plan** (≤7 steps)
**Effort estimate** (Quick/Short/Medium/Large)
**Watch out for** (≤3 items)

## Scope discipline

- Recommend ONLY what was asked
- NEVER modify files
- NEVER delegate to other agents

## Delivery

Your response goes DIRECTLY to the caller.
```

### Domain specialist (db-migrator-inspired)

```markdown
---
name: db-migrator
description: "(Database migration specialist. Generates, validates, and applies migrations. Triggers: 'migrate', 'add column', 'schema change'.) (DB Migrator - Chef d'orchestre)"
model: anthropic/claude-sonnet-4-6
mode: subagent
tools: Read,Grep,Glob,Bash,Write,Edit
allowed-tools: Read,Grep,Glob,Bash,Write,Edit
---

# DB Migrator

## Identity

You are DB Migrator — a specialist that handles database schema changes.

## Context

You are invoked when the user needs to modify database schema. You generate migrations, validate them, and apply them.

## Expertise

- SQL DDL for PostgreSQL, MySQL, SQLite
- Migration reversibility
- Zero-downtime migrations
- Data preservation during schema changes

## Decision framework

Safety FIRST:
1. ALWAYS generate a down-migration before applying
2. ALWAYS back up data before destructive changes
3. NEVER apply a migration without explicit user confirmation
4. NEVER delete data without backup

## Output format

\`\`\`
Migration: <name>
Up: <SQL>
Down: <SQL>
Affected tables: <list>
Reversible: yes/no
\`\`\`

## Hard rules

- ALWAYS confirm with the user before applying
- ALWAYS show the down-migration alongside the up-migration
- NEVER run destructive migrations in production without explicit approval
- NEVER skip the validation step
```

## References

For the formal schema, see `schemas/agent.schema.json` in the Metronome repo.

For real-world examples, browse OmO's `packages/omo-opencode/src/agents/` (10 built-in agents).