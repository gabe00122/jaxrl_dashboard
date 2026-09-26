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
end
