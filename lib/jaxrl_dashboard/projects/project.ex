defmodule JaxrlDashboard.Projects.Project do
  @moduledoc """
  One training project: where its checkout, configs and results are, and how
  it's run. Built from its entry in `config :jaxrl_dashboard, :projects`;
  behaviour that differs between projects is delegated to `adapter`.
  """

  alias JaxrlDashboard.Projects.Stage

  @enforce_keys [:id, :label, :adapter, :dir, :config_dir, :results_dir, :python, :train_command]
  defstruct @enforce_keys ++ [description: nil, record_command: nil, record_env: []]

  @type t :: %__MODULE__{}

  def new(id, opts), do: struct!(__MODULE__, [{:id, id} | opts])

  @doc "Directory a run (or one stage of a run) writes its results to."
  def experiment_dir(%__MODULE__{results_dir: results_dir}, experiment),
    do: Path.join(results_dir, experiment)

  @doc "Config file names (not paths) in the project's config directory."
  def config_files(%__MODULE__{config_dir: config_dir}) do
    config_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  @doc "The full command that trains `name` with the config at `config_path`."
  def train_command(%__MODULE__{} = project, name, config_path) do
    project.train_command ++ project.adapter.train_args(config_path, project.results_dir, name)
  end

  @doc """
  The config a run will actually be started with. See
  `c:JaxrlDashboard.Projects.Adapter.prepare_config/1`.
  """
  def prepare_config(%__MODULE__{adapter: adapter}, config) when is_map(config),
    do: adapter.prepare_config(config)

  def prepare_config(%__MODULE__{}, config), do: config

  @doc "The stages a run launched with `config` goes through. `config` may be nil."
  @spec stages(t(), String.t(), map() | nil) :: [Stage.t()]
  def stages(%__MODULE__{adapter: adapter}, name, config), do: adapter.stages(name, config)

  @doc "Whether runs with this config can have policy videos recorded."
  def recordable?(%__MODULE__{record_command: nil}, _config), do: false
  def recordable?(%__MODULE__{adapter: adapter}, config), do: adapter.recordable?(config)

  @doc "Absolute path of the project's Python."
  def python_path(%__MODULE__{} = project), do: Path.expand(project.python, project.dir)
end
