defmodule JaxrlDashboard.Runs do
  @moduledoc """
  Training runs: queueing, cancelling and status changes.

  Starting and supervising the actual processes is done by
  `JaxrlDashboard.Runs.Scheduler`. Every change is broadcast on the `"runs"`
  PubSub topic as `{:run_created, run}` or `{:run_updated, run}`.
  """

  import Ecto.Query, warn: false

  alias JaxrlDashboard.Repo
  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.Runs.{Run, Scheduler, Settings}

  @topic "runs"

  def subscribe, do: Phoenix.PubSub.subscribe(JaxrlDashboard.PubSub, @topic)

  @doc """
  Topic for one run's live data: metrics rows and output lines, broadcast by
  `JaxrlDashboard.Runs.Watcher`.
  """
  def run_topic(name), do: "run:" <> name
  def subscribe_run(name), do: Phoenix.PubSub.subscribe(JaxrlDashboard.PubSub, run_topic(name))

  def broadcast_run(name, message),
    do: Phoenix.PubSub.broadcast(JaxrlDashboard.PubSub, run_topic(name), message)

  defp broadcast({:ok, run}, event) do
    run = Repo.preload(run, :user)
    Phoenix.PubSub.broadcast(JaxrlDashboard.PubSub, @topic, {event, run})
    {:ok, run}
  end

  defp broadcast(error, _event), do: error

  ## Queries

  def list_runs(limit \\ 200) do
    Repo.all(
      from r in Run,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: ^limit,
        preload: :user
    )
  end

  def get_run!(id), do: Run |> Repo.get!(id) |> Repo.preload(:user)
  def get_run_by_name!(name), do: Run |> Repo.get_by!(name: name) |> Repo.preload(:user)

  def list_running_runs do
    Repo.all(from r in Run, where: r.status == :running, order_by: r.started_at)
  end

  def count_running_runs do
    Repo.aggregate(from(r in Run, where: r.status == :running), :count)
  end

  ## Queueing and cancelling

  @doc "A changeset for live form validation."
  def change_run(attrs \\ %{}) do
    Run.enqueue_changeset(%Run{}, attrs, generate_name: false)
  end

  @doc """
  Queues a run from a file in the jaxrl config directory. The config is
  snapshotted now, so later edits to the file don't affect queued runs.
  """
  def enqueue_run(%Scope{user: user}, attrs) do
    %Run{status: :queued, user_id: user.id}
    |> Run.enqueue_changeset(attrs)
    |> load_config()
    |> Repo.insert()
    |> broadcast(:run_created)
    |> tap(fn result -> match?({:ok, _}, result) && Scheduler.poke() end)
  end

  defp load_config(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp load_config(changeset) do
    path = Path.join(Settings.config_dir(), Ecto.Changeset.get_field(changeset, :config_source))

    with {:ok, contents} <- File.read(path),
         {:ok, %{} = config} <- Jason.decode(contents) do
      Ecto.Changeset.put_change(changeset, :config, config)
    else
      {:ok, _} -> Ecto.Changeset.add_error(changeset, :config_source, "is not a JSON object")
      {:error, _} -> Ecto.Changeset.add_error(changeset, :config_source, "is not valid JSON")
    end
  end

  @doc """
  Cancels a run. Queued runs are cancelled immediately; running ones are
  flagged, and the scheduler stops the process (SIGTERM, then SIGKILL after
  a grace period).
  """
  def cancel_run(%Run{status: :queued} = run) do
    now = DateTime.utc_now(:second)

    # Conditional update: loses cleanly if the scheduler just started the run.
    query = from r in Run, where: r.id == ^run.id and r.status == :queued, select: r

    case Repo.update_all(query,
           set: [status: :cancelled, finished_at: now, cancel_requested_at: now, updated_at: now]
         ) do
      {1, [run]} -> broadcast({:ok, run}, :run_updated)
      {0, _} -> run.id |> get_run!() |> cancel_run()
    end
  end

  def cancel_run(%Run{status: :running, cancel_requested_at: nil} = run) do
    result =
      run
      |> Ecto.Changeset.change(cancel_requested_at: DateTime.utc_now(:second))
      |> Repo.update()
      |> broadcast(:run_updated)

    Scheduler.poke()
    result
  end

  def cancel_run(%Run{status: :running} = run), do: {:ok, run}
  def cancel_run(%Run{}), do: {:error, :already_finished}

  ## Importing runs trained outside the dashboard

  @doc """
  Adds a run for every directory in the jaxrl results dir that has a
  `config.json` and isn't known yet. Safe to run repeatedly.

  Returns `{imported_names, skipped}` where `skipped` lists
  `{name, reason}` for directories that couldn't be imported.
  """
  def import_existing_runs do
    known = MapSet.new(Repo.all(from r in Run, select: r.name))
    results_dir = Settings.results_dir()

    results_dir
    |> File.ls()
    |> case do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> []
    end
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.filter(&File.regular?(Path.join([results_dir, &1, "config.json"])))
    |> Enum.reduce({[], []}, fn name, {imported, skipped} ->
      case import_run(name) do
        {:ok, run} ->
          broadcast({:ok, run}, :run_created)
          {[name | imported], skipped}

        {:error, reason} ->
          {imported, [{name, reason} | skipped]}
      end
    end)
    |> then(fn {imported, skipped} -> {Enum.reverse(imported), Enum.reverse(skipped)} end)
  end

  defp import_run(name) do
    dir = Settings.experiment_dir(name)

    with {:ok, config} <- read_json(Path.join(dir, "config.json")) do
      meta =
        case read_json(Path.join(dir, "meta.json")) do
          {:ok, meta} -> meta
          {:error, _} -> %{}
        end

      started_at = parse_datetime(meta["start_time"])

      attrs = %{
        name: name,
        config: config,
        config_source: meta["config_file"] && Path.basename(meta["config_file"]),
        started_at: started_at,
        # The last write to the metrics log is the best guess at when it ended.
        finished_at: file_mtime(Path.join(dir, "logs.jsonl")),
        # Sort imported runs by when they ran rather than when they were imported.
        inserted_at: started_at
      }

      case Repo.insert(Run.import_changeset(%Run{}, attrs)) do
        {:ok, run} -> {:ok, run}
        {:error, changeset} -> {:error, inspect(changeset.errors)}
      end
    end
  end

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(contents) do
      {:ok, map}
    else
      {:ok, _} -> {:error, "#{Path.basename(path)} is not a JSON object"}
      {:error, %Jason.DecodeError{}} -> {:error, "#{Path.basename(path)} is not valid JSON"}
      {:error, reason} -> {:error, "#{Path.basename(path)}: #{inspect(reason)}"}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _} -> nil
    end
  end

  ## Used by the scheduler

  @doc """
  Atomically moves the oldest queued run to `:running` and returns it, or
  `nil` if the queue is empty.
  """
  def claim_next_queued_run do
    now = DateTime.utc_now(:second)

    next_id =
      from r in Run,
        where: r.status == :queued,
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: 1,
        select: r.id

    query = from r in Run, where: r.id in subquery(next_id) and r.status == :queued, select: r

    case Repo.update_all(query, set: [status: :running, started_at: now, updated_at: now]) do
      {1, [run]} ->
        {:ok, run} = broadcast({:ok, run}, :run_updated)
        run

      {0, _} ->
        nil
    end
  end

  def mark_started(%Run{} = run, os_pid) do
    run
    |> Ecto.Changeset.change(pid: os_pid)
    |> Repo.update()
    |> broadcast(:run_updated)
  end

  def mark_finished(%Run{} = run, status, attrs \\ [])
      when status in [:succeeded, :failed, :cancelled, :lost] do
    run
    |> Ecto.Changeset.change(
      Keyword.merge([status: status, finished_at: DateTime.utc_now(:second)], attrs)
    )
    |> Repo.update()
    |> broadcast(:run_updated)
  end
end
