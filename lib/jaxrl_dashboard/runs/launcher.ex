defmodule JaxrlDashboard.Runs.Launcher do
  @moduledoc """
  Starts, inspects and signals training runs and other jobs (video
  recordings).

  Runs are launched through `priv/bin/run_job.sh` under `setsid --fork`, so
  they are not children of the BEAM and keep running across dashboard
  restarts. Everything the dashboard needs to reattach lives in the run's
  job directory (see `run_job.sh`).
  """

  alias JaxrlDashboard.Projects
  alias JaxrlDashboard.Projects.Project
  alias JaxrlDashboard.Runs.{Run, Settings}

  @pid_wait_attempts 50
  @pid_wait_interval 100

  @doc """
  Writes the run's config to disk and starts the training process.
  Returns `{:ok, os_pid}` or `{:error, reason}`.
  """
  def launch(%Run{} = run) do
    project = Projects.for_run(run)
    job_dir = Settings.job_dir(run.name)
    config_path = Path.join(job_dir, "config.json")

    with :ok <- File.mkdir_p(job_dir),
         :ok <- File.write(config_path, Jason.encode_to_iodata!(run.config, pretty: true)) do
      start_job(project, job_dir, Project.train_command(project, run.name, config_path))
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{job_dir}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts `command` in the project's checkout through `run_job.sh`, detached
  from the BEAM, with `job_dir` (which must exist) for its pid, output and
  exit code. Returns `{:ok, os_pid}` or `{:error, reason}`.

  ## Options

    * `:env` - extra environment variables, as `{name, value}` string pairs
  """
  def start_job(%Project{dir: project_dir}, job_dir, command, opts \\ []) do
    with :ok <- check_command(command, project_dir) do
      args = ["--fork", wrapper_path(), job_dir, project_dir | command]

      case System.cmd("setsid", args, stderr_to_stdout: true, env: Keyword.get(opts, :env, [])) do
        {_, 0} -> wait_for_pid(job_dir, @pid_wait_attempts)
        {output, code} -> {:error, "setsid exited with #{code}: #{output}"}
      end
    end
  end

  # Catch a misconfigured command up front instead of as an opaque exit 127.
  defp check_command([exe | _], project_dir) do
    cond do
      not String.contains?(exe, "/") -> :ok
      File.exists?(Path.expand(exe, project_dir)) -> :ok
      true -> {:error, "command not found: #{exe} (in #{project_dir})"}
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
  def read_exit_code(job_dir) when is_binary(job_dir),
    do: read_int(Path.join(job_dir, "exit_code"))

  def read_exit_code(%Run{name: name}), do: read_exit_code(Settings.job_dir(name))

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
  def alive?(%Run{pid: pid, name: name}), do: job_alive?(pid, Settings.job_dir(name))

  @doc "Like `alive?/1`, for any job started with `start_job/4`."
  def job_alive?(nil, _job_dir), do: false

  def job_alive?(pid, job_dir) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} -> cmdline |> String.split(<<0>>) |> Enum.member?(job_dir)
      {:error, _} -> false
    end
  end

  @doc """
  Sends a signal (`"TERM"` or `"KILL"`) to the run's whole process group.
  """
  def signal(%Run{pid: pid, name: name}, signal),
    do: signal_job(pid, Settings.job_dir(name), signal)

  @doc "Like `signal/2`, for any job started with `start_job/4`."
  def signal_job(pid, job_dir, signal) when signal in ["TERM", "KILL"] do
    if job_alive?(pid, job_dir) do
      System.cmd("kill", ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp wrapper_path, do: Application.app_dir(:jaxrl_dashboard, "priv/bin/run_job.sh")
end
