# rl dashboard

Experiment lifecycle dashboard for training runs of the sibling projects
`../jaxrl` (multi-agent gridworld RL) and `../llm_rl` (valm, LLM finetuning):
build configs, queue training jobs on this machine, watch live metrics, and
record policy videos (jaxrl).

Phoenix LiveView + Postgres. Login-only: there is no signup page.

## Setup

Requires Elixir/Erlang, Docker, and `inotify-tools` (for live reload in dev).

```sh
docker compose up -d     # Postgres 17 on 127.0.0.1:5432
mix setup                # deps, database, assets
mix phx.server           # http://localhost:4000
```

## Users

Accounts are created on the server, and passwords are generated for you.
Each password is printed once and only its argon2 hash is stored.

```sh
mix dashboard.add_user alice         # prints alice's password
mix dashboard.reset_password alice   # new password; logs out all her sessions
mix dashboard.remove_user alice
mix dashboard.list_users
```

## Projects

Each project is a checkout with its own venv, listed under
`config :jaxrl_dashboard, :projects` in `config/config.exs` with an adapter
module (`lib/jaxrl_dashboard/projects/`) for what differs between them:

| | jaxrl | llm_rl |
|---|---|---|
| Configs | `../jaxrl/config` | `../llm_rl/configs` |
| Launched as | `.venv/bin/pmarl train --config ... --base-dir ../jaxrl/results --name NAME` | `.venv/bin/valm pipeline CONFIG --run-id NAME --base-dir ../llm_rl/results` |
| Stages | one, `results/NAME` | PPO: value warmup (`results/NAME-value`), then RL (`results/NAME`); GRPO: RL only |
| Videos | rust environments | none |

Runs from every project share one queue, since they share the GPU. Configs are
validated with each project's own Pydantic models (`priv/python/<project>_config_validator.py`,
run with that project's Python). llm_rl runs are always queued with
`logger.use_jsonl` on, since that's where the dashboard reads metrics.

## Training runs

Runs are queued from config files in their project's config directory and
start one at a time (`max_concurrent` in `config/config.exs`).

Runs are detached from the dashboard, so restarting the server doesn't stop
them. Each run's pid, output and exit code are written to `var/runs/NAME/`, and
the dashboard picks running jobs back up after a restart. Cancelling sends
SIGTERM to the run's process group, then SIGKILL after 30s.

Paths and commands are set in `config/config.exs`. In prod they can be
overridden with `JAXRL_DIR`, `LLM_RL_DIR` and `RUNS_DATA_DIR`.

Runs trained outside the dashboard can be imported from every project's
results dir with `mix dashboard.import_runs`.

## Tests

```sh
mix precommit   # warnings-as-errors, format, tests
```
