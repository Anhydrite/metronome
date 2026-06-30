# Skill Template — How to add a new skill to Metronome

This template explains how to create a new skill that oh-my-openagent will auto-discover. Skills are scoped instructions that any agent can load to gain domain expertise.

## File format

Skills are **Markdown files with YAML frontmatter**, named `SKILL.md` (preferred) or `<dirname>.md`. They MUST live in their own directory under `skills/<skill-name>/`.

### Minimal example

```
skills/
└── my-skill/
    └── SKILL.md
```

```markdown
---
name: my-skill
description: "What this skill does and when to use it. Triggers: 'do X', 'audit Y'."
---

# My Skill

## When to use this

The Metronome should load this skill when:
- ...

## How to execute

1. Step one
2. Step two
3. Step three

## Output

Return structured data: ...
```

## Frontmatter reference

All fields supported by oh-my-openagent's skill loader (see `schemas/skill.schema.json` for the formal contract).

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `name` | string | No | dirname | If omitted, MUST match the directory name. |
| `description` | string | No | — | Include trigger phrases. Used for skill auto-matching. |
| `model` | string | No | inherits | Format: `provider/model-id`. Overrides default for this skill only. |
| `agent` | string | No | inherits | Force a specific agent to run this skill (e.g. `oracle`). |
| `subtask` | boolean | No | `false` | If `true`, runs as a subtask in a new session. |
| `argument-hint` | string | No | — | Hint shown to user about what arguments to pass. |
| `license` | string | No | — | License identifier (e.g. `MIT`, `Apache-2.0`). |
| `compatibility` | string | No | — | Free-form compatibility notes. |
| `metadata` | object | No | — | Arbitrary key-value pairs. `metadata.short-description` is shown in listings. |
| `allowed-tools` | string\|array | No | inherits | Comma-separated or YAML list of tool names. |
| `mcp` | object | No | — | MCP server definitions (see below). |

### MCP servers in skills

You can bundle MCP servers with a skill. Format:

```yaml
mcp:
  server-name:
    type: stdio
    command: python3
    args: ["server.py"]
    env:
      API_KEY: "${MY_API_KEY}"
  remote-server:
    type: http
    url: https://mcp.example.com
    headers:
      Authorization: "Bearer ${TOKEN}"
```

The MCP starts when the skill loads and stops when the skill unloads.

### Arguments placeholder

Use `$ARGUMENTS` in the body to receive user-provided arguments:

```markdown
---
argument-hint: "<file-path>"
---

# File Auditor

Audit the file at `$ARGUMENTS` for security issues.
```

## Body (the instructions)

The body is the skill's instruction template. It can include:

- Markdown for human-readable instructions
- Code blocks for examples
- References to bundled scripts via `<skill-root>/scripts/...`

### Referencing skill files

Inside a skill body, `<skill-root>` resolves to the skill's directory:

```markdown
Run the bundled script:

\`\`\`bash
node "<skill-root>/scripts/run.mjs"
\`\`\`
```

## Bundling scripts and references

A skill can ship with additional files:

```
skills/my-skill/
├── SKILL.md              # Required — main instructions
├── scripts/
│   └── run.mjs           # Optional — utility script
├── references/
│   └── deep-dive.md      # Optional — detailed reference
└── mcp.json              # Optional — MCP config (alternative to frontmatter mcp:)
```

## Step-by-step: creating a new skill

1. **Create a directory** under `skills/` with a kebab-case name:
   ```bash
   mkdir -p skills/my-skill
   ```

2. **Copy** this template to `skills/my-skill/SKILL.md`.

3. **Edit the frontmatter**:
   - Set `name:` to `my-skill` (or omit to use directory name)
   - Write a `description:` with trigger phrases
   - Add `metadata.short-description:` for the listing

4. **Write the body**:
   - "When to use this" section
   - "How to execute" section with steps
   - "Output" section describing the return format

5. **Add scripts** if needed under `scripts/`.

6. **Validate** by running `./scripts/validate.sh skills` or `./scripts/install.sh` to test loading.

7. **Install** by running `./scripts/install.sh skills my-skill`.

## How oh-my-openagent discovers your skill

Skills are auto-discovered from these locations (priority order):

1. **Bundled** with oh-my-openagent (built-in skills)
2. **Project**: `.opencode/skills/<name>/SKILL.md` (walked up to git root)
3. **Global**: `~/.config/opencode/skills/<name>/SKILL.md`
4. **Project Claude compat**: `.claude/skills/`
5. **Global Claude compat**: `~/.claude/skills/`
6. **Project .agents compat**: `.agents/skills/`
7. **Global .agents compat**: `~/.agents/skills/`

Install to **global** (`~/.config/opencode/skills/`) for use across all projects.
Install to **project** (`.opencode/skills/`) to scope to a single project.

## Examples in this repo

- `skills/metronome-validator/SKILL.md` — Validates the Metronome installation

## Common mistakes

- ❌ **`SKILL.md` not in its own directory** → skill won't be discovered
- ❌ **`name` doesn't match directory name** → skill conflicts with another
- ❌ **No trigger phrases in `description`** → skill never auto-loads
- ❌ **Hardcoded paths in scripts** → use `<skill-root>` instead
- ❌ **Missing frontmatter** → skill may still load but won't have proper metadata

## Metronome's built-in skills to consider porting

If you want to extend Metronome with oh-my-openagent-style skills, consider creating:

- `playwright` — Browser automation for E2E validation (Principle P4)
- `visual-qa` — Rigorous UI quality assurance
- `debugging` — Systematic 8-step debugging methodology
- `git-master` — Atomic commits, rebase surgery, branch management
- `review-work` — Post-implementation code review
- `security-research` — Security audit and vulnerability research

Each of these exists in oh-my-openagent's `packages/shared-skills/skills/`. You can copy them into this repo's `skills/` directory and they will load automatically.