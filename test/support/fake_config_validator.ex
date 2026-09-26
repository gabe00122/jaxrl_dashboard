defmodule JaxrlDashboard.FakeConfigValidator do
  @moduledoc """
  Stands in for the Python validator in tests. Serves a snapshot of jaxrl's
  real schema (regenerate with `mix run priv/python/dump_schema.exs`) and
  reports whatever errors a test sets with `put_errors/1`; none by default.
  """
  @behaviour JaxrlDashboard.Configs.Validator

  @schema_path Path.expand("fixtures/config_schema.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()

  @impl true
  def schema, do: {:ok, @schema}

  @impl true
  def validate(config) do
    errors_for = Application.get_env(:jaxrl_dashboard, :fake_config_errors, fn _config -> [] end)
    {:ok, errors_for.(config)}
  end

  @impl true
  def format(config), do: {:ok, Jason.encode!(config, pretty: true)}

  @doc "Makes `validate/1` return `fun.(config)`. Not async-safe."
  def put_errors(fun) do
    Application.put_env(:jaxrl_dashboard, :fake_config_errors, fun)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:jaxrl_dashboard, :fake_config_errors)
    end)
  end
end
