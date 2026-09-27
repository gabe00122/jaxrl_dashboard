defmodule JaxrlDashboard.Configs.PythonValidatorTest do
  # Runs each project's validator script with the real project checkout.
  use ExUnit.Case, async: false

  alias JaxrlDashboard.Configs.PythonValidator
  alias JaxrlDashboard.Projects

  setup_all do
    Enum.each(PythonValidator.child_specs(), &start_supervised!/1)
    :ok
  end

  defp read_config(project, file) do
    Path.join(project.config_dir, file) |> File.read!() |> Jason.decode!()
  end

  describe "jaxrl" do
    @describetag :jaxrl

    setup do
      project = Projects.get!("jaxrl")
      %{project: project, config: read_config(project, "return.json")}
    end

    test "serves the config schema and every registered environment's schema", %{
      project: project
    } do
      assert {:ok, %{"config" => config, "environments" => environments}} =
               PythonValidator.schema(project)

      assert config["title"] == "Config"
      assert "max_env_steps" in config["x-order"]
      assert Map.has_key?(environments, "rust_find_return")
      assert Map.has_key?(environments, "craftax")
    end

    test "the snapshot the other tests use matches jaxrl's current schema", %{project: project} do
      {:ok, live} = PythonValidator.schema(project)
      {:ok, snapshot} = JaxrlDashboard.FakeConfigValidator.schema(project)

      assert live == snapshot,
             "jaxrl's config models changed; run `mix run --no-start priv/python/dump_schema.exs`"
    end

    test "accepts a valid config", %{project: project, config: config} do
      assert PythonValidator.validate(project, config) == {:ok, []}
    end

    test "reports problems at their paths in the config", %{project: project, config: config} do
      config =
        config
        |> put_in(~w(learner model num_layers), 2.5)
        |> put_in(~w(learner optimizer typo), 1)
        |> update_in(~w(learner model obs_encoder), &Map.delete(&1, "kernels"))

      {:ok, errors} = PythonValidator.validate(project, config)

      assert %{path: ~w(learner model num_layers), message: "Input should be a valid integer"} in errors

      assert %{path: ~w(learner optimizer typo), message: "Extra inputs are not permitted"} in errors

      # Union tags (obs_type=grid_cnn) are dropped from paths.
      assert %{path: ~w(learner model obs_encoder kernels), message: "Field required"} in errors
    end

    test "validates environments against the model they registered", %{
      project: project,
      config: config
    } do
      bad_nested = put_in(config, ~w(environment env num_agents), "eight")
      {:ok, errors} = PythonValidator.validate(project, bad_nested)
      assert Enum.any?(errors, &(&1.path == ~w(environment env num_agents)))

      unknown = put_in(config, ~w(environment env_type), "nope")
      {:ok, errors} = PythonValidator.validate(project, unknown)

      assert Enum.any?(
               errors,
               &(&1.path == ~w(environment env_type) and
                   &1.message =~ "Unknown environment type 'nope'")
             )
    end

    test "formats a config the way jaxrl writes it", %{project: project, config: config} do
      {:ok, json} = PythonValidator.format(project, config)
      assert json =~ ~s("num_checkpoints": 5)
      assert Jason.decode!(json)["max_env_steps"] == config["max_env_steps"]
    end
  end

  describe "llm_rl" do
    @describetag :llm_rl

    setup do
      project = Projects.get!("llm_rl")
      %{project: project, config: read_config(project, "grpo.json")}
    end

    test "serves the config schema, with no separate environment schemas", %{project: project} do
      assert {:ok, %{"config" => config, "environments" => environments}} =
               PythonValidator.schema(project)

      assert config["title"] == "Config"
      assert "total_update_episodes" in config["x-order"]
      assert environments == %{}
    end

    test "the snapshot the other tests use matches llm_rl's current schema", %{project: project} do
      {:ok, live} = PythonValidator.schema(project)
      {:ok, snapshot} = JaxrlDashboard.FakeConfigValidator.schema(project)

      assert live == snapshot,
             "llm_rl's config models changed; run `mix run --no-start priv/python/dump_schema.exs`"
    end

    test "accepts a valid config", %{project: project, config: config} do
      assert PythonValidator.validate(project, config) == {:ok, []}
    end

    test "reports problems at their paths in the config", %{project: project, config: config} do
      config =
        config
        |> put_in(~w(lora rank), "big")
        |> put_in(~w(loss typo), 1)
        |> update_in(~w(env), &Map.delete(&1, "max_guesses"))

      {:ok, errors} = PythonValidator.validate(project, config)

      assert %{path: ~w(lora rank), message: "Input should be a valid integer"} in errors
      # Union tags (loss type=grpo, env name=wordle) are dropped from paths.
      assert %{path: ~w(loss typo), message: "Extra inputs are not permitted"} in errors
      assert %{path: ~w(env max_guesses), message: "Field required"} in errors
    end

    test "reports config-wide checks at the root", %{project: project, config: config} do
      {:ok, errors} = PythonValidator.validate(project, %{config | "eval_envs" => 63})
      assert Enum.any?(errors, &(&1.path == [] and &1.message =~ "multiple of group_size"))
    end

    test "formats a config the way valm writes it, keeping a random seed", %{
      project: project,
      config: config
    } do
      {:ok, json} = PythonValidator.format(project, config)
      formatted = Jason.decode!(json)
      assert formatted["seed"] == "random"
      assert formatted["logger"]["use_tb"] == false
    end
  end
end
