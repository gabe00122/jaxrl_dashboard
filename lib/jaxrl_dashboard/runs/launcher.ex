defmodule JaxrlDashboard.Runs.Launcher do
  @moduledoc """
  Starts, inspects and signals training processes.

  Runs are launched through `priv/bin/run_job.sh` under `setsid --fork`, so
  they are not children of the BEAM and keep running across dashboard
  restarts. Everything the dashboard needs to reattach lives in the run's
  job directory (see `run_job.sh`).
  """

  alias JaxrlDashboard.Runs.{Run, Settings}

  @pid_wait_attempts 50
  @pid_wait_interval 100

  @doc """
  Writes the run's config to disk and starts the training process.
  Returns `{:ok, os_pid}` or `{:error, reason}`.
  """
  def launch(%Run{} = run) do
    job_dir = Settings.job_dir(run.name)
    config_path = Path.join(job_dir, "config.json")

    with :ok <- check_command(),
         :ok <- File.mkdir_p(job_dir),
         :ok <- File.write(config_path, Jason.encode_to_iodata!(run.config, pretty: true)) do
      command =
        Settings.get(:train_command) ++
          ["--config", config_path, "--base-dir", Settings.results_dir(), "--name", run.name]

      args = ["--fork", wrapper_path(), job_dir, Settings.project_dir() | command]

      case System.cmd("setsid", args, stderr_to_stdout: true) do
        {_, 0} -> wait_for_pid(job_dir, @pid_wait_attempts)
        {output, code} -> {:error, "setsid exited with #{code}: #{output}"}
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{job_dir}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Catch a misconfigured command up front instead of as an opaque exit 127.
  defp check_command do
    [exe | _] = Settings.get(:train_command)

    cond do
      not String.contains?(exe, "/") -> :ok
      File.exists?(Path.expand(exe, Settings.project_dir())) -> :ok
      true -> {:error, "training command not found: #{exe} (in #{Settings.project_dir()})"}
    end
  end

  defp wait_for_pid(job_dir, attempts) do
    case read_pid(job_dir) do
      {:ok, pid} ->
        {:ok, pid}

      :error when attempts > 0 ->
        Process.sleep(@pid_wait_interval)
        wait_for_pid(job_dir, attempts - 1)

      :error ->
        {:error, "the job wrapper didn't write its pid file"}
    end
  end

  @doc "Reads the pid file of a run that may have been launched by an earlier dashboard."
  def read_pid(job_dir) when is_binary(job_dir), do: read_int(Path.join(job_dir, "pid"))
  def read_pid(%Run{name: name}), do: read_pid(Settings.job_dir(name))

  @doc "Returns `{:ok, code}` once the run's command has exited normally."
  def read_exit_code(%Run{name: name}),
    do: read_int(Path.join(Settings.job_dir(name), "exit_code"))

  defp read_int(path) do
    with {:ok, contents} <- File.read(path),
         {int, _} <- Integer.parse(String.trim(contents)) do
      {:ok, int}
    else
      _ -> :error
    end
  end

  @doc """
  Whether the run's process is still alive.

  Checks the process's command line as well as the pid, so a pid reused by an
  unrelated process after a reboot isn't mistaken for the run.
  """
  def alive?(%Run{pid: nil}), do: false

  def alive?(%Run{pid: pid, name: name}) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} -> cmdline |> String.split(<<0>>) |> Enum.member?(Settings.job_dir(name))
      {:error, _} -> false
    end
  end

  @doc """
  Sends a signal (`"TERM"` or `"KILL"`) to the run's whole process group.
  """
  def signal(%Run{pid: pid} = run, signal) when signal in ["TERM", "KILL"] do
    if alive?(run) do
      System.cmd("kill", ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  @doc """
  Returns up to the last `max_bytes` of the run's output, starting at a line
  boundary.
  """
  def read_output_tail(%Run{name: name}, max_bytes \\ 64 * 1024) do
    path = Path.join(Settings.job_dir(name), "output.log")

    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      offset = max(size - max_bytes, 0)

      data =
        try do
          case :file.pread(file, offset, max_bytes) do
            {:ok, data} -> data
            _ -> ""
          end
        after
          File.close(file)
        end

      if offset > 0, do: drop_partial_line(data), else: data
    else
      _ -> ""
    end
  end

  defp drop_partial_line(data) do
    case :binary.split(data, "\n") do
      [_partial, rest] -> rest
      [_] -> data
    end
  end

  defp wrapper_path, do: Application.app_dir(:jaxrl_dashboard, "priv/bin/run_job.sh")
end
