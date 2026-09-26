defmodule Mix.Dashboard do
  @moduledoc false
  # Shared helpers for the `mix dashboard.*` user management tasks.

  @doc """
  Starts the app with logging turned down, so debug query logs (which would
  include password hashes) don't end up in the terminal.
  """
  def start_app do
    Mix.Task.run("app.start")
    Logger.configure(level: :error)
  end

  def format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
