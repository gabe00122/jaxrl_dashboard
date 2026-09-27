defmodule JaxrlDashboard.Runs.WatcherTest do
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.AccountsFixtures
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.{Metrics, Runs}
  alias JaxrlDashboard.Runs.{Run, Scheduler, Settings, Watcher}

  setup :setup_run_dirs

  # The watcher only needs what a run says about where it writes.
  defp running(name, project \\ "jaxrl", config \\ %{}),
    do: %Run{name: name, project: project, config: config, status: :running}

  defp logs(experiment, project \\ "jaxrl"), do: Metrics.path(experiment_dir(experiment, project))

  describe "a watcher on its own" do
    setup do
      name = "watched"
      File.mkdir_p!(experiment_dir(name))
      File.mkdir_p!(Settings.job_dir(name))
      Runs.subscribe_run(name)
      %{name: name, run: running(name)}
    end

    test "broadcasts metrics rows and output lines as they're appended", %{name: name, run: run} do
      {:ok, _} = Watcher.start(run)

      File.write!(logs(name), ~s({"step": 0, "loss": 1.0}\n))
      File.write!(Settings.output_path(name), "hello\n")

      assert_receive {:metrics, ^name, "train", [%{step: 0, values: %{"loss" => 1.0}}]}
      assert_receive {:output, ^name, [{0, "hello"}]}

      # A half-written row is only sent once it's complete.
      File.write!(logs(name), ~s({"step": 1, "lo), [:append])
      refute_receive {:metrics, ^name, _, _}, 100
      File.write!(logs(name), ~s(ss": 0.5}\n), [:append])
      assert_receive {:metrics, ^name, "train", [%{step: 1, values: %{"loss" => 0.5}}]}
    end

    test "sends existing metrics from the start and output from its tail", %{name: name, run: run} do
      File.write!(logs(name), ~s({"step": 0, "loss": 1.0}\n{"step": 1, "loss": 2.0}\n))
      File.write!(Settings.output_path(name), "old output\n")

      {:ok, _} = Watcher.start(run)

      assert_receive {:metrics, ^name, "train", [%{step: 0}, %{step: 1}]}
      # Viewers read the output tail themselves; the watcher only sends new lines.
      refute_receive {:output, ^name, _}, 100
    end

    test "follows each stage of a pipeline run in its own results dir" do
      name = "piped"
      run = running(name, "llm_rl", %{"loss" => %{"type" => "ppo"}})
      Runs.subscribe_run(name)
      {:ok, _} = Watcher.start(run)

      File.mkdir_p!(experiment_dir("piped-value", "llm_rl"))
      File.write!(logs("piped-value", "llm_rl"), ~s({"step": 0, "value_loss.mean": 1.0}\n))
      assert_receive {:metrics, ^name, "value", [%{step: 0}]}

      File.mkdir_p!(experiment_dir(name, "llm_rl"))
      File.write!(logs(name, "llm_rl"), ~s({"step": 0, "rewards.mean": 0.1}\n))
      assert_receive {:metrics, ^name, "rl", [%{step: 0, values: %{"rewards.mean" => 0.1}}]}
    end

    test "flushes unterminated last lines when stopped", %{name: name, run: run} do
      {:ok, _} = Watcher.start(run)
      File.write!(Settings.output_path(name), "no newline")
      refute_receive {:output, ^name, _}, 100

      :ok = Watcher.stop(name)

      assert_receive {:output, ^name, [{0, "no newline"}]}
      # The Registry drops the name asynchronously once the process exits.
      wait_until(fn -> Watcher.watched_names() == [] end)
    end

    test "start is idempotent and reconcile matches the given runs", %{run: run} do
      {:ok, pid} = Watcher.start(run)
      assert {:ok, ^pid} = Watcher.start(run)

      Watcher.reconcile([running("other")])
      wait_until(fn -> Watcher.watched_names() == ["other"] end)
      refute Process.alive?(pid)
    end
  end

  test "the scheduler watches runs while they run and streams their metrics" do
    scope = Scope.for_user(user_fixture())
    source = write_config("steps.json", %{"fake_steps" => 5, "fake_sleep" => 0.3})
    {:ok, run} = Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => source})
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
      {:metrics, ^name, "train", rows} -> collect_steps(name, steps ++ Enum.map(rows, & &1.step))
    after
      3_000 -> flunk("only received steps #{inspect(steps)}")
    end
  end
end
