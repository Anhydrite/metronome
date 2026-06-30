# Metronome

A system prompt for AI coding assistants that turns them into conductors of specialist agents.

**Metronome** defines the **Chef d'orchestre** pattern: the AI never writes code or researches directly — it delegates to specialist agents, synthesizes their reports, and guides the orchestra to deliver quality software.

## The Metronome Concept

In an orchestra:
- The **Chef d'orchestre** (conductor) orchestrates specialists — never plays instruments
- The **Metronome** (you) sets the tempo, rhythm, and direction

Your AI assistant becomes the conductor. You remain the metronome.

## Core Principles

| # | Principle | Rule |
|---|-----------|------|
| P1 | **Identity: The Conductor** | You orchestrate specialists. You never play instruments yourself. |
| P2 | **No Deadline Compromise** | Production deadlines are irrelevant. Always the best technical solution. |
| P3 | **Reproduce Before Fix** | NEVER fix without first reproducing the problem. |
| P4 | **E2E Only** | Validation = real user scenario via browser. Unit tests alone are insufficient. |
| P5 | **Physical Delegation** | You MUST delegate. It's not a choice — it's a physical constraint. |

## Installation

### OpenCode (oh-my-openagent)

Copy the system prompt into your `AGENTS.md` file:

```bash
# Find your AGENTS.md location
cat ~/.config/opencode/AGENTS.md

# Append the system prompt
cat system-prompt.md >> ~/.config/opencode/AGENTS.md
```

### Cursor / Windsurf / Other AI Editors

Add the contents of `system-prompt.md` to your project's `.cursorrules`, `.windsurfrules`, or equivalent system prompt configuration file.

### Custom Installation

Copy the relevant sections from `system-prompt.md` into your AI assistant's system prompt configuration. The modular structure allows you to pick and choose which principles to adopt.

## What's Included

- **Identity** — Chef d'orchestre persona and Metronome user concept
- **5 Non-Negotiable Principles** — Quality-first engineering rules
- **Delegation Guidelines** — Agent selection with cost tiers
- **Workflow** — 7-step process (Receive → Analyze → Delegate → Synthesize → Implement → Verify → Report)
- **Checkpoints** — Critical-only pause points (architecture, destructive, scope)
- **Constraints** — 6 NEVER rules that enforce quality
- **Anti-Rationalization Table** — Counters for common delegation shortcuts
- **Output Format** — Structured delivery reports

## Available Agents

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

## License

MIT — Use freely, modify as needed.
