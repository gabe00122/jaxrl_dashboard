defmodule JaxrlDashboard.Runs.Settings do
  @moduledoc """
  Paths and options for launching jaxrl training runs, from the
  `:jaxrl_dashboard, :runs` config.
  """

  def get(key), do: Application.fetch_env!(:jaxrl_dashboard, :runs) |> Keyword.fetch!(key)

  def project_dir, do: get(:project_dir)
  def config_dir, do: get(:config_dir)
  def results_dir, do: get(:results_dir)
  def data_dir, do: get(:data_dir)

  @doc "The dashboard's own directory for one run's files."
  def job_dir(run_name), do: Path.join(data_dir(), run_name)

  @doc "The run's combined stdout/stderr, written by `run_job.sh`."
  def output_path(run_name), do: Path.join(job_dir(run_name), "output.log")

  @doc "Directory jaxrl writes the run's results to (`logs.jsonl`, checkpoints)."
  def experiment_dir(run_name), do: Path.join(results_dir(), run_name)

  @doc "Config file names (not paths) available in the jaxrl config directory."
  def config_files do
    config_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end
end
