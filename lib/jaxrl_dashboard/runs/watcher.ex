defmodule JaxrlDashboard.Runs.Watcher do
  @moduledoc """
  Follows a running run's `logs.jsonl` and `output.log` and broadcasts what's
  appended, so every viewer shares one reader per run.

  Broadcasts on `JaxrlDashboard.Runs.run_topic/1`:

    * `{:metrics, name, rows}` - parsed rows, see `JaxrlDashboard.Metrics`
    * `{:output, name, lines}` - `{offset, line}` tuples

  The scheduler starts and stops watchers to match the running runs (see
  `reconcile/1`). Metrics are read from the start of the file and output from
  its recent tail; subscribers drop anything they already have by step or
  offset.
  """

  use GenServer, restart: :transient

  alias JaxrlDashboard.{Metrics, Runs}
  alias JaxrlDashboard.Runs.{LogFile, Settings}

  @registry JaxrlDashboard.Runs.WatcherRegistry
  @supervisor JaxrlDashboard.Runs.WatcherSupervisor
  @read_limit 1_000_000
  @output_start_tail 64 * 1024

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  defp via(name), do: {:via, Registry, {@registry, name}}

  @doc "Names of runs that currently have a watcher."
  def watched_names, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @doc "Starts or stops watchers so exactly the given runs are watched."
  def reconcile(names) do
    current = watched_names()
    Enum.each(names -- current, &start/1)
    Enum.each(current -- names, &stop/1)
  end

  def start(name) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, name}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Reads whatever is left (including unterminated last lines), then stops."
  def stop(name) do
    GenServer.call(via(name), :stop)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(name) do
    {_lines, output_offset} =
      LogFile.read_tail_lines(Settings.output_path(name), @output_start_tail)

    send(self(), :poll)
    {:ok, %{name: name, metrics_offset: 0, output_offset: output_offset}}
  end

  @impl true
  def handle_info(:poll, state) do
    {state, more?} = poll(state, false)
    # Catching up on a big file: keep reading instead of waiting a tick.
    if more?, do: send(self(), :poll), else: Process.send_after(self(), :poll, interval())
    {:noreply, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {state, _more?} = poll(state, true)
    {:stop, :normal, :ok, state}
  end

  defp poll(state, final?) do
    opts = [max_bytes: @read_limit, partial: final?]

    {metric_lines, metrics_offset} =
      LogFile.read_lines(Metrics.path(state.name), state.metrics_offset, opts)

    {output_lines, output_offset} =
      LogFile.read_lines(Settings.output_path(state.name), state.output_offset, opts)

    if (rows = Metrics.parse_lines(metric_lines)) != [] do
      Runs.broadcast_run(state.name, {:metrics, state.name, rows})
    end

    if output_lines != [] do
      Runs.broadcast_run(state.name, {:output, state.name, output_lines})
    end

    more? =
      metrics_offset - state.metrics_offset >= @read_limit or
        output_offset - state.output_offset >= @read_limit

    {%{state | metrics_offset: metrics_offset, output_offset: output_offset}, more?}
  end

  defp interval, do: Settings.get(:watch_interval)
end
