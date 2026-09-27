defmodule JaxrlDashboard.Runs.Settings do
  @moduledoc """
  Options for running jobs, shared by every project, from the
  `:jaxrl_dashboard, :runs` config. Per-project paths and commands are in
  `JaxrlDashboard.Projects`.
  """

  def get(key), do: Application.fetch_env!(:jaxrl_dashboard, :runs) |> Keyword.fetch!(key)

  def data_dir, do: get(:data_dir)

  @doc "The dashboard's own directory for one run's files."
  def job_dir(run_name), do: Path.join(data_dir(), run_name)

  @doc "The run's combined stdout/stderr, written by `run_job.sh`."
  def output_path(run_name), do: Path.join(job_dir(run_name), "output.log")
end
