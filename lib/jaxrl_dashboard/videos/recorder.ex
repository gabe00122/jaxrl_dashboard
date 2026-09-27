defmodule JaxrlDashboard.Videos.Recorder do
  @moduledoc """
  Starts video recordings and follows them until they finish.

  Starting goes through this process so the checks (recordable, not already
  recording, under `max_concurrent_recordings`) and the launch can't race.
  While any recording is in progress it polls them, broadcasting each
  run's `JaxrlDashboard.Videos.status/1` when it changes, and prunes old
  sets once a recording is done.

  Recordings are detached processes, like training runs; a restarted
  recorder adopts the ones still going.
  """

  use GenServer

  alias JaxrlDashboard.Videos
  alias JaxrlDashboard.Runs.{Run, Settings}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts recording the run. Returns `{:ok, status}` or `{:error, message}`
  with a message fit for showing to the user.
  """
  # Launching waits up to 5s for the job wrapper's pid file.
  def start(%Run{} = run), do: GenServer.call(__MODULE__, {:start, run}, 15_000)

  def cancel(name), do: GenServer.call(__MODULE__, {:cancel, name})

  @impl true
  def init(_opts) do
    # Trapping exits means ports opened by System.cmd report their exit here.
    Process.flag(:trap_exit, true)
    active = Map.new(Videos.recording_names(), &{&1, nil})
    {:ok, schedule(%{active: active, timer: nil})}
  end

  @impl true
  def handle_call({:start, run}, _from, state) do
    cond do
      not Videos.recordable?(run) ->
        {:reply, {:error, "Only runs on rust environments can be recorded."}, state}

      not Videos.has_checkpoint?(run.name) ->
        {:reply, {:error, "#{run.name} hasn't saved a checkpoint yet."}, state}

      Map.has_key?(state.active, run.name) ->
        {:reply, {:error, "#{run.name} is already being recorded."}, state}

      map_size(state.active) >= Settings.get(:max_concurrent_recordings) ->
        others = state.active |> Map.keys() |> Enum.join(", ")

        {:reply, {:error, "Already recording #{others}. Try again once that finishes."}, state}

      true ->
        case Videos.launch(run) do
          {:ok, _pid} ->
            status = Videos.status(run.name)
            Videos.broadcast(run.name, status)
            state = put_in(state.active[run.name], status)
            {:reply, {:ok, status}, schedule(state)}

          {:error, reason} ->
            status = Videos.status(run.name)
            Videos.broadcast(run.name, status)
            {:reply, {:error, "Couldn't start recording: #{reason}"}, state}
        end
    end
  end

  def handle_call({:cancel, name}, _from, state) do
    Videos.cancel(name)
    {:reply, :ok, poll(state)}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, poll(%{state | timer: nil})}

  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  defp poll(state) do
    active =
      Enum.reduce(state.active, state.active, fn {name, last}, active ->
        status = Videos.status(name)

        if status.state != :recording, do: Videos.prune(name)
        if status != last, do: Videos.broadcast(name, status)

        if status.state == :recording,
          do: Map.put(active, name, status),
          else: Map.delete(active, name)
      end)

    schedule(%{state | active: active})
  end

  defp schedule(%{active: active, timer: nil} = state) when map_size(active) > 0 do
    %{state | timer: Process.send_after(self(), :tick, Settings.get(:watch_interval))}
  end

  defp schedule(state), do: state
end
