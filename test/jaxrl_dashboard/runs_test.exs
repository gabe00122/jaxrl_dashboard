defmodule JaxrlDashboard.RunsTest do
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.AccountsFixtures
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.{Run, Settings}

  setup :setup_run_dirs

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  describe "enqueue_run/2" do
    test "snapshots the config and generates a name", %{scope: scope} do
      write_config("Best_Jax 6L.json", %{"seed" => 7})
      Runs.subscribe()

      assert {:ok, run} = Runs.enqueue_run(scope, %{"config_source" => "Best_Jax 6L.json"})

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
               Runs.enqueue_run(scope, %{"config_source" => "a.json", "name" => "my_run-2"})
    end

    test "only accepts files from the config directory", %{scope: scope} do
      for source <- ["missing.json", "../config/a.json", "/etc/passwd"] do
        assert {:error, changeset} = Runs.enqueue_run(scope, %{"config_source" => source})

        assert "is not a config file in the jaxrl config directory" in errors_on(changeset).config_source
      end
    end

    test "rejects configs that aren't a JSON object", %{scope: scope} do
      File.write!(Path.join(Settings.config_dir(), "broken.json"), "{not json")
      File.write!(Path.join(Settings.config_dir(), "list.json"), "[1, 2]")

      assert {:error, cs} = Runs.enqueue_run(scope, %{"config_source" => "broken.json"})
      assert "is not valid JSON" in errors_on(cs).config_source
      assert {:error, cs} = Runs.enqueue_run(scope, %{"config_source" => "list.json"})
      assert "is not a JSON object" in errors_on(cs).config_source
    end

    test "rejects unsafe or taken names", %{scope: scope} do
      write_config("a.json")
      File.mkdir_p!(Settings.experiment_dir("old-run"))
      {:ok, _} = Runs.enqueue_run(scope, %{"config_source" => "a.json", "name" => "taken"})

      for {name, error} <- [
            {"../escape", "use lowercase letters, digits, dashes and underscores"},
            {"Has Space", "use lowercase letters, digits, dashes and underscores"},
            {"--flag", "use lowercase letters, digits, dashes and underscores"},
            {"old-run", "already exists in the jaxrl results directory"},
            {"taken", "has already been taken"}
          ] do
        assert {:error, cs} =
                 Runs.enqueue_run(scope, %{"config_source" => "a.json", "name" => name})

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

      assert {:error, changeset} = Runs.enqueue_run(scope, %{"config_source" => "stale.json"})

      assert [message] = errors_on(changeset).config_source
      assert message == "is invalid: learner.trainer.vf_clip: Extra inputs are not permitted"
    end

    test "enqueue_config_run queues a built config", %{scope: scope} do
      assert {:ok, run} =
               Runs.enqueue_config_run(scope, %{
                 "config" => %{"seed" => 5},
                 "config_source" => "best.json (edited)"
               })

      assert run.config == %{"seed" => 5}
      assert run.name =~ ~r/^best-[a-z2-7]{4}$/
      assert run.status == :queued
    end

    test "enqueue_config_run names configs without a source 'custom'", %{scope: scope} do
      assert {:ok, %Run{name: "custom-" <> _}} =
               Runs.enqueue_config_run(scope, %{"config" => %{}})
    end

    test "enqueue_config_run refuses invalid configs", %{scope: scope} do
      JaxrlDashboard.FakeConfigValidator.put_errors(fn _ ->
        [%{path: ["seed"], message: "bad"}, %{path: ["max_env_steps"], message: "Field required"}]
      end)

      assert {:error, changeset} = Runs.enqueue_config_run(scope, %{"config" => %{"seed" => "?"}})
      assert errors_on(changeset).config == ["is invalid: seed: bad (and 1 more)"]
    end
  end

  describe "cancel_run/1" do
    test "cancels a queued run immediately", %{scope: scope} do
      write_config("a.json")
      {:ok, run} = Runs.enqueue_run(scope, %{"config_source" => "a.json"})

      assert {:ok, %Run{status: :cancelled, finished_at: %DateTime{}}} = Runs.cancel_run(run)
      assert Runs.claim_next_queued_run() == nil
    end

    test "refuses finished runs", %{scope: scope} do
      write_config("a.json")
      {:ok, run} = Runs.enqueue_run(scope, %{"config_source" => "a.json"})
      {:ok, run} = Runs.cancel_run(run)

      assert Runs.cancel_run(run) == {:error, :already_finished}
    end
  end

  test "claim_next_queued_run/0 takes the oldest run first", %{scope: scope} do
    write_config("a.json")
    {:ok, first} = Runs.enqueue_run(scope, %{"config_source" => "a.json"})
    {:ok, second} = Runs.enqueue_run(scope, %{"config_source" => "a.json"})

    assert %Run{id: id, status: :running, started_at: %DateTime{}} = Runs.claim_next_queued_run()
    assert id == first.id
    assert Runs.claim_next_queued_run().id == second.id
    assert Runs.claim_next_queued_run() == nil
  end

  describe "import_existing_runs/0" do
    defp make_result_dir(name, files) do
      dir = Settings.experiment_dir(name)
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
      File.write!(Path.join(Settings.results_dir(), "README.md"), "hi")

      # A dashboard run's results dir must not be imported a second time.
      write_config("a.json")
      {:ok, _} = Runs.enqueue_run(scope, %{"config_source" => "a.json", "name" => "mine"})
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
end
