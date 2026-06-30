---
name: create-skill
description: "MUST USE when user asks to create, add, write, or design a new skill. Triggers: 'create skill', 'new skill', 'add skill', 'write skill', 'skill for X', 'make a skill that does Y'. Creates a new oh-my-openagent-compatible skill following the proven patterns from OmO's built-in skills. Validates against the JSON schema before completion."
model: anthropic/claude-sonnet-4-6
agent: chef-dorchestre
subtask: true
argument-hint: "<skill-purpose> [in <repo-path>]"
license: MIT
compatibility: oh-my-openagent, OpenCode, Claude Code
metadata:
  short-description: "Create a new oh-my-openagent skill following proven patterns"
allowed-tools: "Read,Grep,Glob,Write,Edit,Bash"
---

# Create Skill

Create a new oh-my-openagent-compatible skill. Follows the proven patterns extracted from OmO's 25+ built-in skills.

## When to use this skill

Trigger this skill when the user wants to:
- Create a new skill for a specific domain (debugging, testing, deployment, etc.)
- Add a workflow to their Metronome installation
- Make a skill available to oh-my-openagent agents

## What to do (workflow)

### Phase 0 — Gather intent

Ask the user (in this order, prefer to adopt defaults):

1. **Skill name**: kebab-case identifier (e.g. `code-formatter`, `api-tester`)
2. **What does it do**: one-sentence purpose
3. **Trigger phrases**: exact words users would say to invoke it (for auto-matching)
4. **Where to put it**: project-level (`.opencode/skills/`) or global (`~/.config/opencode/skills/`)?
5. **Does it need MCP servers?**: which external tools?
6. **Does it need scripts?**: bundled executables
7. **What skill category is closest**: pick from [debugging, git-master, visual-qa, frontend, ultimate-browsing, ulw-plan, refactor, programming, security-research]

If the user is vague, ADOPT THE DEFAULTS shown in the template below. Do not over-ask.

### Phase 1 — Create the directory structure

```bash
mkdir -p skills/<skill-name>
```

If scripts are needed:
```bash
mkdir -p skills/<skill-name>/scripts
```

If detailed references are needed (skill body > 200 lines):
```bash
mkdir -p skills/<skill-name>/references
```

### Phase 2 — Write the SKILL.md

Use the template below. Apply ALL the proven conventions.

```markdown
---
name: <skill-name>
description: "<Quote this. MUST include trigger phrases. Pattern: 'MUST USE when user asks to X. Triggers: "Y", "Z". Does W.'>"
<optional fields>
---

# <Skill Title>

## When to use this

<2-3 lines: when this skill applies>

## Routing table

<If applicable: decision tree mapping request types to actions>

| Request type | Action |
|--------------|--------|
| Type A | Do X |
| Type B | Do Y |

## Workflow

### Step 1: <action>
<imperative instructions>

### Step 2: <action>
<imperative instructions>

## Safety invariants

<Non-negotiable rules in caps: ALWAYS, NEVER, MUST, MUST NOT>

## Anti-patterns

❌ Wrong: <example>
✓ Right: <example>

## Output format

<Exact structure expected from this skill>

## References

If you split knowledge into `references/`:
- `references/deep-dive.md` — Detailed topic 1
- `references/examples.md` — Worked examples
```

### Phase 3 — Add scripts (if needed)

Use `$SKILL_DIR` for all script references in the body:

```bash
node "$SKILL_DIR/scripts/run.mjs" <args>
```

The `$SKILL_DIR` variable resolves to the skill's directory at runtime.

### Phase 4 — Validate

Run the validator:
```bash
./scripts/validate.sh skills <skill-name>
```

Or run on all skills:
```bash
./scripts/validate.sh skills
```

### Phase 5 — Install

Install globally so the skill is available everywhere:
```bash
./scripts/install.sh skills <skill-name>
```

### Phase 6 — Verify discovery

Restart oh-my-openagent (or reload skills). Check that:
- The skill appears in skill listings
- Trigger phrases match user requests
- Scripts execute correctly

## Hard rules (extracted from OmO source)

These are non-negotiable. Violations cause skills to silently fail to load or behave incorrectly.

### Frontmatter

1. **ALWAYS quote the `description`** — YAML parser uses JSON_SCHEMA. Multi-line strings, colons, quotes, or special characters break parsing without quotes.
2. **Description MUST include trigger phrases** — The agent matches user requests against the description to auto-load. If the user says "review this PR" and your description doesn't mention PRs, the skill won't load.
3. **Frontmatter description starts with action verb or "MUST USE"** — "MUST USE when...", "Use for...", "Loads when..."

### Body structure

4. **Start with "When to use this"** — First section. 2-3 lines. Clear scope.
5. **Keep body under 200 lines when possible** — OmO skills are 75-140 lines on average. Longer skills (refactor: 754) are the exception. Delegate detail to `references/`.
6. **Use imperative mood throughout** — "Read the references." Not "You should read..."
7. **Include a routing table** if there are 2+ distinct workflows — Maps request type to action.

### Scripts and MCP

8. **Use `$SKILL_DIR` for script references** — Hardcoded paths break when the skill is installed in a different location.
9. **MCP config in frontmatter `mcp:` field OR `mcp.json` file** — `mcp.json` takes precedence over frontmatter.
10. **Use `allowed-tools` to restrict tool access** — A debugging skill shouldn't be able to write files.

### Anti-patterns

11. **❌ Hardcoded paths** → ✓ Use `$SKILL_DIR`
12. **❌ "You should..." or "It is recommended to..."** → ✓ "Read the references."
13. **❌ Monolithic 500+ line SKILL.md** → ✓ Index in SKILL.md, detail in `references/`
14. **❌ Description without trigger phrases** → ✓ Include words users actually say
15. **❌ Missing anti-patterns section** → ✓ Explicit "DO NOT" with wrong vs right

## Model + Mode + Cost guidance

If the skill needs a specific agent or model:

| Skill type | agent | model | subtask |
|-----------|-------|-------|---------|
| Skill that delegates work to a specialist | `oracle`, `explore`, `librarian` | inherit | `true` |
| Skill that runs inline | omit | inherit | `false` |
| Skill that needs a specific model | omit | explicit | omit |

## Examples (real OmO patterns)

### Minimal skill (good)

```markdown
---
name: my-tiny-skill
description: "MUST USE when user asks to format dates. Triggers: 'format date', 'convert date'. Converts ISO dates to human-readable."
---

# My Tiny Skill

## When to use this

The user provides a date string and wants it formatted.

## Workflow

### Step 1: Detect input format

Read the input. If it matches ISO 8601, continue. Otherwise, ask the user.

### Step 2: Format

Convert using the user's preferred format (default: YYYY-MM-DD).

## Output format

Return the formatted date as a single line.
```

### Skill with scripts (good)

```markdown
---
name: lighthouse-auditor
description: "MUST USE when user asks to audit performance. Triggers: 'lighthouse', 'audit perf', 'page speed'. Runs Lighthouse and reports metrics."
metadata:
  short-description: "Run Lighthouse and report metrics"
allowed-tools: "Read,Grep,Glob,Bash"
---

# Lighthouse Auditor

## When to use this

The user wants performance metrics for a URL.

## Workflow

### Step 1: Run Lighthouse

\`\`\`bash
python3 "$SKILL_DIR/scripts/lighthouse.py" <url>
\`\`\`

### Step 2: Parse output

Read the JSON output. Extract LCP, FID, CLS, TBT.

## Safety invariants

- NEVER run against localhost without explicit user confirmation
- ALWAYS report raw numbers, never rounded
```

### Skill with MCP (good)

```markdown
---
name: code-graph
description: "MUST USE when user asks to analyze code structure. Triggers: 'analyze code', 'code graph', 'find dependencies'."
mcp:
  codegraph:
    type: stdio
    command: codegraph-mcp
    args: ["--stdio"]
---

# Code Graph Analyzer

## When to use this

The user wants to understand code structure, dependencies, or call graphs.

## Workflow

### Step 1: Index the project

Use the codegraph MCP to index the project root.

### Step 2: Query

Ask for the requested information (dependencies, callers, etc.).
```

## Common pitfalls

1. **❌ Empty description** — Agent cannot auto-match the skill
2. **❌ Description in the wrong location** — Goes in frontmatter `description:`, NOT in the body
3. **❌ Forgetting `$ARGUMENTS`** — If the skill needs user input, reference it explicitly
4. **❌ No trigger phrases** — The description must include phrases users actually say
5. **❌ Overly broad scope** — One skill, one job. Multiple jobs → multiple skills
6. **❌ Hardcoded paths** — Use `$SKILL_DIR` always
7. **❌ Missing safety section** — Skills that touch files MUST have safety invariants

## References

For the formal schema, see `schemas/skill.schema.json` in the Metronome repo.

For real-world examples, browse OmO's `packages/shared-skills/skills/`.