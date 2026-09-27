defmodule JaxrlDashboard.RunsTest do
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.AccountsFixtures
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.Run

  # A minimal llm_rl config: enough for its stages and logging to be read.
  @llm_rl_config %{"loss" => %{"type" => "grpo"}, "logger" => %{"use_jsonl" => true}}

  defp ppo_config, do: put_in(@llm_rl_config, ~w(loss type), "ppo")

  setup :setup_run_dirs

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  describe "enqueue_run/2" do
    test "snapshots the config and generates a name", %{scope: scope} do
      write_config("Best_Jax 6L.json", %{"seed" => 7})
      Runs.subscribe()

      assert {:ok, run} =
               Runs.enqueue_run(scope, %{
                 "project" => "jaxrl",
                 "config_source" => "Best_Jax 6L.json"
               })

      assert run.status == :queued
      assert run.config == %{"seed" => 7}
      assert run.name =~ ~r/^best-jax-6l-[a-z2-7]{4}$/
      assert run.user.id == scope.user.id
      assert_receive {:run_created, %Run{id: id}}
      assert id == run.id
    end

    test "uses a given name", %{scope: scope} do
      write_config("a.json")

      assert {:ok, %Run{name: "my_run-2"}} =
               Runs.enqueue_run(scope, %{
                 "project" => "jaxrl",
                 "config_source" => "a.json",
                 "name" => "my_run-2"
               })
    end

    test "only accepts files from the config directory", %{scope: scope} do
      for source <- ["missing.json", "../config/a.json", "/etc/passwd"] do
        assert {:error, changeset} =
                 Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => source})

        assert "is not a config file in jaxrl's config directory" in errors_on(changeset).config_source
      end
    end

    test "rejects configs that aren't a JSON object", %{scope: scope} do
      File.write!(Path.join(config_dir(), "broken.json"), "{not json")
      File.write!(Path.join(config_dir(), "list.json"), "[1, 2]")

      assert {:error, cs} =
               Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "broken.json"})

      assert "is not valid JSON" in errors_on(cs).config_source

      assert {:error, cs} =
               Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "list.json"})

      assert "is not a JSON object" in errors_on(cs).config_source
    end

    test "rejects unsafe or taken names", %{scope: scope} do
      write_config("a.json")
      File.mkdir_p!(experiment_dir("old-run"))

      {:ok, _} =
        Runs.enqueue_run(scope, %{
          "project" => "jaxrl",
          "config_source" => "a.json",
          "name" => "taken"
        })

      for {name, error} <- [
            {"../escape", "use lowercase letters, digits, dashes and underscores"},
            {"Has Space", "use lowercase letters, digits, dashes and underscores"},
            {"--flag", "use lowercase letters, digits, dashes and underscores"},
            {"old-run", "already exists in jaxrl's results directory"},
            {"taken", "has already been taken"}
          ] do
        assert {:error, cs} =
                 Runs.enqueue_run(scope, %{
                   "project" => "jaxrl",
                   "config_source" => "a.json",
                   "name" => name
                 })

        assert error in errors_on(cs).name, "expected #{inspect(name)} to be rejected"
      end
    end
  end

  describe "validation against jaxrl's config models" do
    test "enqueue_run refuses config files that don't validate", %{scope: scope} do
      write_config("stale.json", %{"vf_clip" => 1})

      JaxrlDashboard.FakeConfigValidator.put_errors(fn
        %{"vf_clip" => _} ->
          [%{path: ~w(learner trainer vf_clip), message: "Extra inputs are not permitted"}]

        _ ->
          []
      end)

      assert {:error, changeset} =
               Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "stale.json"})

      assert [message] = errors_on(changeset).config_source
      assert message == "is invalid: learner.trainer.vf_clip: Extra inputs are not permitted"
    end

    test "enqueue_config_run queues a built config", %{scope: scope} do
      assert {:ok, run} =
               Runs.enqueue_config_run(scope, %{
                 "project" => "jaxrl",
                 "config" => %{"seed" => 5},
                 "config_source" => "best.json (edited)"
               })

      assert run.config == %{"seed" => 5}
      assert run.name =~ ~r/^best-[a-z2-7]{4}$/
      assert run.status == :queued
    end

    test "enqueue_config_run names configs without a source 'custom'", %{scope: scope} do
      assert {:ok, %Run{name: "custom-" <> _}} =
               Runs.enqueue_config_run(scope, %{"project" => "jaxrl", "config" => %{}})
    end

    test "enqueue_config_run refuses invalid configs", %{scope: scope} do
      JaxrlDashboard.FakeConfigValidator.put_errors(fn _ ->
        [%{path: ["seed"], message: "bad"}, %{path: ["max_env_steps"], message: "Field required"}]
      end)

      assert {:error, changeset} =
               Runs.enqueue_config_run(scope, %{
                 "project" => "jaxrl",
                 "config" => %{"seed" => "?"}
               })

      assert errors_on(changeset).config == ["is invalid: seed: bad (and 1 more)"]
    end
  end

  describe "cancel_run/1" do
    test "cancels a queued run immediately", %{scope: scope} do
      write_config("a.json")
      {:ok, run} = Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "a.json"})

      assert {:ok, %Run{status: :cancelled, finished_at: %DateTime{}}} = Runs.cancel_run(run)
      assert Runs.claim_next_queued_run() == nil
    end

    test "refuses finished runs", %{scope: scope} do
      write_config("a.json")
      {:ok, run} = Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "a.json"})
      {:ok, run} = Runs.cancel_run(run)

      assert Runs.cancel_run(run) == {:error, :already_finished}
    end
  end

  test "claim_next_queued_run/0 takes the oldest run first", %{scope: scope} do
    write_config("a.json")
    {:ok, first} = Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "a.json"})
    {:ok, second} = Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "a.json"})

    assert %Run{id: id, status: :running, started_at: %DateTime{}} = Runs.claim_next_queued_run()
    assert id == first.id
    assert Runs.claim_next_queued_run().id == second.id
    assert Runs.claim_next_queued_run() == nil
  end

  describe "import_existing_runs/0" do
    defp make_result_dir(name, files) do
      dir = experiment_dir(name)
      File.mkdir_p!(dir)
      for {file, contents} <- files, do: File.write!(Path.join(dir, file), contents)
      dir
    end

    test "imports runs from the results dir with their config and timing" do
      dir =
        make_result_dir("old-run", %{
          "config.json" => ~s({"seed": 3}),
          "meta.json" =>
            ~s({"config_file": "./config/return.json", "start_time": "2026-07-19T22:51:46.728641Z", "git_hash": "abc"}),
          "logs.jsonl" => ~s({"step": 0}\n)
        })

      File.touch!(Path.join(dir, "logs.jsonl"), 1_784_600_000)
      Runs.subscribe()

      assert {["old-run"], []} = Runs.import_existing_runs()

      run = Runs.get_run_by_name!("old-run")
      assert run.status == :imported
      assert run.config == %{"seed" => 3}
      assert run.config_source == "return.json"
      assert run.started_at == ~U[2026-07-19 22:51:46Z]
      assert run.inserted_at == ~U[2026-07-19 22:51:46Z]
      assert run.finished_at == DateTime.from_unix!(1_784_600_000)
      assert run.user_id == nil
      assert_receive {:run_created, %Run{name: "old-run"}}
    end

    test "is idempotent and skips things that aren't runs", %{scope: scope} do
      make_result_dir("run-a", %{"config.json" => "{}"})
      make_result_dir("no-config", %{"logs.jsonl" => ""})
      make_result_dir("Bad Name", %{"config.json" => "{}"})
      make_result_dir("broken", %{"config.json" => "{nope"})
      File.write!(Path.join(results_dir(), "README.md"), "hi")

      # A dashboard run's results dir must not be imported a second time.
      write_config("a.json")

      {:ok, _} =
        Runs.enqueue_run(scope, %{
          "project" => "jaxrl",
          "config_source" => "a.json",
          "name" => "mine"
        })

      make_result_dir("mine", %{"config.json" => "{}"})

      assert {["run-a"], skipped} = Runs.import_existing_runs()
      assert [{"Bad Name", _}, {"broken", "config.json is not valid JSON"}] = skipped

      assert {[], _} = Runs.import_existing_runs()
    end

    test "imported runs can't be cancelled and aren't scheduled" do
      make_result_dir("done", %{"config.json" => "{}"})
      Runs.import_existing_runs()

      assert Runs.cancel_run(Runs.get_run_by_name!("done")) == {:error, :already_finished}
      assert Runs.claim_next_queued_run() == nil
    end
  end

  describe "projects" do
    test "a run must be in a known project", %{scope: scope} do
      write_config("a.json")

      assert {:error, cs} = Runs.enqueue_run(scope, %{"config_source" => "a.json"})
      assert "can't be blank" in errors_on(cs).project

      assert {:error, cs} =
               Runs.enqueue_run(scope, %{"project" => "nope", "config_source" => "a.json"})

      assert "is not a known project" in errors_on(cs).project

      assert {:error, cs} =
               Runs.enqueue_config_run(scope, %{"project" => "nope", "config" => %{}})

      assert "is not a known project" in errors_on(cs).project
    end

    test "config files come from the run's own project", %{scope: scope} do
      write_config("only_jaxrl.json")
      write_config("grpo.json", @llm_rl_config, "llm_rl")

      assert {:error, cs} =
               Runs.enqueue_run(scope, %{
                 "project" => "llm_rl",
                 "config_source" => "only_jaxrl.json"
               })

      assert "is not a config file in llm_rl's config directory" in errors_on(cs).config_source

      assert {:ok, run} =
               Runs.enqueue_run(scope, %{"project" => "llm_rl", "config_source" => "grpo.json"})

      assert run.project == "llm_rl"
      assert run.name =~ ~r/^grpo-/
    end

    test "llm_rl configs are queued with the logging the dashboard reads", %{scope: scope} do
      config = put_in(@llm_rl_config, ~w(logger), %{"use_jsonl" => false, "use_tui" => true})
      write_config("quiet.json", config, "llm_rl")

      {:ok, run} =
        Runs.enqueue_run(scope, %{"project" => "llm_rl", "config_source" => "quiet.json"})

      assert run.config["logger"] == %{"use_jsonl" => true, "use_tui" => false}

      {:ok, run} = Runs.enqueue_config_run(scope, %{"project" => "llm_rl", "config" => config})
      assert run.config["logger"] == %{"use_jsonl" => true, "use_tui" => false}
    end

    test "names that would reuse a stage's results dir are taken", %{scope: scope} do
      write_config("ppo.json", ppo_config(), "llm_rl")
      write_config("grpo.json", @llm_rl_config, "llm_rl")
      File.mkdir_p!(experiment_dir("again-value", "llm_rl"))

      # A PPO run writes its value warmup stage to NAME-value.
      assert {:error, cs} =
               Runs.enqueue_run(scope, %{
                 "project" => "llm_rl",
                 "config_source" => "ppo.json",
                 "name" => "again"
               })

      assert "would write to again-value, which already exists in llm_rl's results directory" in errors_on(
               cs
             ).name

      assert {:error, cs} =
               Runs.enqueue_config_run(scope, %{
                 "project" => "llm_rl",
                 "config" => ppo_config(),
                 "name" => "again"
               })

      assert errors_on(cs).name != []

      # GRPO has no value stage.
      assert {:ok, _} =
               Runs.enqueue_run(scope, %{
                 "project" => "llm_rl",
                 "config_source" => "grpo.json",
                 "name" => "again"
               })
    end

    test "imports every project's runs, but not a known run's stages", %{scope: scope} do
      for {project, name} <- [{"jaxrl", "grid-run"}, {"llm_rl", "llm-run"}] do
        File.mkdir_p!(experiment_dir(name, project))
        File.write!(Path.join(experiment_dir(name, project), "config.json"), "{}")
      end

      # The dashboard's own PPO run: its value stage belongs to it.
      write_config("ppo.json", ppo_config(), "llm_rl")

      {:ok, _} =
        Runs.enqueue_run(scope, %{
          "project" => "llm_rl",
          "config_source" => "ppo.json",
          "name" => "mine"
        })

      for dir <- ["mine", "mine-value"] do
        File.mkdir_p!(experiment_dir(dir, "llm_rl"))
        File.write!(Path.join(experiment_dir(dir, "llm_rl"), "config.json"), "{}")
      end

      assert {["grid-run", "llm-run"], []} = Runs.import_existing_runs()
      assert Runs.get_run_by_name!("grid-run").project == "jaxrl"
      assert Runs.get_run_by_name!("llm-run").project == "llm_rl"

      assert Runs.count_runs_by_project() == %{"jaxrl" => 1, "llm_rl" => 2}

      assert ["llm-run", "mine"] =
               Runs.list_runs(project: "llm_rl") |> Enum.map(& &1.name) |> Enum.sort()
    end
  end
end
