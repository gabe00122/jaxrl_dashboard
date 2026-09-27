defmodule JaxrlDashboard.Configs do
  @moduledoc """
  Training configs: the schema they follow, validation against their
  project's own Pydantic models, starting points for the builder, and saving
  config files. Everything here is per project (a
  `JaxrlDashboard.Projects.Project`, or its id).
  """

  alias JaxrlDashboard.{Projects, Repo}
  alias JaxrlDashboard.Configs.Schema
  alias JaxrlDashboard.Projects.Project
  alias JaxrlDashboard.Runs.Run

  defp validator, do: Application.fetch_env!(:jaxrl_dashboard, :config_validator)

  defp project(%Project{} = project), do: project
  defp project(id), do: Projects.get!(id)

  def schema(project) do
    with {:ok, raw} <- validator().schema(project(project)), do: {:ok, Schema.new(raw)}
  end

  @doc "`{:ok, []}` for a valid config, `{:ok, errors}` otherwise. See `Configs.Validator`."
  def validate(project, config), do: validator().validate(project(project), config)

  @doc """
  Loads a starting point for the builder: `"file:NAME.json"` from the
  project's config directory, `"run:NAME"` for the config of one of the
  project's runs, or `nil` for a new one. Returns `{:ok, config, label}`.
  """
  def load_source(_project, nil, %Schema{} = schema),
    do: {:ok, Schema.new_value(schema, Schema.root_node(schema)), nil}

  def load_source(%Project{} = project, "file:" <> file, _schema) do
    with true <- file in Project.config_files(project),
         {:ok, contents} <- File.read(Path.join(project.config_dir, file)),
         {:ok, %{} = config} <- Jason.decode(contents) do
      {:ok, config, file}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_source(%Project{id: project_id}, "run:" <> name, _schema) do
    case Repo.get_by(Run, name: name, project: project_id) do
      %Run{config: config} -> {:ok, config, name}
      nil -> {:error, :not_found}
    end
  end

  def load_source(_project, _source, _schema), do: {:error, :not_found}

  @doc """
  Saves a valid config as a new file in the project's config directory,
  written the way the project writes configs (model field order, defaults
  filled in). Never overwrites an existing file. Returns `{:ok, file_name}`.
  """
  def save_file(%Project{} = project, name, config) do
    file = if String.ends_with?(name, ".json"), do: name, else: name <> ".json"

    with :ok <- check_file_name(file),
         {:ok, []} <- validate(project, config),
         {:ok, json} <- validator().format(project, config),
         :ok <- File.write(Path.join(project.config_dir, file), [json, "\n"], [:exclusive]) do
      {:ok, file}
    else
      {:ok, [_ | _]} -> {:error, "the config has problems; fix them first"}
      {:error, :eexist} -> {:error, "#{file} already exists"}
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason) |> to_string()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_file_name(file) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}\.json$/, file),
      do: :ok,
      else: {:error, "use letters, digits, dashes, dots and underscores"}
  end
end
