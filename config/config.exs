# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jaxrl_dashboard,
  ecto_repos: [JaxrlDashboard.Repo],
  generators: [timestamp_type: :utc_datetime]

# Where the jaxrl project lives and how training runs are launched.
# `train_command` is resolved relative to `project_dir`; the dashboard appends
# `--config`, `--base-dir` and `--name`. Calling the venv directly (rather
# than `uv run`) avoids uv re-syncing the environment and dropping the CUDA extra.
jaxrl_dir = Path.expand("../../jaxrl", __DIR__)

config :jaxrl_dashboard, :config_validator, JaxrlDashboard.Configs.PythonValidator

config :jaxrl_dashboard, :runs,
  project_dir: jaxrl_dir,
  config_dir: Path.join(jaxrl_dir, "config"),
  results_dir: Path.join(jaxrl_dir, "results"),
  # Dashboard-owned per-run files: input config, output log, pid, exit code.
  data_dir: Path.expand("../var/runs", __DIR__),
  train_command: [".venv/bin/pmarl", "train"],
  # jaxrl's Python, used to validate configs against its Pydantic models.
  python: ".venv/bin/python",
  # One GPU, so one training run at a time.
  max_concurrent: 1,
  poll_interval: 1_000,
  # How often a running run's logs.jsonl and output.log are checked for new lines.
  watch_interval: 1_000,
  # How long a cancelled run gets to exit after SIGTERM before SIGKILL.
  kill_grace_period: 30_000,
  start_scheduler: true

# Configure the endpoint
config :jaxrl_dashboard, JaxrlDashboardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: JaxrlDashboardWeb.ErrorHTML, json: JaxrlDashboardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: JaxrlDashboard.PubSub,
  live_view: [signing_salt: "9AhOGws/"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  jaxrl_dashboard: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  jaxrl_dashboard: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
