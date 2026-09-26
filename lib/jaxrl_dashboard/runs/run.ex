defmodule JaxrlDashboard.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  alias JaxrlDashboard.Runs.Settings

  # :imported runs were trained outside the dashboard and found in results/.
  @statuses [:queued, :running, :succeeded, :failed, :cancelled, :lost, :imported]
  @finished [:succeeded, :failed, :cancelled, :lost, :imported]

  schema "runs" do
    field :name, :string
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
  Changeset for queueing a run from a config file.

  ## Options

    * `:generate_name` - fill in a name when none is given. Off for live form
      validation so the name field doesn't change on every keystroke.
  """
  def enqueue_changeset(run, attrs, opts \\ []) do
    run
    |> cast(attrs, [:name, :config_source])
    |> validate_required([:config_source])
    |> validate_inclusion(:config_source, Settings.config_files(),
      message: "is not a config file in the jaxrl config directory"
    )
    |> maybe_generate_name(Keyword.get(opts, :generate_name, true))
    |> validate_name()
  end

  defp maybe_generate_name(changeset, true) do
    source = get_field(changeset, :config_source)

    if is_nil(get_field(changeset, :name)) and source do
      put_change(changeset, :name, generate_name(source))
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
  Changeset for a run found in the jaxrl results directory.
  """
  def import_changeset(run, attrs) do
    run
    |> cast(attrs, [:name, :config, :config_source, :started_at, :finished_at, :inserted_at])
    |> validate_required([:name, :config])
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
    |> validate_change(:name, fn :name, name ->
      if File.exists?(Settings.experiment_dir(name)),
        do: [name: "already exists in the jaxrl results directory"],
        else: []
    end)
    |> unsafe_validate_unique(:name, JaxrlDashboard.Repo)
    |> unique_constraint(:name)
  end
end
