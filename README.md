# Metronome

An autonomous delivery pipeline that runs as a [maki](https://github.com/Anhydrite/maki) plugin.

> [!WARNING]
> **The `no-mistakes` review gate runs its own agent, not maki.**
> With `[review] engine = "no-mistakes"`, the gate reads `agent:` from
> `~/.no-mistakes/config.yaml`. `agent: auto` picks the first native agent it
> detects — on this machine, `pi` — so the gate's review/fix/test steps run in
> `pi`, while Metronome's own roles keep running in maki. If `pi` fails with
> `401 api_key_expired` (provider `opencode-go`), the gate fails even though
> maki is healthy. To run the gate through maki, use `agent: acp:maki` with an
> `acp_registry_overrides` entry (`maki: maki acp`); to stay in maki only,
> switch `[review] engine` to `"model"`.

You bring an intention. Metronome qualifies it into tasks, asks the questions that block work, and drives each task through implementation, checks, review, merge and deploy. You stay the conductor: you set the tempo, answer what only you can answer, and read the delivery report.

Metronome never writes code itself. It orchestrates five roles — qualifier, analyst, implementer, reviewer, deployer — each in its own session and git worktree, and it reports what the pipeline recorded, never what a model claimed.

## Why

A model saying "done" is not done. Metronome makes the pipeline the source of truth:

- **Checks are executable.** A task is done when its declared commands exit `0`, not when a model says so.
- **Review is exact.** The reviewer gates one commit SHA; if the branch moves during the review, the answer is refused.
- **Merge is proven.** The PR is squash-merged, then the checks are re-run on the merged base. A red base fails the task.
- **Deploy is guarded.** Deploy starts only from `merged`, with a really merged PR, green checks and an existing `deploy.md`.

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
| `/metronome submit <intention>` | Qualify an intention into tasks. `fast` / `full` / `auto` set the complexity. |
| `/metronome status [id]` | Show every task, or one task in detail. |
| `/metronome answer` | Open the pending question round. |
| `/metronome calibrate` | Generate `review-rules.md` from the repository. |
| `/metronome retry <id>` | Restart a failed task from its last stable phase. |
| `/metronome abandon <id>` | Archive a task. |
| `/metronome prune` | Reconcile GitHub with the journal: close orphan PRs, delete stale branches. |
| `/metronome stop <id>` | Cancel an in-flight task and park it as abandoned. |
| `/metronome delete <id>` | Remove a task from the panel and status; a snapshot is kept in the archive and the slow cleanup runs in the background. |
| `/metronome archive` | List the snapshots kept for deleted tasks. |
| `/metronome config [key=value ...]` | Show the project configuration, or update it in place. |
| `/metronome panel` | Open, close or toggle the live panel. |
| `/metronome resume` | Restart tasks interrupted by a reload. |
| `/metronome feedback <id>` | Rate a review's findings to calibrate the reviewer. |
| `/metronome on` | Natural-language routing: a plain request calls the matching tool. |
| `/metronome off` | Turn natural-language routing off. |

The same surface is exposed to the agent as twelve tools: `metronome_submit`, `metronome_status`, `metronome_answer`, `metronome_retry`, `metronome_abandon`, `metronome_prune`, `metronome_stop`, `metronome_delete`, `metronome_archive`, `metronome_calibrate`, `metronome_config`, `metronome_panel`. `metronome_config` reads the config and, with `answers`, updates it in place — merged with the config on disk, so changing one model does not reset the checks or the merge/deploy policy.

### Natural-language mode

`/metronome on` makes the pipeline listen to plain requests. While it is on, a prompt hint evaluated before every run tells the agent to call the matching tool instead of answering in prose: "add a CSV export task" calls `metronome_submit`, "where is T-…" calls `metronome_status`, "abandon T-…" calls `metronome_abandon`, and so on. A message that is not a Metronome request is answered normally. The flag lives in the project state directory, is read on every run, and `/metronome off` takes effect on the next turn. While the mode is on, the main session is guarded: `write`, `edit` and `bash` are refused, so the agent cannot bypass the pipeline or touch a protected path.

## Live panel

`/metronome panel` opens a floating window ordered by what needs you:

1. **questions** — tasks blocked on an answer (`a` to answer).
2. **failures** — `failed` or `stalled` tasks (`r` to retry).
3. **review ready** — `reviewing`, `changes_requested` or `pr_open` (`Enter` to read).
4. **in progress** — everything still moving.

`Enter` focuses the selected task's transcript, `Space` peeks without attaching and offers a reply, `+`/`-` rates a finding, `j`/`k` move, `q` or `Esc` closes. The keys are bound to the panel's own buffer, so the focused window never swallows them. The panel redraws on `TaskStatusChanged` and `TurnEnd`; it does not poll.

The panel is **two columns**: one request per line on the left, a separator, and the selected request's PERT schema on the right. `j`/`k` move between requests and redraw the schema; `v` toggles quiet/verbose and `q` closes. The schema draws the request's dependency tree as an indented `├─▶`/`└─▶` tree, with terminal tasks dimmed so an edge to an already-merged prerequisite stays visible.

The panel opens in **quiet mode**: progress lines pushed by the agent are dropped, and `Space` hides the agent's notes. What needs you — a blocked question, a failure, a review to read — keeps its detail. Press `v` to switch to verbose and back; the footer shows the current choice.

## How it works

One task moves through a fixed set of states, and every move is one event in `state.jsonl`:

```text
draft -> qualifying -> awaiting_answers -> qualifying
      -> ready -> running -> verifying -> reviewing
      -> changes_requested -> running
      -> pr_open -> merging -> merged -> deploying -> deployed
```

`failed`, `stalled` and `abandoned` are reachable from the active states. Each phase is owned by a module:

1. **Qualify** — `qualify.lua` turns the intention into task sheets with declared files, checks and acceptance criteria. A task that asks a question is parked in `awaiting_answers`.
2. **Analyze** — `analyze.lua` checks the sheets against each other: duplicate titles, missing or cyclic dependencies, gate coupling (a check that runs a file another task owns, which deadlocks when the owner waits on this task), empty checks. A blocking finding keeps the task in `qualifying`. Overlapping files and identical file sets are informative (`minor`) findings only, and cross-task rules compare only tasks cut from the same `base_ref` — two epics are never compared.
3. **Implement** — `implement.lua` creates the worktree from the fresh base, checkpoints the starting SHA, runs the implementer, commits and pushes.
4. **Verify** — `checks.lua` runs the declared commands in the worktree. A red check rolls back to the checkpoint and sends the task back to `running`.
5. **Converge** — `converge.lua` compares the diff with the declared files. A missing or unexpected file gets one repair turn; the verdict is the diff, never the model's word.
6. **Review** — `review.lua` reads the exact HEAD SHA, refuses a protected path before any model call, then asks the reviewer for structured findings. The loop is bounded, then escalates to a human.
7. **PR** — `git.pr_open` creates the pull request, stores it on the task and moves it to `pr_open`.
8. **Merge** — `merge.lua` rebases on the fresh base, squash-merges through `gh`, and re-runs the checks on the merged base.
9. **Deploy** — `deploy.lua` requires a merged PR, a green checks report and an existing `deploy.md`, asks for confirmation, then runs the plan.

The scheduler (`pipeline.lua`) decides what may run, never how a step runs: dependencies must be `merged` or `deployed`, `max_parallel` is the hard cap, and a stale task is flagged and surfaced in the panel. Declared files never bound parallelism — two tasks that share a file run at the same time in separate worktrees, and any conflict is resolved at merge.

### Epic branches

One intention can qualify into several tasks. Those tasks never merge into the project base directly: qualification cuts an epic branch `metronome/epic/<slug>-<first-task-suffix>` from the fresh base, pushes it, and cuts every subtask from it. A subtask opens its PR against the epic branch, merges there, re-runs its checks on that branch and stops at `merged` — it never deploys. Once every subtask is merged, a single `epic` task opens the one PR from the epic branch to the project base, merges it, re-runs the declared checks on the merged base, and only then deploys. An intention that produces exactly one task is unchanged: it merges into the project base and deploys as before.

## Recovery

A failure is a state, not a verdict. No transient failure — git identity, network, a missing binary, a timeout, a killed process, a dead session, a quota or a 429 — permanently condemns a task.

- **Nothing is thrown away.** A failed task keeps its worktree, its branch, its checkpoints and its transcript. It restarts from the last stable state, never from scratch.
- **Bounded automatic retry.** `recover.lua` classifies the error into a closed, typed cause with an actionable remedy, then retries with exponential backoff, capped at 3 attempts, 30 s base and 900 s max (`recover.DEFAULTS`). The scheduler never stops because a task is `failed`; each run is spawned on its own, so a retry never blocks the drain.
- **Visible diagnosis.** `metronome_status` and `/metronome status <id>` expose, per task, the `checkpoint` to resume from, the typed `last_error` and the `retry_action` (`auto_retry`, `human` or `none`).
- **Manual relaunch.** `/metronome retry <id>` resumes a failed task from its last checkpoint; `/metronome resume` relaunches tasks interrupted by a `/reload`. Human escalation is the last resort, only when a retry is impossible.

## Architecture

Metronome is a set of Lua modules under `maki/lua/metronome/`, a JSONL journal, and a scheduler.

- **State** — `state.jsonl` is append-only; `state.json` is a projection for the panel and for humans. A torn last line is dropped on replay, so a crash costs at most the event being written.
- **Roles** — each role resolves to a model, a thinking level, a tool whitelist and a markdown prompt. A missing role or an unknown model fails before a session is opened.
- **Runtime** — `runtime.lua` is the table the tools and commands call; it owns the state paths and drives one submit through qualify, implement, checks, converge, review, PR, merge and deploy.
- **Security** — diffs, transcripts and command output are wrapped in `<<<METRONOME_UNTRUSTED ...>>>` sentinels and treated as data. Protected paths are blocking before a model is called. The implementer refuses to commit on the base branch: every change reaches `main` through a pull request.

See [docs/architecture.md](docs/architecture.md) for the module map, the state machine and the full lifecycle.

## Configuration

Each bound project owns a `config.toml` in its state directory (`~/.local/state/maki/metronome/<slug>/`). It names the repository, the base branch, the model and thinking level of every role, the checks, the review bound, the merge policy and the deploy plan. A typo or an unknown model fails at load time with a message that names the role.

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
./scripts/e2e-tmux.sh   # realistic proof: a real repo, a tmux session, a deployed task
tests/run-lua.sh        # Lua unit and integration suite
```

`scripts/validate.sh` refuses drift between `roles.lua`, the prompts, the config schema and the template. `scripts/e2e.sh` creates a throwaway repo, a bare remote and a fake `gh`, then drives init, submit, questions, implementation, review, merge, deploy, resume and the protected-path guard end to end.
