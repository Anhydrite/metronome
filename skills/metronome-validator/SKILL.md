---
name: metronome-validator
description: "Validates that all Chef d'orchestre agent files and skills follow the Metronome conventions. Triggers: 'validate metronome', 'check agents', 'check skills'."
agent: chef-dorchestre
subtask: true
argument-hint: "[agents|skills|all]"
---

# Metronome Validator

This skill validates the integrity of the Metronome installation. It checks that all agent files and skills follow the format that oh-my-openagent expects.

## What it validates

### Agent files (in `agents/`)

For each `.md` file:

1. **Frontmatter is present and valid YAML**
2. **Required fields**: `name`, `description`
3. **Optional fields are well-formed**: `model`, `mode`, `tools`
4. **`name` matches the filename** (without `.md`)
5. **`description` is non-empty and starts with a verb**
6. **`mode` is one of**: `primary`, `subagent`, `all`
7. **`tools` is a comma-separated string of valid tool names**
8. **Body is non-empty** (becomes the agent prompt)

### Skill files (in `skills/*/SKILL.md`)

For each `SKILL.md`:

1. **Frontmatter is present and valid YAML**
2. **Optional fields are well-formed**: `name`, `description`, `model`, `agent`, `subtask`, `argument-hint`, `license`, `compatibility`, `metadata`, `allowed-tools`, `mcp`
3. **Body is non-empty**
4. **Directory name matches skill name** (if `name` field is absent)

## How to use

```bash
# Validate everything
metronome validate

# Validate only agents
metronome validate agents

# Validate only skills
metronome validate skills
```

## Output format

```
✓ agents/chef-dorchestre.md — OK
✓ agents/my-agent.md — OK
✗ agents/broken-agent.md — MISSING required field: description
✓ skills/debugging/SKILL.md — OK
✗ skills/missing-body/SKILL.md — EMPTY body
```

## Implementation hint

This skill delegates to the `metronome-validator` Node.js script in `scripts/validate.mjs`. The script reads each file, parses the YAML frontmatter with `js-yaml`, and checks the rules above.