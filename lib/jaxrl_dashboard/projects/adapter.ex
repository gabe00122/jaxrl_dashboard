defmodule JaxrlDashboard.Projects.Adapter do
  @moduledoc """
  What differs between training projects. Each project in
  `config :jaxrl_dashboard, :projects` names a module implementing this.

  Everything else is shared: a project is a checkout with a venv, a directory
  of JSON configs validated by Pydantic models, and a results directory where
  every run (stage) writes `config.json`, `meta.json` and a `logs.jsonl` of
  `{"step": N, ...metrics}` rows.
  """

  alias JaxrlDashboard.Projects.Stage

  @doc "Arguments appended to the project's `train_command`."
  @callback train_args(config_path :: Path.t(), results_dir :: Path.t(), name :: String.t()) ::
              [String.t()]

  @doc """
  Adjusts a config before it's queued, for settings the dashboard depends on
  (like logging metrics to `logs.jsonl`). The result is what's stored with
  the run and validated, so the run's page shows what actually ran.
  """
  @callback prepare_config(config :: map()) :: map()

  @doc """
  The stages a run named `name` goes through with `config` (nil while the
  config isn't known yet), in order. The last is the main one: it has the
  final checkpoints and is what the compare page shows.
  """
  @callback stages(name :: String.t(), config :: map() | nil) :: [Stage.t(), ...]

  @doc "Whether the project's `record_command` can render videos of runs with this config."
  @callback recordable?(config :: map()) :: boolean()

  @doc """
  File name in `priv/python/` of the script that serves the project's config
  schema and validates configs (see `JaxrlDashboard.Configs.PythonValidator`).
  """
  @callback validator_script() :: String.t()
end
