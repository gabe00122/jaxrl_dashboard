defmodule JaxrlDashboard.Videos do
  @moduledoc """
  Policy videos of jaxrl rust-env runs, recorded on demand with the
  project's `record_command` (`pmarl record`): one episode per task, played
  by the run's latest checkpoint. Projects without a `record_command` have no
  videos.

  Everything lives on disk in the run's job directory, so there is nothing
  to migrate and a restarted dashboard picks up where it left off:

      videos/
        job/        run_job.sh files of the latest recording (pid, output.log,
                    exit_code), plus `set` (the set it writes) and
                    `cancelled` (if it was cancelled)
        <set id>/   one recording: task-N.mp4 files and manifest.json

  jaxrl writes `manifest.json` last, so a set with one is complete. The
  newest complete set is the one shown; the rest are pruned.

  Recordings are started and followed by `JaxrlDashboard.Videos.Recorder`,
  which broadcasts `{:videos, name, status}` on the run's topic.
  """

  alias JaxrlDashboard.{Projects, Runs}
  alias JaxrlDashboard.Projects.Project
  alias JaxrlDashboard.Runs.{Launcher, LogFile, Run, Settings}

  @set_id ~r/^\d{8}T\d{6}Z$/
  @video_file ~r/^task-\d+\.mp4$/
  @output_tail_bytes 16 * 1024

  @doc "Whether the run's project can record it (for jaxrl: a rust environment)."
  def recordable?(%Run{} = run), do: Project.recordable?(Projects.for_run(run), run.config)

  @doc """
  Whether the run has saved a checkpoint to play. Orbax writes each one to a
  temp directory and renames it to the bare step number once it's complete.
  """
  def has_checkpoint?(%Run{} = run) do
    dir = Projects.stage_dir(run, Projects.main_stage(run))

    case File.ls(Path.join(dir, "checkpoints")) do
      {:ok, entries} -> Enum.any?(entries, &Regex.match?(~r/^\d+$/, &1))
      {:error, _} -> false
    end
  end

  def videos_dir(name), do: Path.join(Settings.job_dir(name), "videos")
  def job_dir(name), do: Path.join(videos_dir(name), "job")

  @doc """
  The run's videos and recording state, read from disk:

    * `:state` - `:idle`, `:recording` or `:failed`
    * `:progress` - while recording, how far along it is (see `parse_progress/1`)
    * `:error` - when failed, `%{summary: line, output: tail}`
    * `:set` - the newest complete set of videos, or nil
  """
  def status(name) do
    job_dir = job_dir(name)

    base = %{state: :idle, progress: nil, error: nil, set: latest_set(name)}

    case recording_state(job_dir) do
      :idle ->
        base

      :recording ->
        %{base | state: :recording, progress: parse_progress(output_tail(job_dir))}

      {:failed, summary} ->
        %{base | state: :failed, error: %{summary: summary, output: output_tail(job_dir)}}
    end
  end

  def recording?(name), do: recording_state(job_dir(name)) == :recording

  defp recording_state(job_dir) do
    with {:ok, pid} <- Launcher.read_pid(job_dir) do
      cond do
        File.exists?(Path.join(job_dir, "cancelled")) and not Launcher.job_alive?(pid, job_dir) ->
          :idle

        match?({:ok, _}, Launcher.read_exit_code(job_dir)) ->
          finished_state(job_dir)

        Launcher.job_alive?(pid, job_dir) ->
          :recording

        true ->
          {:failed, "The recording stopped unexpectedly (killed or out of memory)."}
      end
    else
      :error -> :idle
    end
  end

  defp finished_state(job_dir) do
    {:ok, code} = Launcher.read_exit_code(job_dir)

    set_dir =
      with {:ok, id} <- File.read(Path.join(job_dir, "set")),
           do: Path.join(Path.dirname(job_dir), id)

    cond do
      code != 0 ->
        {:failed, exception_line(output_tail(job_dir)) || "exited with code #{code}."}

      is_binary(set_dir) and read_manifest(set_dir) != nil ->
        :idle

      true ->
        {:failed, "The recording finished without writing its videos."}
    end
  end

  defp output_tail(job_dir) do
    {lines, _offset} =
      LogFile.read_tail_lines(Path.join(job_dir, "output.log"), @output_tail_bytes)

    Enum.map(lines, fn {_offset, line} -> line end)
  end

  # The last line of a Python traceback, like `ValueError: no checkpoints`.
  defp exception_line(lines) do
    lines
    |> Enum.reverse()
    |> Enum.find(&Regex.match?(~r/^[\w.]*(Error|Exception|Interrupt)\b/, &1))
  end

  @doc """
  Reads `pmarl record`'s progress from its output lines: the task it's on
  and the step within it. Returns nil until the first task starts (while
  JAX starts up and the checkpoint loads).
  """
  def parse_progress(lines), do: Enum.reduce(lines, nil, &progress_line/2)

  defp progress_line(line, progress) do
    case Regex.run(~r/^Recording task (\d+)\/(\d+): (.+?) \(/, line) do
      [_, index, count, task] ->
        %{
          task: task,
          task_index: String.to_integer(index),
          task_count: String.to_integer(count),
          step: 0,
          steps: nil
        }

      nil ->
        case progress && Regex.run(~r/: step (\d+)\/(\d+)$/, line) do
          [_, step, steps] ->
            %{progress | step: String.to_integer(step), steps: String.to_integer(steps)}

          _ ->
            progress
        end
    end
  end

  @doc "Overall progress of a recording, from 0.0 to 1.0."
  def fraction(nil), do: 0.0

  def fraction(%{task_index: index, task_count: count, step: step, steps: steps}) do
    within = if steps, do: step / steps, else: 0.0
    (index - 1 + within) / count
  end

  ## Sets

  @doc "The newest complete set of videos, or nil."
  def latest_set(name) do
    name |> set_ids() |> Enum.find_value(&load_set(name, &1))
  end

  # Newest first; set ids are UTC timestamps, so they sort by time.
  defp set_ids(name) do
    case File.ls(videos_dir(name)) do
      {:ok, entries} -> entries |> Enum.filter(&Regex.match?(@set_id, &1)) |> Enum.sort(:desc)
      {:error, _} -> []
    end
  end

  defp load_set(name, id) do
    with %{} = manifest <- read_manifest(Path.join(videos_dir(name), id)) do
      Map.put(manifest, :id, id)
    end
  end

  # Only the fields the dashboard uses, and only well-formed video entries,
  # so the file names can go straight into URLs.
  defp read_manifest(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, %{"videos" => [_ | _] = videos} = manifest} <- Jason.decode(contents) do
      %{
        checkpoint_step: manifest["checkpoint_step"],
        created_at: parse_datetime(manifest["created_at"]),
        videos:
          for %{"file" => file, "task" => task} = video when is_binary(file) and is_binary(task) <-
                videos,
              Regex.match?(@video_file, file) do
            %{task: task, file: file, width: video["width"], height: video["height"]}
          end
      }
    else
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  @doc """
  Path of a video file in a set, or nil if the names aren't a set id and a
  video file name, so a request can't point anywhere else.
  """
  def video_path(name, set_id, file) do
    if Regex.match?(@set_id, set_id) and Regex.match?(@video_file, file) do
      Path.join([videos_dir(name), set_id, file])
    end
  end

  @doc "Deletes every set but the newest complete one. Not while recording."
  def prune(name) do
    keep = latest_set(name)

    for id <- set_ids(name), id != (keep && keep.id) do
      File.rm_rf!(Path.join(videos_dir(name), id))
    end

    :ok
  end

  ## Used by the recorder

  @doc """
  Starts the project's `record_command` for the run in a new set directory. Use
  `JaxrlDashboard.Videos.Recorder.start/1`, which checks it isn't already
  recording and limits how many recordings run at once.
  """
  def launch(%Run{name: name} = run) do
    project = Projects.for_run(run)
    job_dir = job_dir(name)
    set_id = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

    prune(name)
    File.rm_rf!(job_dir)
    File.mkdir_p!(job_dir)
    File.write!(Path.join(job_dir, "set"), set_id)

    command =
      project.record_command ++
        [
          name,
          "--base-dir",
          project.results_dir,
          "--out-dir",
          Path.join(videos_dir(name), set_id)
        ]

    Launcher.start_job(project, job_dir, command, env: project.record_env)
  end

  @doc "Stops a recording. Its partial set is pruned once it's gone."
  def cancel(name) do
    job_dir = job_dir(name)

    with :recording <- recording_state(job_dir),
         {:ok, pid} <- Launcher.read_pid(job_dir) do
      File.write!(Path.join(job_dir, "cancelled"), "")
      # Nothing to save in a half-recorded episode, so no grace period.
      Launcher.signal_job(pid, job_dir, "KILL")
    end

    :ok
  end

  @doc "Names of runs with a recording in progress, found on disk."
  def recording_names do
    case File.ls(Settings.data_dir()) do
      {:ok, names} -> Enum.filter(names, &recording?/1)
      {:error, _} -> []
    end
  end

  def broadcast(name, status), do: Runs.broadcast_run(name, {:videos, name, status})
end
