defmodule JaxrlDashboard.Runs.SchedulerTest do
  # Runs real processes through run_job.sh and test/support/fake_train.sh.
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.AccountsFixtures
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.{Launcher, Scheduler, Settings}

  setup :setup_run_dirs

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  defp enqueue(scope, fake_config) do
    source = write_config("#{System.unique_integer([:positive])}.json", fake_config)
    {:ok, run} = Runs.enqueue_run(scope, %{"config_source" => source})
    run
  end

  defp reload(run), do: Runs.get_run!(run.id)

  defp wait_for_status(run, status, timeout \\ 5_000) do
    wait_until(fn -> (run = reload(run)).status == status && run end, timeout)
  end

  test "runs a job to completion", %{scope: scope} do
    run = enqueue(scope, %{"fake_sleep" => 0})
    start_supervised!(Scheduler)

    run = wait_for_status(run, :succeeded)

    assert run.exit_code == 0
    assert is_integer(run.pid)
    assert run.finished_at
    assert File.read!(Settings.output_path(run.name)) =~ "training #{run.name} from"
    # jaxrl writes its results into the results dir under the run's name.
    assert File.exists?(Path.join(Settings.experiment_dir(run.name), "logs.jsonl"))
  end

  test "marks non-zero exits as failed", %{scope: scope} do
    run = enqueue(scope, %{"fake_exit_code" => 3})
    start_supervised!(Scheduler)

    run = wait_for_status(run, :failed)
    assert run.exit_code == 3
    assert run.error == "training exited with code 3"
  end

  test "runs one job at a time, in queue order", %{scope: scope} do
    first = enqueue(scope, %{"fake_sleep" => 0.5})
    second = enqueue(scope, %{"fake_sleep" => 0})
    start_supervised!(Scheduler)

    wait_for_status(first, :running)
    assert reload(second).status == :queued

    first = wait_for_status(first, :succeeded)
    second = wait_for_status(second, :succeeded)
    assert DateTime.compare(second.started_at, first.finished_at) != :lt
  end

  test "cancelling a running job kills its process group", %{scope: scope} do
    run = enqueue(scope, %{"fake_sleep" => 60})
    start_supervised!(Scheduler)
    run = wait_until(fn -> (run = reload(run)).pid && run end)
    assert Launcher.alive?(run)

    {:ok, _} = Runs.cancel_run(run)

    run = wait_for_status(run, :cancelled)
    refute Launcher.alive?(run)
    # The fake trainer's `sleep` child is gone too, not just the wrapper.
    {pgrep, _} = System.cmd("pgrep", ["-g", "#{run.pid}"])
    assert pgrep == ""
  end

  test "escalates to SIGKILL when a job ignores SIGTERM", %{scope: scope} do
    put_run_setting(:train_command, [
      "bash",
      "-c",
      "trap '' TERM; sleep 60 & wait; sleep 60",
      "--"
    ])

    run = enqueue(scope, %{})
    start_supervised!(Scheduler)
    run = wait_until(fn -> (run = reload(run)).pid && run end)

    {:ok, _} = Runs.cancel_run(run)

    # kill_grace_period is 2s in tests.
    run = wait_for_status(run, :cancelled, 6_000)
    refute Launcher.alive?(run)
  end

  test "jobs keep running across a scheduler restart", %{scope: scope} do
    run = enqueue(scope, %{"fake_sleep" => 1})
    start_supervised!(Scheduler)
    run = wait_until(fn -> (run = reload(run)).pid && run end)

    stop_supervised!(Scheduler)
    assert Launcher.alive?(run)

    start_supervised!(Scheduler)
    assert wait_for_status(run, :succeeded).exit_code == 0
  end

  test "a job killed while the dashboard was down is marked lost", %{scope: scope} do
    run = enqueue(scope, %{"fake_sleep" => 60})
    start_supervised!(Scheduler)
    run = wait_until(fn -> (run = reload(run)).pid && run end)
    stop_supervised!(Scheduler)

    System.cmd("kill", ["-KILL", "--", "-#{run.pid}"])
    wait_until(fn -> not Launcher.alive?(run) end)
    start_supervised!(Scheduler)

    run = wait_for_status(run, :lost)
    assert run.error =~ "without an exit code"
  end

  test "a missing training command fails the run without starting anything", %{scope: scope} do
    put_run_setting(:train_command, [".venv/bin/pmarl", "train"])
    run = enqueue(scope, %{})
    start_supervised!(Scheduler)

    run = wait_for_status(run, :failed)
    assert run.error =~ "training command not found: .venv/bin/pmarl"
    assert run.pid == nil
  end
end
