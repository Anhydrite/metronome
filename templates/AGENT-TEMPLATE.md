# Agent Template — How to add a new agent to Metronome

This template explains how to create a new custom agent that lives inside oh-my-openagent. Drop the resulting file into the `agents/` directory of this repo, or directly into your `~/.config/opencode/agents/` directory.

## File format

Agents are **Markdown files with YAML frontmatter**. The filename (minus `.md`) MUST match the `name` field.

### Minimal example

```markdown
---
name: my-specialist
description: "What this agent does in one sentence. Triggers: 'do X', 'fix Y'."
model: anthropic/claude-sonnet-4-6
mode: subagent
---

# My Specialist

You are a specialist that does X very well.

## Rules

1. ...
2. ...

## Output format

Return structured reports with sections: Findings, Action Plan, Verification.
```

## Frontmatter reference

All fields supported by oh-my-openagent's agent loader (see `schemas/agent.schema.json` for the formal contract).

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `name` | string | **Yes** | filename | MUST match the filename (without `.md`). Lowercase, kebab-case. |
| `description` | string | **Yes** | — | One sentence. Include trigger phrases ("Triggers: 'foo', 'bar'"). |
| `model` | string | No | inherits | Format: `provider/model-id`. Examples: `anthropic/claude-opus-4-7`, `openai/gpt-5.5`. |
| `mode` | string | No | `subagent` | One of: `primary` (selectable in UI), `subagent` (callable only), `all` (both). |
| `tools` | string | No | all tools | Comma-separated tool whitelist. Examples: `"Read,Grep,Glob"` or `"Read,Grep,Glob,Bash"`. |
| `prompt` | string | No | body content | If set in frontmatter, OVERRIDES the body. Usually leave empty and put the prompt in the body. |

### Tools whitelist

Available tool names (from oh-my-openagent):

- **Read-only**: `Read`, `Grep`, `Glob`, `WebFetch`
- **Write**: `Write`, `Edit`, `ApplyPatch`
- **Execution**: `Bash`, `InteractiveBash`
- **Delegation**: `Task`, `CallOmoAgent`, `Skill`, `SkillMcp`
- **Session**: `SessionManager`, `Monitor`, `Slashcommand`
- **Media**: `LookAt`
- **Workflow**: `TodoWrite`, `TaskReminder`

To restrict an agent to read-only, set:

```yaml
tools: "Read,Grep,Glob"
```

## Body (the prompt)

Everything after the closing `---` of the frontmatter becomes the agent's system prompt. Write it as you would write any LLM system prompt:

- **Identity section** — Who is the agent?
- **Principles** — What rules must it follow?
- **Workflow** — How should it approach tasks?
- **Output format** — What structure should its responses have?
- **Constraints** — What must it never do?

## Naming conventions

- **Filename**: lowercase, kebab-case, descriptive. Example: `db-migrator.md`, `security-auditor.md`.
- **`name` field**: MUST match filename (without `.md`).
- **Description**: imperative mood. "Audits code for..." not "This agent audits...".

## Step-by-step: creating a new agent

1. **Copy** `agents/chef-dorchestre.md` to `agents/my-new-agent.md`.
2. **Edit the frontmatter**:
   - Change `name:` to `my-new-agent`
   - Change `description:` to describe what it does
   - Change `model:` if needed
   - Change `mode:` if needed (`primary` / `subagent` / `all`)
   - Adjust `tools:` to restrict access if needed
3. **Replace the body** with the new agent's system prompt.
4. **Validate** by running `metronome validate agents` (or by visually inspecting).
5. **Install** by running `./scripts/install.sh agents my-new-agent` or just `./scripts/install.sh` for all.

## Examples in this repo

- `agents/chef-dorchestre.md` — The primary conductor agent (mode: primary)
- (Add more examples here as you create them)

## How oh-my-openagent discovers your agent

When oh-my-openagent starts, it loads agents from these sources (in order):

1. Built-in agents (`sisyphus`, `hephaestus`, `oracle`, etc.) — hard-coded in TypeScript
2. `~/.claude/agents/*.md` — Claude Code compatibility
3. `.claude/agents/*.md` — project-level Claude Code compat
4. `~/.config/opencode/opencode.json` under `agents` key — inline config
5. `agent_definitions` paths in opencode.json — file references
6. Plugin-bundled agents (none for Metronome — we ship files, not code)

To make your agent visible **globally**, install to `~/.config/opencode/agents/`.
To make it visible **per-project**, install to `.opencode/agents/` in that project.

## Common mistakes

- ❌ **`name` doesn't match filename** → agent won't load
- ❌ **Empty `description`** → agent won't show up in UI listings
- ❌ **`mode: primary` for a subagent** → pollutes the agent selection UI
- ❌ **Tools as JSON array** → must be comma-separated string in YAML frontmatter
- ❌ **Prompt in frontmatter instead of body** → confusing; pick one location

## Extending the conductor pattern

To add a new agent that follows the Chef d'orchestre philosophy, include in its body:

```markdown
## Delegation Protocol

When the task is outside my scope, I delegate using the 6-section format:

1. **TASK** — Atomic goal
2. **EXPECTED OUTCOME** — Concrete deliverables
3. **REQUIRED TOOLS** — Tool whitelist
4. **MUST DO** — Requirements
5. **MUST NOT DO** — Prohibitions
6. **CONTEXT** — File paths, patterns, constraints
```

This keeps the orchestra coherent.