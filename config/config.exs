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

config :jaxrl_dashboard, :config_validator, JaxrlDashboard.Configs.PythonValidator

# The training projects the dashboard runs, in the order they're listed in the
# UI. Each is a checkout next to this one with its own venv; `adapter` knows
# how that project is launched and where its runs write their results.
# Commands are resolved relative to `dir`. Calling the venv directly (rather
# than `uv run`) avoids uv re-syncing the environment and dropping the CUDA
# extra. Projects are keyed by id, which is stored with each run: never
# rename one that has runs.
jaxrl_dir = Path.expand("../../jaxrl", __DIR__)
llm_rl_dir = Path.expand("../../llm_rl", __DIR__)

config :jaxrl_dashboard, :projects,
  jaxrl: [
    label: "jaxrl",
    description: "Multi-agent gridworld RL",
    adapter: JaxrlDashboard.Projects.Jaxrl,
    dir: jaxrl_dir,
    config_dir: Path.join(jaxrl_dir, "config"),
    results_dir: Path.join(jaxrl_dir, "results"),
    # Used to validate configs against the project's Pydantic models.
    python: ".venv/bin/python",
    # The dashboard appends `--config`, `--base-dir` and `--name`.
    train_command: [".venv/bin/pmarl", "train"],
    # `pmarl record` renders policy videos; the dashboard appends the run
    # name, `--base-dir` and `--out-dir`.
    record_command: [".venv/bin/pmarl", "record"],
    # Recordings share the GPU with training, so JAX mustn't grab most of its
    # memory up front.
    record_env: [{"XLA_PYTHON_CLIENT_PREALLOCATE", "false"}]
  ],
  llm_rl: [
    label: "llm_rl",
    description: "LLM finetuning with value approximation (valm)",
    adapter: JaxrlDashboard.Projects.LlmRl,
    dir: llm_rl_dir,
    config_dir: Path.join(llm_rl_dir, "configs"),
    results_dir: Path.join(llm_rl_dir, "results"),
    python: ".venv/bin/python",
    # The dashboard appends the config path, `--run-id` and `--base-dir`.
    # PPO configs go through offline data and value warmup stages first.
    train_command: [".venv/bin/valm", "pipeline"]
  ]

config :jaxrl_dashboard, :runs,
  # Dashboard-owned per-run files: input config, output log, pid, exit code.
  data_dir: Path.expand("../var/runs", __DIR__),
  max_concurrent_recordings: 1,
  # One GPU shared by every project, so one training run at a time.
  max_concurrent: 1,
  poll_interval: 1_000,
  # How often a running run's logs.jsonl and output.log are checked for new lines.
  watch_interval: 1_000,
  # How long a cancelled run gets to exit after SIGTERM before SIGKILL.
  kill_grace_period: 30_000,
  # Starts the run scheduler and the video recorder.
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
