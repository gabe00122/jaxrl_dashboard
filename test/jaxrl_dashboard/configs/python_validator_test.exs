defmodule JaxrlDashboard.Configs.PythonValidatorTest do
  # Runs priv/python/config_validator.py with the real jaxrl project.
  use ExUnit.Case, async: false

  alias JaxrlDashboard.Configs.PythonValidator
  alias JaxrlDashboard.Runs.Settings

  @moduletag :jaxrl

  setup_all do
    start_supervised!(PythonValidator)
    config = Path.join(Settings.config_dir(), "return.json") |> File.read!() |> Jason.decode!()
    %{config: config}
  end

  test "serves the config schema and every registered environment's schema" do
    assert {:ok, %{"config" => config, "environments" => environments}} = PythonValidator.schema()
    assert config["title"] == "Config"
    assert "max_env_steps" in config["x-order"]
    assert Map.has_key?(environments, "rust_find_return")
    assert Map.has_key?(environments, "craftax")
  end

  test "the snapshot the other tests use matches jaxrl's current schema" do
    {:ok, live} = PythonValidator.schema()
    {:ok, snapshot} = JaxrlDashboard.FakeConfigValidator.schema()

    assert live == snapshot,
           "jaxrl's config models changed; run `mix run priv/python/dump_schema.exs`"
  end

  test "accepts a valid config", %{config: config} do
    assert PythonValidator.validate(config) == {:ok, []}
  end

  test "reports problems at their paths in the config", %{config: config} do
    config =
      config
      |> put_in(~w(learner model num_layers), 2.5)
      |> put_in(~w(learner optimizer typo), 1)
      |> update_in(~w(learner model obs_encoder), &Map.delete(&1, "kernels"))

    {:ok, errors} = PythonValidator.validate(config)

    assert %{path: ~w(learner model num_layers), message: "Input should be a valid integer"} in errors

    assert %{path: ~w(learner optimizer typo), message: "Extra inputs are not permitted"} in errors

    # Union tags (obs_type=grid_cnn) are dropped from paths.
    assert %{path: ~w(learner model obs_encoder kernels), message: "Field required"} in errors
  end

  test "validates environments against the model they registered", %{config: config} do
    bad_nested = put_in(config, ~w(environment env num_agents), "eight")
    {:ok, errors} = PythonValidator.validate(bad_nested)
    assert Enum.any?(errors, &(&1.path == ~w(environment env num_agents)))

    unknown = put_in(config, ~w(environment env_type), "nope")
    {:ok, errors} = PythonValidator.validate(unknown)

    assert Enum.any?(
             errors,
             &(&1.path == ~w(environment env_type) and
                 &1.message =~ "Unknown environment type 'nope'")
           )
  end

  test "formats a config the way jaxrl writes it", %{config: config} do
    {:ok, json} = PythonValidator.format(config)
    assert json =~ ~s("num_checkpoints": 5)
    assert Jason.decode!(json)["max_env_steps"] == config["max_env_steps"]
  end
end
