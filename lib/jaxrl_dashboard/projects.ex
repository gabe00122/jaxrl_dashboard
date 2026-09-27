defmodule JaxrlDashboard.Projects do
  @moduledoc """
  The training projects the dashboard runs (jaxrl, llm_rl), from
  `config :jaxrl_dashboard, :projects`.

  Every run belongs to one project, stored by id. What's different between
  projects (how a run is launched, where its stages write their logs, which
  runs can be recorded) is up to the project's
  `JaxrlDashboard.Projects.Adapter`.
  """

  alias JaxrlDashboard.Projects.{Project, Stage}
  alias JaxrlDashboard.Runs.Run

  @doc "All projects, in config order."
  def list do
    for {id, opts} <- Application.fetch_env!(:jaxrl_dashboard, :projects),
        do: Project.new(Atom.to_string(id), opts)
  end

  def ids, do: Enum.map(list(), & &1.id)

  @doc "The project with the given id, or nil. Safe to call with user input."
  def get(id) when is_binary(id), do: Enum.find(list(), &(&1.id == id))
  def get(_id), do: nil

  def get!(id), do: get(id) || raise(ArgumentError, "unknown project #{inspect(id)}")

  @doc "The project new runs and configs start in."
  def default, do: hd(list())

  @doc "The run's project."
  def for_run(%Run{project: id}), do: get!(id)

  @doc """
  The run's stages, in the order they run; the last is its main stage.

  Imported runs are a single results directory, whatever their config says:
  the dashboard didn't launch them, so there are no other stages to find.
  """
  def stages(%Run{status: :imported, name: name}), do: [Stage.single(name)]
  def stages(%Run{} = run), do: Project.stages(for_run(run), run.name, run.config)

  def main_stage(%Run{} = run), do: run |> stages() |> List.last()

  @doc "The stage with the given id, or nil. Safe to call with user input."
  def stage(%Run{} = run, id), do: Enum.find(stages(run), &(&1.id == id))

  @doc "Where one of the run's stages writes its results."
  def stage_dir(%Run{} = run, %Stage{experiment: experiment}),
    do: Project.experiment_dir(for_run(run), experiment)
end
