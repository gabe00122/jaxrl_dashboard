defmodule JaxrlDashboard.Configs.Validator do
  @moduledoc """
  Checks training configs against their project's own Pydantic models.

  The implementation is set by `config :jaxrl_dashboard, :config_validator`:
  `JaxrlDashboard.Configs.PythonValidator` normally, a fake in tests.
  """

  alias JaxrlDashboard.Projects.Project

  @typedoc "A problem at `path` in the config, e.g. `[\"learner\", \"model\", \"num_layers\"]`."
  @type error :: %{path: [String.t() | non_neg_integer()], message: String.t()}

  @doc """
  JSON schemas: `%{"config" => schema, "environments" => %{env_type => schema}}`.
  `environments` is empty for projects that don't register environments
  separately from their config.
  """
  @callback schema(Project.t()) :: {:ok, map()} | {:error, String.t()}

  @doc "Problems with the config; `{:ok, []}` means it's valid."
  @callback validate(Project.t(), config :: map()) :: {:ok, [error()]} | {:error, String.t()}

  @doc "The config as the project writes it (model field order, defaults filled in). Must be valid."
  @callback format(Project.t(), config :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
