# Architecture

Metronome is a maki plugin: a set of Lua modules loaded from `~/.config/maki/lua/metronome/`, a JSONL journal, and a scheduler. It orchestrates model sessions; it does not contain a model and it does not write code.

## Modules

Every module returns a table and never raises into maki. Fallible functions return `(value, err)`, and the pipeline steps take their collaborators as injected options so they can be tested without a model, a repository or a session.

| Module | Responsibility |
| --- | --- |
| `config.lua` | Parse and validate `config.toml` against the schema subset the host can read. |
| `state.lua` | Append-only journal, projection, task CRUD and the legal transition table. |
| `roles.lua` | Resolve a role name to its model, thinking level, tool whitelist and prompt files. |
| `runner.lua` | Open a maki subagent session for one role, with retry, timeout and logs. |
| `git.lua` | Fetch, worktree, branch, commit, push, diff and the `gh` PR calls. |
| `qualify.lua` | Turn an intention into task sheets, with a repair pass and a question list. |
| `questions.lua` | Deduplicate, rank and cap a question round; write answers back to every source. |
| `analyze.lua` | Cross-task structural and semantic analysis; gate `qualifying -> ready`. |
| `implement.lua` | Prepare the worktree, checkpoint, run the implementer turn, commit and push. |
| `checks.lua` | Run the declared commands, capture the report, roll back on red. |
| `converge.lua` | Compare the diff with the task's declared files; one repair turn if they differ. |
| `review.lua` | Review one exact SHA, store findings, bound the rounds, escalate. |
| `merge.lua` | Rebase on the fresh base, merge the PR, re-run the checks on the merged base. |
| `deploy.lua` | Run `deploy.md` with the user in the loop, guarded by a merged PR and green checks. |
| `calibrate.lua` | Analyze the repository and generate `review-rules.md`; ingest feedback. |
| `pipeline.lua` | Scheduler: dependencies, file overlap, `max_parallel`, stall detection, resume. |
| `runtime.lua` | The production runtime the tools and commands call: paths, init, config (read and merge-update), submit, status, answer, retry, abandon, calibrate, panel, resume, feedback, mode. |
| `mode.lua` | Persist the on/off routing flag, contribute a routing prompt hint evaluated before every run, and guard the main session from `write`/`edit`/`bash` while the mode is on. |
| `fence.lua` | Wrap untrusted output in sentinels and escape forged sentinels. |
| `tools.lua` | The twelve agent tools, as thin adapters over an injected runtime. |
| `commands.lua` | The seventeen `/metronome` subcommands, parsed and forwarded to the runtime. |
| `ui/panel.lua` | Floating panel lifecycle, key routing, peek/reply, event-driven refresh, quiet mode and its spinner loop. |
| `ui/render.lua` | Pure attention-bell ordering, intention grouping, dependency and branch rendering, and the quiet-mode spinner. |

`maki/init.lua` loads every module and registers the tools and the `/metronome` dispatcher against `runtime.lua`. The agent card is `agents/metronome.md`, and the operating manual is `system-prompt.md`.

## State

The state root lives outside the repository, under `~/.local/state/maki/metronome/<slug>/`. It holds:

```text
state.jsonl      append-only journal, one event per line
state.json       projection rebuilt from the journal on every write
state.lock       advisory lock (the journal shape is the real guarantee)
config.toml      the bound project configuration
tasks/<id>.md    the task sheet qualification wrote
checks/<id>.json the last checks report
runs/<id>/...    transcripts, prompts and logs per run
review-rules.md  the calibrated review rules
deploy.md        the deployment plan
archive/<id>.json  snapshot of a deleted task (record + sheet)
```

`state.jsonl` is the truth. A torn last line is dropped on replay, so a crash costs at most the event being written. `state.json` carries the event count it was built from and is trusted only when that count matches the journal.

Every task moves through a fixed state machine, and every move is one event:

```text
draft -> qualifying -> awaiting_answers -> qualifying
      -> ready -> running -> verifying -> reviewing
      -> changes_requested -> running
      -> pr_open -> merging -> merged -> deploying -> deployed
```

`failed`, `stalled` and `abandoned` are reachable from the active states. `state.lua` owns the legal edges; an illegal move is refused with the allowed alternatives named. The task and event shapes are pinned by `schemas/task.schema.json` and `schemas/event.schema.json`.

## Pipeline

One task goes through these phases, each owned by a module:

1. **Qualify** — `qualify.lua` turns the intention into task sheets, one per unit of work, with declared files, checks and acceptance criteria. A task that asks a question is parked in `awaiting_answers`; the rest become `ready` after the analysis gate.
2. **Analyze** — `analyze.lua` checks the sheets against each other: duplicate titles, duplicate file sets, overlapping files without a dependency, missing dependencies, dependency cycles, gate coupling (a check that runs a file another task owns, which deadlocks when the owner waits on this task), empty checks. A blocking finding keeps the task in `qualifying`.
3. **Implement** — `implement.lua` creates the worktree from the base branch, checkpoints the starting SHA, runs the implementer, commits and pushes.
4. **Verify** — `checks.lua` runs the declared commands in the worktree. A red check rolls back to the checkpoint and sends the task back to `running`.
5. **Converge** — `converge.lua` compares the diff with the declared files. A missing or unexpected file gets one repair turn; the verdict is the diff after the turn, never the model's word.
6. **Review** — `review.lua` reads the exact HEAD SHA, lists the changed files, refuses a protected path before any model call, then asks the reviewer for structured findings. Blocking or major findings send the task to `changes_requested`; the loop is bounded, then escalates.
7. **PR** — `git.pr_open` creates the pull request, stores it on the task and moves it to `pr_open`.
8. **Merge** — `merge.lua` rebases on the fresh base, merges through `gh`, and re-runs the checks on the merged base. A red base fails the task.
9. **Deploy** — `deploy.lua` requires a merged PR (stored and live), a green checks report and an existing `deploy.md`, asks for confirmation, then runs the plan.

## Scheduler

`pipeline.lua` decides what may run, never how a step runs:

- **Dependencies** — a task starts only when every `depends_on` task is `merged` or `deployed`. A missing, failed or abandoned dependency blocks it with a named reason.
- **File overlap** — two tasks that declare a common file never run together, even below `max_parallel`.
- **`max_parallel`** — the hard cap on tasks in flight.
- **Stall detection** — an active task whose last progress is older than `stall_minutes` is stale. A stale `running` task moves to `stalled`; the other active statuses are flagged `stall.suspect`.
- **Resume** — `/reload` kills in-flight sessions. Resume walks each interrupted task back to `running` through legal transitions only (`reviewing -> changes_requested -> running`, `merging -> failed -> running`) and re-dispatches its phase.

## Security

- **Untrusted content** — diffs, transcripts, command output and repository files are wrapped by `fence.lua` in `<<<METRONOME_UNTRUSTED ...>>>` sentinels with a standing warning. Any sentinel inside the content is escaped, so the block cannot be closed early; `kind` and `label` are reduced to safe tokens.
- **Protected paths** — a diff touching `review-rules.md`, `AGENTS.md`, `.metronome/`, `deploy.md` or the config is a blocking finding, decided before the reviewer model is called.
- **Done is executable** — a task is done when its checks exit 0, not when a model says so.
- **Exact SHA** — the reviewer reviews one commit; if the branch moves during the review, the review is refused rather than stored.
- **No self-approval** — the implementer never reviews its own change, and the reviewer never edits code.
- **Least privilege** — the plugin declares the maki permissions it uses, and the installer never overwrites a permission the user set.

## Testing

- Lua unit and integration tests run inside maki's own host through `tests/run-lua.sh`; they use real git against throwaway repositories and real journals validated by `tools/validate-state.py`.
- `tests/validate.sh` proves the schemas, prompts and config cannot drift.
- `scripts/e2e.sh` drives the whole lifecycle on a disposable repository with a bare remote and a fake `gh`, and judges the remote and the journal, not a summary.
- `scripts/e2e-shop.sh` builds a fake e-commerce project, splits it into products, accounts and orders tasks, fails the orders check once to prove the rollback-and-retry loop, deploys, and validates the delivered server over HTTP.
