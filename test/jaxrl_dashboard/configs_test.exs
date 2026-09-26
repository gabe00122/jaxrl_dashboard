defmodule JaxrlDashboard.ConfigsTest do
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.{Configs, FakeConfigValidator}
  alias JaxrlDashboard.Runs.Settings

  setup :setup_run_dirs

  setup do
    {:ok, schema} = Configs.schema()
    %{schema: schema}
  end

  describe "load_source/2" do
    test "loads a config file", %{schema: schema} do
      write_config("base.json", %{"max_env_steps" => 64})

      assert Configs.load_source("file:base.json", schema) ==
               {:ok, %{"max_env_steps" => 64}, "base.json"}
    end

    test "only loads files from the config directory", %{schema: schema} do
      assert Configs.load_source("file:../etc/passwd", schema) == {:error, :not_found}
      assert Configs.load_source("file:missing.json", schema) == {:error, :not_found}
    end

    test "loads a run's config", %{schema: schema} do
      dir = Settings.experiment_dir("old")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "config.json"), ~s({"seed": 3}))
      JaxrlDashboard.Runs.import_existing_runs()

      assert Configs.load_source("run:old", schema) == {:ok, %{"seed" => 3}, "old"}
      assert Configs.load_source("run:nope", schema) == {:error, :not_found}
    end

    test "starts a new config from the schema", %{schema: schema} do
      assert {:ok, %{"learner" => _}, nil} = Configs.load_source(nil, schema)
    end
  end

  describe "save_file/2" do
    test "writes a new file in the config directory" do
      assert Configs.save_file("my_config", %{"seed" => 1}) == {:ok, "my_config.json"}
      path = Path.join(Settings.config_dir(), "my_config.json")
      assert Jason.decode!(File.read!(path)) == %{"seed" => 1}
      assert "my_config.json" in Settings.config_files()
    end

    test "never overwrites a file" do
      write_config("taken.json", %{"keep" => true})

      assert Configs.save_file("taken.json", %{"seed" => 1}) ==
               {:error, "taken.json already exists"}

      assert File.read!(Path.join(Settings.config_dir(), "taken.json")) =~ "keep"
    end

    test "rejects file names that could escape the config directory" do
      for name <- ["../x", "a/b", ".hidden", "", "has space"] do
        assert {:error, "use letters" <> _} = Configs.save_file(name, %{})
      end
    end

    test "refuses invalid configs" do
      FakeConfigValidator.put_errors(fn _ -> [%{path: ["seed"], message: "bad"}] end)
      assert {:error, "the config has problems" <> _} = Configs.save_file("x", %{"seed" => "?"})
      refute File.exists?(Path.join(Settings.config_dir(), "x.json"))
    end
  end
end
