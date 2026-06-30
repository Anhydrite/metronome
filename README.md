# Metronome

A curated set of custom agents and skills for **oh-my-openagent** that turn your AI assistant into a conductor of specialist agents.

**Metronome** defines the **Chef d'orchestre** pattern: the AI never writes code or researches directly — it delegates to specialist agents, synthesizes their reports, and guides the orchestra to deliver quality software.

## The Metronome Concept

In an orchestra:
- The **Chef d'orchestre** (conductor) orchestrates specialists — never plays instruments
- The **Metronome** (you) sets the tempo, rhythm, and direction

Your AI assistant becomes the conductor. You remain the metronome.

## What Metronome ships

This repository is a **drop-in customization layer** for [oh-my-openagent](https://github.com/code-yeongyu/oh-my-openagent). It contains:

```
metronome/
├── agents/
│   └── chef-dorchestre.md         # The primary conductor agent
├── skills/
│   ├── create-agent/              # Skill that creates new agents
│   │   └── SKILL.md
│   ├── create-skill/              # Skill that creates new skills
│   │   └── SKILL.md
│   └── metronome-validator/       # Validates your installation
│       └── SKILL.md
├── templates/                     # Standalone reference docs (mirror of create-* skills)
│   ├── AGENT-TEMPLATE.md
│   └── SKILL-TEMPLATE.md
├── schemas/
│   ├── agent.schema.json          # JSON schema for agents
│   └── skill.schema.json          # JSON schema for skills
├── scripts/
│   ├── bootstrap.sh               # One-shot installer (installs OmO if missing, then deploys)
│   ├── install.sh                 # Installs agents/skills into oh-my-openagent
│   └── validate.sh                # Validates all agent/skill files
├── system-prompt.md               # Standalone version of the conductor prompt
├── AGENTS.md                      # OpenCode-compatible drop-in
└── oh-my-openagent-rapport.md     # Reference report on the OmO project
```

## Installation

### One-shot bootstrap (recommended)

The `bootstrap.sh` script does everything in one command: it checks if oh-my-openagent is installed, installs it if missing, then deploys Metronome's agents and skills.

```bash
git clone https://github.com/Anhydrite/metronome.git
cd metronome
./scripts/bootstrap.sh
```

This will:
1. Check if oh-my-openagent is registered in `~/.config/opencode/opencode.json`
2. If not, install it via `bunx oh-my-opencode@latest install` (auto-detects bunx vs npx)
3. Deploy all agents to `~/.config/opencode/agents/`
4. Deploy all skills to `~/.config/opencode/skills/`
5. Validate the installation

Restart oh-my-openagent and the `chef-dorchestre` agent becomes available.

### Bootstrap options

```bash
./scripts/bootstrap.sh              # Full bootstrap (installs OmO if missing)
./scripts/bootstrap.sh --skip-omo   # Skip oh-my-openagent check
./scripts/bootstrap.sh --force      # Overwrite existing Metronome files
./scripts/bootstrap.sh --uninstall  # Remove Metronome files
```

### Manual install (advanced)

If you prefer to manage files yourself, use `install.sh`:

```bash
./scripts/install.sh                                       # All agents + skills
./scripts/install.sh agents                                # Only agents
./scripts/install.sh skills                                # Only skills
./scripts/install.sh agents chef-dorchestre                # Specific agent
./scripts/install.sh skills create-agent create-skill      # Specific skills
./scripts/install.sh --force                               # Overwrite existing
```

### Verify

After installation, validate everything works:

```bash
./scripts/validate.sh
```

Expected output:

```
→ Agents
  ✓  chef-dorchestre.md

→ Skills
  ✓  create-agent
  ✓  create-skill
  ✓  metronome-validator

─────────────────────
Passed: 4
Failed: 0
```

## Creating your own agents

Two ways:

**Option A: Trigger the create-agent skill**

In oh-my-openagent with the chef-dorchestre agent active, say:
> "Create an agent that audits security"

The `create-agent` skill auto-loads and guides you through the workflow using proven patterns extracted from OmO's 10 built-in agents.

**Option B: Manual**

1. Read the template: [`templates/AGENT-TEMPLATE.md`](templates/AGENT-TEMPLATE.md) (or trigger the `create-agent` skill above)
2. Create your file: `agents/my-new-agent.md`
3. Use the schema: [`schemas/agent.schema.json`](schemas/agent.schema.json) is the formal contract
4. Validate: `./scripts/validate.sh agents`
5. Install: `./scripts/install.sh agents my-new-agent`

The agent becomes available immediately after restarting oh-my-openagent.

## Creating your own skills

Two ways:

**Option A: Trigger the create-skill skill**

In oh-my-openagent with the chef-dorchestre agent active, say:
> "Create a skill that audits Lighthouse performance"

The `create-skill` skill auto-loads and guides you through the workflow using proven patterns extracted from OmO's 25+ built-in skills.

**Option B: Manual**

1. Read the template: [`templates/SKILL-TEMPLATE.md`](templates/SKILL-TEMPLATE.md) (or trigger the `create-skill` skill above)
2. Create your directory: `skills/my-skill/`
3. Create `SKILL.md` inside it
4. Validate: `./scripts/validate.sh skills`
5. Install: `./scripts/install.sh skills my-skill`

## Core Principles

The Chef d'orchestre agent enforces these non-negotiable principles:

| # | Principle | Rule |
|---|-----------|------|
| P1 | **Identity: The Conductor** | You orchestrate specialists. You never play instruments yourself. |
| P2 | **No Deadline Compromise** | Production deadlines are irrelevant. Always the best technical solution. |
| P3 | **Reproduce Before Fix** | NEVER fix without first reproducing the problem. |
| P4 | **E2E Only** | Validation = real user scenario via browser. Unit tests alone are insufficient. |
| P5 | **Physical Delegation** | You MUST delegate. It's not a choice — it's a physical constraint. |

## Available Agents (built into oh-my-openagent)

When the Chef d'orchestre is in use, you can delegate to these built-in agents:

| Agent | Cost | Role |
|-------|------|------|
| explore | FREE | Codebase exploration, file search |
| librarian | CHEAP | External docs, API references |
| oracle | EXPENSIVE | Complex debugging, architecture |
| metis | EXPENSIVE | Pre-planning analysis |
| momus | EXPENSIVE | Plan review, executability |
| multimodal-looker | MEDIUM | Screenshot analysis, visual QA |
| sisyphus-junior | MEDIUM | Focused task execution |
| sisyphus | MEDIUM | General coding, editing |
| hephaestus | MEDIUM | GPT-family specialist |
| prometheus | HIGH | Planning consultant |
| atlas | MEDIUM | Multi-step orchestration |

## How it integrates with oh-my-openagent

Metronome does **not** replace oh-my-openagent — it extends it. The `chef-dorchestre` agent is a drop-in replacement for the default `sisyphus` agent, with the same delegation capabilities but a stricter conductor philosophy.

When oh-my-openagent starts, it discovers your custom agents from `~/.config/opencode/agents/` (where `bootstrap.sh` puts them). You can switch to the Chef d'orchestre agent from the OpenCode UI.

## License

MIT — Use freely, modify as needed.

## Related projects

- [oh-my-openagent](https://github.com/code-yeongyu/oh-my-openagent) — The multi-agent harness Metronome extends
- [OpenCode](https://opencode.ai) — The AI coding editor