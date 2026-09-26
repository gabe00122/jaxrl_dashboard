defmodule JaxrlDashboard.Runs.WatcherTest do
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.AccountsFixtures
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.{Metrics, Runs}
  alias JaxrlDashboard.Runs.{Scheduler, Settings, Watcher}

  setup :setup_run_dirs

  describe "a watcher on its own" do
    setup do
      name = "watched"
      File.mkdir_p!(Settings.experiment_dir(name))
      File.mkdir_p!(Settings.job_dir(name))
      Runs.subscribe_run(name)
      %{name: name}
    end

    test "broadcasts metrics rows and output lines as they're appended", %{name: name} do
      {:ok, _} = Watcher.start(name)

      File.write!(Metrics.path(name), ~s({"step": 0, "loss": 1.0}\n))
      File.write!(Settings.output_path(name), "hello\n")

      assert_receive {:metrics, ^name, [%{step: 0, values: %{"loss" => 1.0}}]}
      assert_receive {:output, ^name, [{0, "hello"}]}

      # A half-written row is only sent once it's complete.
      File.write!(Metrics.path(name), ~s({"step": 1, "lo), [:append])
      refute_receive {:metrics, ^name, _}, 100
      File.write!(Metrics.path(name), ~s(ss": 0.5}\n), [:append])
      assert_receive {:metrics, ^name, [%{step: 1, values: %{"loss" => 0.5}}]}
    end

    test "sends existing metrics from the start and output from its tail", %{name: name} do
      File.write!(Metrics.path(name), ~s({"step": 0, "loss": 1.0}\n{"step": 1, "loss": 2.0}\n))
      File.write!(Settings.output_path(name), "old output\n")

      {:ok, _} = Watcher.start(name)

      assert_receive {:metrics, ^name, [%{step: 0}, %{step: 1}]}
      # Viewers read the output tail themselves; the watcher only sends new lines.
      refute_receive {:output, ^name, _}, 100
    end

    test "flushes unterminated last lines when stopped", %{name: name} do
      {:ok, _} = Watcher.start(name)
      File.write!(Settings.output_path(name), "no newline")
      refute_receive {:output, ^name, _}, 100

      :ok = Watcher.stop(name)

      assert_receive {:output, ^name, [{0, "no newline"}]}
      # The Registry drops the name asynchronously once the process exits.
      wait_until(fn -> Watcher.watched_names() == [] end)
    end

    test "start is idempotent and reconcile matches the given runs", %{name: name} do
      {:ok, pid} = Watcher.start(name)
      assert {:ok, ^pid} = Watcher.start(name)

      Watcher.reconcile(["other"])
      wait_until(fn -> Watcher.watched_names() == ["other"] end)
      refute Process.alive?(pid)
    end
  end

  test "the scheduler watches runs while they run and streams their metrics" do
    scope = Scope.for_user(user_fixture())
    source = write_config("steps.json", %{"fake_steps" => 5, "fake_sleep" => 0.3})
    {:ok, run} = Runs.enqueue_run(scope, %{"config_source" => source})
    Runs.subscribe_run(run.name)
    name = run.name

    start_supervised!(Scheduler)

    wait_until(fn -> Watcher.watched_names() == [name] end)

    # All five rows arrive in order, however they're batched.
    assert collect_steps(name, []) == [0, 1, 2, 3, 4]
    assert_receive {:output, ^name, _lines}, 2_000

    wait_until(fn -> Runs.get_run!(run.id).status == :succeeded end)
    wait_until(fn -> Watcher.watched_names() == [] end)
  end

  defp collect_steps(_name, steps) when length(steps) >= 5, do: steps

  defp collect_steps(name, steps) do
    receive do
      {:metrics, ^name, rows} -> collect_steps(name, steps ++ Enum.map(rows, & &1.step))
    after
      3_000 -> flunk("only received steps #{inspect(steps)}")
    end
  end
end
