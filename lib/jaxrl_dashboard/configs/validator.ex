defmodule JaxrlDashboard.Configs.Validator do
  @moduledoc """
  Checks training configs against jaxrl's own Pydantic models.

  The implementation is set by `config :jaxrl_dashboard, :config_validator`:
  `JaxrlDashboard.Configs.PythonValidator` normally, a fake in tests.
  """

  @typedoc "A problem at `path` in the config, e.g. `[\"learner\", \"model\", \"num_layers\"]`."
  @type error :: %{path: [String.t() | non_neg_integer()], message: String.t()}

  @doc "JSON schemas: `%{\"config\" => schema, \"environments\" => %{env_type => schema}}`."
  @callback schema() :: {:ok, map()} | {:error, String.t()}

  @doc "Problems with the config; `{:ok, []}` means it's valid."
  @callback validate(config :: map()) :: {:ok, [error()]} | {:error, String.t()}

  @doc "The config as jaxrl writes it (model field order, defaults filled in). Must be valid."
  @callback format(config :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
