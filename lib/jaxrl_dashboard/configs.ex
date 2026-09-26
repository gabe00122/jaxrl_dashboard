defmodule JaxrlDashboard.Configs do
  @moduledoc """
  Training configs: the schema they follow, validation against jaxrl's own
  Pydantic models, starting points for the builder, and saving config files.
  """

  alias JaxrlDashboard.Configs.Schema
  alias JaxrlDashboard.Repo
  alias JaxrlDashboard.Runs.{Run, Settings}

  defp validator, do: Application.fetch_env!(:jaxrl_dashboard, :config_validator)

  def schema do
    with {:ok, raw} <- validator().schema(), do: {:ok, Schema.new(raw)}
  end

  @doc "`{:ok, []}` for a valid config, `{:ok, errors}` otherwise. See `Configs.Validator`."
  def validate(config), do: validator().validate(config)

  @doc """
  Loads a starting point for the builder: `"file:NAME.json"` from the jaxrl
  config directory, `"run:NAME"` for a run's config, or `nil` for a new one.
  Returns `{:ok, config, label}`.
  """
  def load_source(nil, %Schema{} = schema),
    do: {:ok, Schema.new_value(schema, Schema.root_node(schema)), nil}

  def load_source("file:" <> file, _schema) do
    with true <- file in Settings.config_files(),
         {:ok, contents} <- File.read(Path.join(Settings.config_dir(), file)),
         {:ok, %{} = config} <- Jason.decode(contents) do
      {:ok, config, file}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_source("run:" <> name, _schema) do
    case Repo.get_by(Run, name: name) do
      %Run{config: config} -> {:ok, config, name}
      nil -> {:error, :not_found}
    end
  end

  def load_source(_source, _schema), do: {:error, :not_found}

  @doc """
  Saves a valid config as a new file in the jaxrl config directory, written
  the way jaxrl writes configs (model field order, defaults filled in).
  Never overwrites an existing file. Returns `{:ok, file_name}`.
  """
  def save_file(name, config) do
    file = if String.ends_with?(name, ".json"), do: name, else: name <> ".json"

    with :ok <- check_file_name(file),
         {:ok, []} <- validate(config),
         {:ok, json} <- validator().format(config),
         :ok <- File.write(Path.join(Settings.config_dir(), file), [json, "\n"], [:exclusive]) do
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
