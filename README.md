# Metronome

An autonomous delivery pipeline that runs as a [maki](https://github.com/Anhydrite/maki) plugin.

You bring an intention. Metronome qualifies it into tasks, asks the questions that block work, and drives each task through implementation, checks, review, merge and deploy. You stay the metronome: you set the tempo, answer what only you can answer, and read the delivery report.

Metronome never writes code itself. It orchestrates five roles — qualifier, analyst, implementer, reviewer, deployer — each in its own session and git worktree, and it reports what the pipeline recorded, never what a model claimed.

## Installation

Requirements: `maki`, `git`, `gh` (authenticated), and `python3` for the validators.

```bash
git clone https://github.com/Anhydrite/metronome.git
cd metronome
./scripts/install.sh
```

The installer copies `maki/lua/` into `$MAKI_CONFIG_DIR` (default `$XDG_CONFIG_HOME/maki`, else `~/.config/maki`) and merges `init.lua` and `plugin.toml` without overwriting what you already have. Run `/reload` in maki, then bind a project:

```text
/metronome init
/metronome submit Add a CSV export to the orders page
```

`/metronome init` creates the project state, copies `config.toml` and the prompts, and asks for the model specs. `/metronome submit` starts qualification.

## Commands

All commands are subcommands of one `/metronome` dispatcher.

| Command | What it does |
| --- | --- |
| `/metronome init` | Ask the config questions, then bind the project (state, config, prompts). Use `--defaults` to accept every default, or `key=value` to answer. |
| `/metronome submit <intention>` | Qualify an intention into tasks. |
| `/metronome status [id]` | Show every task, or one task in detail. |
| `/metronome answer` | Open the pending question round. |
| `/metronome calibrate` | Generate `review-rules.md` from the repository. |
| `/metronome retry <id>` | Restart a failed task from its last stable phase. |
| `/metronome abandon <id>` | Archive a task. |
| `/metronome config [key=value ...]` | Show the project configuration, or update it in place. |
| `/metronome panel` | Open, close or toggle the live panel. |
| `/metronome resume` | Restart tasks interrupted by a reload. |
| `/metronome feedback <id>` | Rate a review's findings to calibrate the reviewer. |
| `/metronome on` | Natural-language routing: a plain request calls the matching tool. |
| `/metronome off` | Turn natural-language routing off. |

The same surface is exposed to the agent as eight tools: `metronome_submit`, `metronome_status`, `metronome_answer`, `metronome_retry`, `metronome_abandon`, `metronome_calibrate`, `metronome_config`, `metronome_panel`. `metronome_config` reads the config and, with `answers`, updates it in place — merged with the config on disk, so changing one model does not reset the checks or the merge/deploy policy.

### Natural-language mode

`/metronome on` makes the pipeline listen to plain requests. While it is on, a prompt hint evaluated before every run tells the agent to call the matching tool instead of answering in prose: "ajoute une tache export CSV" calls `metronome_submit`, "ou en est T-…" calls `metronome_status`, "abandonne T-…" calls `metronome_abandon`, and so on. A message that is not a Metronome request is answered normally. The flag lives in the project state directory, is read on every run, and `/metronome off` takes effect on the next turn. The mode refuses an unbound project: run `/metronome init` first, so the models, checks and merge/deploy policy are chosen rather than guessed. While it is on, the main session is also **guarded**: `write`, `edit` and `bash` are refused, so the agent cannot bypass the pipeline and edit `deploy.md` or launch the site itself. The pipeline's subagents keep their tools. The hint is used instead of an `agent.user_message` layer because maki charges every permission to an agent slot, and a plugin without all of them (for example `env = false`) would have the layer silently skipped.

## Live panel

`/metronome panel` opens a floating window ordered by what needs you:

1. **questions** — tasks blocked on an answer (`a` to answer).
2. **failures** — `failed` or `stalled` tasks (`r` to retry).
3. **review ready** — `reviewing`, `changes_requested` or `pr_open` (`Enter` to read).
4. **in progress** — everything still moving.

`Enter` focuses the selected task's transcript, `Space` peeks without attaching and offers a reply, `+`/`-` rates a finding, `j`/`k` move, `q` or `Esc` closes. The keys are bound to the panel's own buffer, so the focused window never swallows them. The panel redraws on `TaskStatusChanged` and `TurnEnd`; it does not poll.

The panel opens in **quiet mode**: a running task shows an animated spinner instead of its phase, progress lines pushed by the agent are dropped, and `Space` hides the agent's notes. What needs you — a blocked question, a failure, a review to read — keeps its detail. Press `v` to switch to verbose and back; the footer shows the current choice.

## Architecture

Metronome is a set of Lua modules under `maki/lua/metronome/`, a JSONL journal, and a scheduler. The pipeline is the source of truth: a task is done when its declared checks exit 0, the reviewer approved the exact commit SHA that was checked, and the PR is merged.

- **State** — `state.jsonl` is append-only; `state.json` is a projection for the panel and for humans. Every transition is one event.
- **Roles** — each role resolves to a model, a thinking level, a tool whitelist and a markdown prompt.
- **Scheduler** — a task starts only when its dependencies are merged and no in-flight task shares a declared file, capped by `max_parallel`. A stale task is flagged; a reload resumes interrupted tasks through legal transitions.
- **Runtime** — `runtime.lua` is the table the eight tools and the thirteen commands call; it owns the state paths and drives one submit through qualify, implement, checks, converge, review, PR, merge and deploy.
- **Security** — diffs, transcripts and command output are wrapped in `<<<METRONOME_UNTRUSTED ...>>>` sentinels and treated as data. Protected paths are blocking before a model is called. The implementer refuses to commit on the base branch: every change reaches `main` through a pull request.

See [docs/architecture.md](docs/architecture.md) for the module map, the state machine and the full lifecycle.

## Configuration

Each bound project owns a `config.toml` in its state directory. It names the repository, the base branch, the model and thinking level of every role, the checks, the review bound, the merge policy and the deploy plan. A typo or an unknown model fails at load time with a message that names the role.

See [docs/configuration.md](docs/configuration.md) for every key, its default and a worked example.

## Repository layout

```text
metronome/
├── maki/                  # installed into ~/.config/maki
│   ├── init.lua
│   ├── plugin.toml
│   └── lua/metronome/     # modules, tools, commands, ui/
├── agents/metronome.md    # the primary agent card
├── prompts/               # role prompts and _global.md
├── schemas/               # config, task and event contracts
├── templates/             # config.toml, deploy.md, review-rules.md
├── scripts/               # install, validate, e2e
├── tests/                 # Lua, shell and end-to-end tests
├── docs/                  # architecture, configuration, spike notes
└── system-prompt.md       # the operating manual
```

## Validation

```bash
./scripts/validate.sh   # schemas, prompts, config coherence
./scripts/e2e.sh        # full lifecycle on a throwaway repository
./scripts/e2e-shop.sh   # e-commerce scenario: products, accounts, orders, retry loop
tests/run-lua.sh        # Lua unit and integration suite
```

`scripts/validate.sh` refuses drift between `roles.lua`, the prompts, the config schema and the template. `scripts/e2e.sh` creates a throwaway repo, a bare remote and a fake `gh`, then drives init, submit, questions, implementation, review, merge, deploy, resume and the protected-path guard end to end.
