defmodule JaxrlDashboard.ConfigsTest do
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.{Configs, FakeConfigValidator}

  setup :setup_run_dirs

  setup do
    {:ok, schema} = Configs.schema("jaxrl")
    %{schema: schema, jaxrl: project("jaxrl"), llm_rl: project("llm_rl")}
  end

  describe "load_source/3" do
    test "loads a config file", %{schema: schema, jaxrl: jaxrl} do
      write_config("base.json", %{"max_env_steps" => 64})

      assert Configs.load_source(jaxrl, "file:base.json", schema) ==
               {:ok, %{"max_env_steps" => 64}, "base.json"}
    end

    test "only loads files from the project's config directory", %{
      schema: schema,
      jaxrl: jaxrl,
      llm_rl: llm_rl
    } do
      write_config("base.json", %{"max_env_steps" => 64})

      assert Configs.load_source(jaxrl, "file:../etc/passwd", schema) == {:error, :not_found}
      assert Configs.load_source(jaxrl, "file:missing.json", schema) == {:error, :not_found}
      assert Configs.load_source(llm_rl, "file:base.json", schema) == {:error, :not_found}
    end

    test "loads a run's config, from the project's own runs", %{
      schema: schema,
      jaxrl: jaxrl,
      llm_rl: llm_rl
    } do
      dir = experiment_dir("old")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "config.json"), ~s({"seed": 3}))
      JaxrlDashboard.Runs.import_existing_runs()

      assert Configs.load_source(jaxrl, "run:old", schema) == {:ok, %{"seed" => 3}, "old"}
      assert Configs.load_source(jaxrl, "run:nope", schema) == {:error, :not_found}
      assert Configs.load_source(llm_rl, "run:old", schema) == {:error, :not_found}
    end

    test "starts a new config from the project's schema", %{schema: schema, jaxrl: jaxrl} do
      assert {:ok, %{"learner" => _}, nil} = Configs.load_source(jaxrl, nil, schema)

      {:ok, llm_rl_schema} = Configs.schema("llm_rl")

      assert {:ok, %{"loss" => %{"type" => "ppo"}, "env" => %{"name" => "arithmetic"}}, nil} =
               Configs.load_source(project("llm_rl"), nil, llm_rl_schema)
    end
  end

  describe "save_file/3" do
    test "writes a new file in the project's config directory", %{llm_rl: llm_rl} do
      assert Configs.save_file(llm_rl, "my_config", %{"seed" => 1}) == {:ok, "my_config.json"}
      path = Path.join(config_dir("llm_rl"), "my_config.json")
      assert Jason.decode!(File.read!(path)) == %{"seed" => 1}
      assert "my_config.json" in config_files("llm_rl")
      refute "my_config.json" in config_files("jaxrl")
    end

    test "never overwrites a file", %{jaxrl: jaxrl} do
      write_config("taken.json", %{"keep" => true})

      assert Configs.save_file(jaxrl, "taken.json", %{"seed" => 1}) ==
               {:error, "taken.json already exists"}

      assert File.read!(Path.join(config_dir(), "taken.json")) =~ "keep"
    end

    test "rejects file names that could escape the config directory", %{jaxrl: jaxrl} do
      for name <- ["../x", "a/b", ".hidden", "", "has space"] do
        assert {:error, "use letters" <> _} = Configs.save_file(jaxrl, name, %{})
      end
    end

    test "refuses invalid configs", %{jaxrl: jaxrl} do
      FakeConfigValidator.put_errors(fn _ -> [%{path: ["seed"], message: "bad"}] end)

      assert {:error, "the config has problems" <> _} =
               Configs.save_file(jaxrl, "x", %{"seed" => "?"})

      refute File.exists?(Path.join(config_dir(), "x.json"))
    end
  end
end
