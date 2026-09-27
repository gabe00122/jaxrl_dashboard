defmodule JaxrlDashboard.Runs.Watcher do
  @moduledoc """
  Follows a running run's `output.log` and each of its stages' `logs.jsonl`
  (see `JaxrlDashboard.Projects.stages/1`) and broadcasts what's appended, so
  every viewer shares one reader per run.

  Broadcasts on `JaxrlDashboard.Runs.run_topic/1`:

    * `{:metrics, name, stage_id, rows}` - parsed rows, see `JaxrlDashboard.Metrics`
    * `{:output, name, lines}` - `{offset, line}` tuples

  The scheduler starts and stops watchers to match the running runs (see
  `reconcile/1`). Metrics are read from the start of the file and output from
  its recent tail; subscribers drop anything they already have by step or
  offset.
  """

  use GenServer, restart: :transient

  alias JaxrlDashboard.{Metrics, Projects, Runs}
  alias JaxrlDashboard.Runs.{LogFile, Run, Settings}

  @registry JaxrlDashboard.Runs.WatcherRegistry
  @supervisor JaxrlDashboard.Runs.WatcherSupervisor
  @read_limit 1_000_000
  @output_start_tail 64 * 1024

  def start_link(%Run{} = run), do: GenServer.start_link(__MODULE__, run, name: via(run.name))

  defp via(name), do: {:via, Registry, {@registry, name}}

  @doc "Names of runs that currently have a watcher."
  def watched_names, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @doc "Starts or stops watchers so exactly the given runs are watched."
  def reconcile(runs) do
    current = watched_names()
    Enum.each(runs, &(&1.name in current || start(&1)))
    Enum.each(current -- Enum.map(runs, & &1.name), &stop/1)
  end

  def start(%Run{} = run) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, run}) do
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
  def init(%Run{name: name} = run) do
    {_lines, output_offset} =
      LogFile.read_tail_lines(Settings.output_path(name), @output_start_tail)

    # Stages that haven't started yet have no log; reading one is a no-op.
    metrics =
      for stage <- Projects.stages(run),
          do: %{id: stage.id, path: Metrics.path(Projects.stage_dir(run, stage)), offset: 0}

    send(self(), :poll)
    {:ok, %{name: name, metrics: metrics, output_offset: output_offset}}
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

    metrics =
      for stage <- state.metrics do
        {lines, offset} = LogFile.read_lines(stage.path, stage.offset, opts)

        if (rows = Metrics.parse_lines(lines)) != [] do
          Runs.broadcast_run(state.name, {:metrics, state.name, stage.id, rows})
        end

        %{stage | offset: offset}
      end

    {output_lines, output_offset} =
      LogFile.read_lines(Settings.output_path(state.name), state.output_offset, opts)

    if output_lines != [] do
      Runs.broadcast_run(state.name, {:output, state.name, output_lines})
    end

    more? =
      output_offset - state.output_offset >= @read_limit or
        Enum.zip(metrics, state.metrics)
        |> Enum.any?(fn {new, old} -> new.offset - old.offset >= @read_limit end)

    {%{state | metrics: metrics, output_offset: output_offset}, more?}
  end

  defp interval, do: Settings.get(:watch_interval)
end
