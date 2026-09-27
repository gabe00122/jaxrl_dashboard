defmodule JaxrlDashboard.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  alias JaxrlDashboard.Projects
  alias JaxrlDashboard.Projects.Project

  # :imported runs were trained outside the dashboard and found in results/.
  @statuses [:queued, :running, :succeeded, :failed, :cancelled, :lost, :imported]
  @finished [:succeeded, :failed, :cancelled, :lost, :imported]

  schema "runs" do
    field :name, :string
    # Id of the project it's trained in, see JaxrlDashboard.Projects.
    field :project, :string
    field :status, Ecto.Enum, values: @statuses
    # Snapshot of the training config, written to disk when the run starts.
    field :config, :map
    # The config file it was created from, if any.
    field :config_source, :string
    # PID of the job wrapper, which is also the run's process group ID.
    field :pid, :integer
    field :exit_code, :integer
    field :error, :string
    field :cancel_requested_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    belongs_to :user, JaxrlDashboard.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def finished_statuses, do: @finished
  def finished?(%__MODULE__{status: status}), do: status in @finished

  @doc """
  Changeset for queueing a run from a file in its project's config directory.
  The config itself is loaded by `JaxrlDashboard.Runs`.

  ## Options

    * `:generate_name` - fill in a name when none is given. Off for live form
      validation so the name field doesn't change on every keystroke.
  """
  def enqueue_changeset(run, attrs, opts \\ []) do
    changeset =
      run
      |> cast(attrs, [:project, :name, :config_source])
      |> validate_required([:project, :config_source])
      |> validate_project()

    project = project(changeset)

    changeset
    |> validate_inclusion(
      :config_source,
      if(project, do: Project.config_files(project), else: []),
      message:
        "is not a config file in #{if project, do: project.label, else: "the project"}'s config directory"
    )
    |> maybe_generate_name(Keyword.get(opts, :generate_name, true))
    |> validate_name()
  end

  @doc """
  Changeset for queueing a run from a config map (the config builder).
  `config_source` is a free-form label for where the config came from. The
  config is adjusted with `JaxrlDashboard.Projects.Project.prepare_config/2`.
  """
  def config_changeset(run, attrs) do
    run
    |> cast(attrs, [:project, :name, :config, :config_source])
    |> validate_required([:project, :config])
    |> validate_project()
    |> prepare_config()
    |> maybe_generate_name(true)
    |> validate_name()
  end

  @doc """
  Sets the config the run will be started with: `config`, adjusted for the
  dashboard by the project (see `JaxrlDashboard.Projects.Project.prepare_config/2`).
  """
  def put_config(changeset, config) do
    changeset |> put_change(:config, config) |> prepare_config()
  end

  defp prepare_config(changeset) do
    case {project(changeset), get_field(changeset, :config)} do
      {%Project{} = project, %{} = config} ->
        put_change(changeset, :config, Project.prepare_config(project, config))

      _ ->
        changeset
    end
  end

  defp validate_project(changeset) do
    validate_inclusion(changeset, :project, Projects.ids(), message: "is not a known project")
  end

  defp project(changeset) do
    if changeset.errors[:project], do: nil, else: Projects.get(get_field(changeset, :project))
  end

  defp maybe_generate_name(changeset, true) do
    if is_nil(get_field(changeset, :name)) do
      put_change(
        changeset,
        :name,
        generate_name(get_field(changeset, :config_source) || "custom")
      )
    else
      changeset
    end
  end

  defp maybe_generate_name(changeset, false), do: changeset

  @doc """
  Generates a name like `best-jax-find-return-k3fq` from a config file name.
  """
  def generate_name(config_source) do
    stem =
      config_source
      |> Path.rootname()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)

    suffix = :crypto.strong_rand_bytes(3) |> Base.encode32(case: :lower, padding: false)
    "#{stem}-#{String.slice(suffix, 0, 4)}"
  end

  @doc """
  Changeset for a run found in a project's results directory.
  """
  def import_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :project,
      :name,
      :config,
      :config_source,
      :started_at,
      :finished_at,
      :inserted_at
    ])
    |> validate_required([:project, :name, :config])
    |> validate_project()
    |> put_change(:status, :imported)
    |> validate_name_format()
    |> unique_constraint(:name)
  end

  # The name becomes a directory name and a CLI argument, so keep it boring.
  defp validate_name_format(changeset) do
    changeset
    |> validate_length(:name, max: 64)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "use lowercase letters, digits, dashes and underscores"
    )
  end

  defp validate_name(changeset) do
    changeset
    |> validate_name_format()
    |> validate_results_dirs()
    |> unsafe_validate_unique(:name, JaxrlDashboard.Repo)
    |> unique_constraint(:name)
  end

  @doc """
  Checks none of the directories the run's stages will write to exist yet,
  so a run never mixes its results with an older one's. Which stages there
  are can depend on the config, so this runs again once it's loaded.
  """
  def validate_results_dirs(changeset) do
    project = project(changeset)
    name = get_field(changeset, :name)

    taken =
      if project && is_binary(name) && !changeset.errors[:name] do
        project
        |> Project.stages(name, get_field(changeset, :config))
        |> Enum.map(& &1.experiment)
        |> Enum.find(&File.exists?(Project.experiment_dir(project, &1)))
      end

    case taken do
      nil ->
        changeset

      ^name ->
        add_error(changeset, :name, "already exists in #{project.label}'s results directory")

      other ->
        add_error(
          changeset,
          :name,
          "would write to #{other}, which already exists in #{project.label}'s results directory"
        )
    end
  end
end
