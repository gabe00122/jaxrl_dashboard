defmodule JaxrlDashboard.Runs.Scheduler do
  @moduledoc """
  Starts queued runs and watches running ones.

  On every tick it:

    1. checks each `:running` run's process: finished runs get their final
       status from the exit code, and cancelled runs are signalled
    2. starts queued runs while fewer than `max_concurrent` are running
    3. starts or stops `JaxrlDashboard.Runs.Watcher`s to match the running runs

  All state lives in the database and the runs' job directories, so a
  restarted scheduler simply picks up where the last one left off, including
  runs that kept going while the dashboard was down.
  """

  use GenServer
  require Logger

  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.{Launcher, Run, Settings, Watcher}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Triggers a tick now instead of waiting for the next poll."
  def poke do
    if pid = Process.whereis(__MODULE__), do: send(pid, :tick)
    :ok
  end

  @impl true
  def init(_opts) do
    # Finish the current tick before shutting down rather than dying mid-query.
    Process.flag(:trap_exit, true)
    send(self(), :tick)
    # Run ids already sent SIGTERM, so it's sent once per cancellation.
    {:ok, %{timer: nil, terminated: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    state = check_running_runs(state)
    start_queued_runs()
    Watcher.reconcile(for run <- Runs.list_running_runs(), run.pid, do: run.name)

    {:noreply, %{state | timer: Process.send_after(self(), :tick, Settings.get(:poll_interval))}}
  end

  # Trapping exits means ports opened by System.cmd report their exit here.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  defp check_running_runs(state) do
    Enum.reduce(Runs.list_running_runs(), state, &check_run/2)
  end

  # Claimed but no pid recorded: the previous scheduler stopped mid-launch.
  # Adopt the process if the wrapper got as far as writing its pid file.
  defp check_run(%Run{pid: nil} = run, state) do
    case Launcher.read_pid(run) do
      {:ok, pid} ->
        {:ok, run} = Runs.mark_started(run, pid)
        check_run(run, state)

      :error ->
        Runs.mark_finished(run, :lost, error: "launch was interrupted before the process started")
        state
    end
  end

  defp check_run(%Run{} = run, state) do
    if Launcher.alive?(run) do
      maybe_stop(run, state)
    else
      finish(run)
      %{state | terminated: MapSet.delete(state.terminated, run.id)}
    end
  end

  defp maybe_stop(%Run{cancel_requested_at: nil}, state), do: state

  defp maybe_stop(%Run{} = run, state) do
    waited_ms = DateTime.diff(DateTime.utc_now(), run.cancel_requested_at, :millisecond)

    cond do
      waited_ms >= Settings.get(:kill_grace_period) ->
        Logger.warning("Run #{run.name} ignored SIGTERM, sending SIGKILL")
        Launcher.signal(run, "KILL")
        state

      MapSet.member?(state.terminated, run.id) ->
        state

      true ->
        Launcher.signal(run, "TERM")
        %{state | terminated: MapSet.put(state.terminated, run.id)}
    end
  end

  defp finish(%Run{} = run) do
    exit_code =
      case Launcher.read_exit_code(run) do
        {:ok, code} -> code
        :error -> nil
      end

    cond do
      run.cancel_requested_at ->
        Runs.mark_finished(run, :cancelled, exit_code: exit_code)

      exit_code == 0 ->
        Runs.mark_finished(run, :succeeded, exit_code: 0)

      exit_code ->
        Runs.mark_finished(run, :failed,
          exit_code: exit_code,
          error: "training exited with code #{exit_code}"
        )

      true ->
        Runs.mark_finished(run, :lost,
          error:
            "process ended without an exit code (killed, out of memory, or machine restarted)"
        )
    end
  end

  defp start_queued_runs do
    if Runs.count_running_runs() < Settings.get(:max_concurrent) do
      case Runs.claim_next_queued_run() do
        nil ->
          :ok

        run ->
          start_run(run)
          start_queued_runs()
      end
    end
  end

  defp start_run(run) do
    case Launcher.launch(run) do
      {:ok, pid} ->
        Logger.info("Started run #{run.name} (pid #{pid})")
        Runs.mark_started(run, pid)

      {:error, reason} ->
        Logger.error("Could not start run #{run.name}: #{reason}")
        Runs.mark_finished(run, :failed, error: "could not start: #{reason}")
    end
  end
end
