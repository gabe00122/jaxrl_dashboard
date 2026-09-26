# jaxrl dashboard

Experiment lifecycle dashboard for jaxrl training runs: build configs, queue
training jobs on this machine, watch live metrics, and (later) view policy videos.

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

## Tests

```sh
mix precommit   # warnings-as-errors, format, tests
```
