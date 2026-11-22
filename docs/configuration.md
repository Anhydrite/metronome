# Configuration

A bound project owns one `config.toml` in its state directory. `/metronome init` copies `templates/config.toml` there; after that you edit it in place. The file is validated before any pipeline run, so a typo, a missing role or an unknown model fails at load time with a message that names the role and the spec.

```bash
./scripts/validate.sh
tools/validate-config.py /path/to/config.toml
```

The contract is `schemas/config.schema.json`. Unknown keys are refused, every role is required, and a model spec must be in `provider/id` form.

## `[project]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `repo` | string, absolute path | required | The git repository Metronome drives. |
| `base_ref` | string | required | The branch every task is cut from. |
| `max_parallel` | integer, 1–16 | `2` | How many tasks may run at once. Parallelism is bounded only by `max_parallel` and `depends_on`; two tasks sharing a declared file may run concurrently, each in its own worktree, with the conflict resolved at merge. |
| `max_parallel_qualifiers` | integer, 1–16 | `4` | How many qualifier sessions may run at once when several intentions are submitted together. |

```toml
[project]
repo = "/home/you/src/shop"
base_ref = "main"
max_parallel = 2
max_parallel_qualifiers = 4
```

## `[git]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `branch_prefix` | string | `"metronome/"` | Prefix for task branches; the task id is appended. |
| `commit_style` | `"conventional"` or `"plain"` | `"conventional"` | Commit message style the implementer is asked for. |
| `pr_draft` | boolean | `false` | Open pull requests as drafts. |

## `[roles]`

One entry per role. Every role is required: a missing one stops the pipeline at load time rather than mid-run. A role has:

| Key | Type | Meaning |
| --- | --- | --- |
| `model` | string | Model spec in `provider/id` form, as `maki.model.available()` lists them. |
| `thinking` | enum | `off`, `adaptive`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. |
| `tools` | array of strings, optional | Tool whitelist. Omit for the audience default. |

A subagent's thinking level is capped by its parent's, so the Metronome agent must run at least as high as the highest role here. The five internal role keys are `qualifier`, `analyst`, `implementer`, `reviewer` and `deployer`; each has a matching `prompts/<role>.md`. The panel and the prompt headings use the orchestra name:

| Internal key | Orchestra name | What it does |
| --- | --- | --- |
| `qualifier` | chef de pupitre | Turns an intention into task sheets. |
| `analyst` | harmoniste | Checks the sheets against each other before any code. |
| `implementer` | instrumentiste | Makes the change on the task branch. |
| `reviewer` | critique | Reviews one exact commit. |
| `deployer` | timbalier | Runs the deployment plan. |

The internal keys stay stable in `config.toml` and in the journal; only the display name changes.

```toml
[roles.qualifier]
model = "ocgo/deepseek-v4.1-flash"
thinking = "high"

[roles.analyst]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"

[roles.implementer]
model = "opencode-go/kimi-k3"
thinking = "max"

[roles.reviewer]
model = "ocgo/deepseek-v4-pro"
thinking = "high"

[roles.deployer]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"
```

## `[checks]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default` | array of strings | `[]` | Commands that prove a task is done. A task's own `checks` override this. |
| `re_run_after_merge` | boolean | `true` | Re-run the checks on the merged base before recording the merge. |
| `timeout_secs` | integer | `600` | Per-command timeout. |

A task is done when these commands exit 0, not when a model says so. A red check rolls the worktree back to its last checkpoint.

## Preflight

`/metronome init` and `/metronome config` verify the environment before they write anything: a project bound with a missing checker, no git identity or a base branch absent from `origin` would otherwise only fail on the first task, far from the command that created it. The preflight runs five mandatory checks in one pass — git identity, a test commit, the declared checks, the `origin` base branch and the toolchain — so a single refusal lists every problem:

| Check | What it proves | Remedy it names |
| --- | --- | --- |
| `git-identity` | `user.name` and `user.email` are set and non-empty in `project.repo`. | `git config --global user.name` and `git config --global user.email`. |
| `git-test-commit` | A probe commit passes in a throwaway worktree cut from `project.base_ref`; the worktree is removed on both paths. | Fix the identity, a blocking pre-commit hook or the repository permissions. |
| `checks-executable` | The program word of every declared check resolves on `PATH`. It proves the program word resolves only: the rest of the command and its runtime dependencies are not resolved, so `npm test` passes this check with `npm` on `PATH` even when `node` is absent or `package.json` declares no `test` script. | Install the missing program, or fix the declared command. |
| `origin-base` | `project.repo` has an `origin`, and that `origin` has `project.base_ref`. | `git remote add origin <url>`, then push the base branch. |
| `toolchain` | `python3` imports `jsonschema`, which `scripts/validate.sh` needs. | `python3 -m pip install jsonschema`. |

Every child process runs under `LC_ALL=C` (and `LANG=C`), so git and the declared checks produce the same locale-independent diagnostics on every machine.

A failure refuses the binding: `init` writes no state, `config` leaves `config.toml` untouched, and the refusal is a message naming the check id, the exact command that failed and the remedy. There is no silent success: a runtime built without the preflight wired refuses to bind explicitly instead of declaring the project ready, and `/metronome config` runs the same five checks before it rewrites `config.toml`.

## `[review]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `engine` | `model` or `no-mistakes` | `model` | `model` runs the reviewer loop; `no-mistakes` runs the local gate, then merges a clean branch without looping back to implementation. |
| `no_mistakes_bin` | string | `no-mistakes` | The `no-mistakes` executable used by the gate engine. |
| `max_rounds` | integer, 1–10 | `3` | Review rounds before escalation. |
| `require_checks_green` | boolean | `true` | Refuse a review when the checks report is red or missing. |
| `protected_paths` | array of strings | `["review-rules.md", "AGENTS.md", ".metronome/", "deploy.md"]` | A diff touching any of these is a blocking finding, decided before the reviewer model is called. |

## `[merge]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `auto_merge` | boolean | `false` | Merge without asking. Off by default: the pipeline opens the PR and waits. |
| `method` | `"squash"`, `"merge"` or `"rebase"` | `"squash"` | Flag passed to `gh pr merge`. |
| `auto_rebase` | boolean | `true` | Rebase the branch on the fresh base before merging. |

## `[deploy]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `auto_deploy` | boolean | `false` | Deploy without asking. Off by default. |
| `confirm` | boolean | `true` | Ask for confirmation before the deployer runs. |
| `plan_file` | string | `"deploy.md"` | The plan the deployer follows, relative to the repository root. |

Deploy also refuses unless the PR is merged (stored and live) and the checks report is green.

## Epic branches

An intention that qualifies into several tasks goes through an epic branch, and no key configures it: the rule is structural. Qualification cuts `metronome/epic/<slug>-<first-task-suffix>` from `project.base_ref` and pushes it; every subtask is cut from it, its PR targets it, and it stops at `merged` without deploying. One `epic` task then owns the single PR from the epic branch to `project.base_ref`. `merge.auto_merge` governs both levels: off, the subtask PRs and the epic PR are left open for a human; on, the pipeline merges the subtasks, then the epic, and `deploy.auto_deploy` decides whether the epic deploys. A single-task intention is unaffected.

## `[quality]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `variants` | integer, 1–3 | `1` | Best-of-N: run the task N times and keep the best diff. |
| `stall_minutes` | integer | `20` | An active task with no progress for this long is stale. |

## `[limits]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_task_cost_usd` | number | `5.0` | Budget per task. |
| `timeout_minutes` | integer | `30` | Wall-clock timeout per task. |
| `max_questions_per_round` | integer, 1–50 | `15` | Cap on the question round Metronome poses. |

The bounded-retry policy is not configured here: it lives in `recover.DEFAULTS` (`max_attempts = 3`, `backoff_base_secs = 30`, `backoff_max_secs = 900`, `factor = 2`). See [architecture.md](architecture.md#recovery) for the recovery loop and what each constant bounds.

## Full example

```toml
[project]
repo = "/home/you/src/shop"
base_ref = "main"
max_parallel = 2
max_parallel_qualifiers = 4

[git]
branch_prefix = "metronome/"
commit_style = "conventional"
pr_draft = false

[roles.qualifier]
model = "ocgo/deepseek-v4.1-flash"
thinking = "high"

[roles.analyst]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"

[roles.implementer]
model = "opencode-go/kimi-k3"
thinking = "max"

[roles.reviewer]
model = "ocgo/deepseek-v4-pro"
thinking = "high"

[roles.deployer]
model = "ocgo/deepseek-v4.1-flash"
thinking = "medium"

[checks]
default = ["npm test"]
re_run_after_merge = true
timeout_secs = 600

[review]
engine = "model"
no_mistakes_bin = "no-mistakes"
max_rounds = 3
require_checks_green = true
protected_paths = ["review-rules.md", "AGENTS.md", ".metronome/", "deploy.md"]

[merge]
auto_merge = false
method = "squash"
auto_rebase = true

[deploy]
auto_deploy = false
confirm = true
plan_file = "deploy.md"

[quality]
variants = 1
stall_minutes = 20

[limits]
max_task_cost_usd = 5.0
timeout_minutes = 30
max_questions_per_round = 15
```

## Files next to the config

The state directory also holds the files the pipeline reads:

- `prompts/_global.md` and `prompts/<role>.md` — the role instructions, copied by `/metronome init`.
- `review-rules.md` — the repository-specific review rules, generated by `/metronome calibrate`.
- `deploy.md` — the deployment plan, read by the deployer.
- `tasks/<id>.md` — the task sheets qualification wrote.
- `checks/<id>.json` — the last checks report.
- `state.jsonl` and `state.json` — the journal and its projection.

## Environment

| Variable | Used by | Meaning |
| --- | --- | --- |
| `MAKI_CONFIG_DIR` | `scripts/install.sh` | Install target. Defaults to `$XDG_CONFIG_HOME/maki`, else `~/.config/maki`. |
| `XDG_CONFIG_HOME` | `scripts/install.sh` | Base for the default install target. |
| `XDG_STATE_HOME` | state root | Base for `~/.local/state/maki/metronome/<slug>/`. |

## Validation

`scripts/validate.sh` checks that the schemas are valid, every role has a prompt, the role set is identical in `roles.lua`, the prompts, the config schema and `templates/config.toml`, the thinking levels match the schema, and the statuses in `state.lua` match the task schema. It refuses drift, not just syntax.
