defmodule JaxrlDashboard.FakeConfigValidator do
  @moduledoc """
  Stands in for the Python validator in tests. Serves a snapshot of each
  project's real schema (`fixtures/<project>_config_schema.json`, regenerate
  with `mix run --no-start priv/python/dump_schema.exs`) and reports whatever
  errors a test sets with `put_errors/1`; none by default.
  """
  @behaviour JaxrlDashboard.Configs.Validator

  alias JaxrlDashboard.Projects.Project

  @schemas (for id <- ~w(jaxrl llm_rl) do
              path = Path.expand("fixtures/#{id}_config_schema.json", __DIR__)
              @external_resource path
              {id, path |> File.read!() |> Jason.decode!()}
            end)
           |> Map.new()

  @impl true
  def schema(%Project{id: id}), do: {:ok, Map.fetch!(@schemas, id)}

  @impl true
  def validate(%Project{}, config) do
    errors_for = Application.get_env(:jaxrl_dashboard, :fake_config_errors, fn _config -> [] end)
    {:ok, errors_for.(config)}
  end

  @impl true
  def format(%Project{}, config), do: {:ok, Jason.encode!(config, pretty: true)}

  @doc "Makes `validate/2` return `fun.(config)`. Not async-safe."
  def put_errors(fun) do
    Application.put_env(:jaxrl_dashboard, :fake_config_errors, fun)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:jaxrl_dashboard, :fake_config_errors)
    end)
  end
end
