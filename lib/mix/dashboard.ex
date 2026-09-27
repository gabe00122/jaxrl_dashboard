defmodule Mix.Dashboard do
  @moduledoc false
  # Shared helpers for the `mix dashboard.*` user management tasks.

  @doc """
  Starts the app without the job scheduler, and with logging turned down so
  debug query logs (which would include password hashes) don't end up in the
  terminal.
  """
  def start_app do
    Mix.Task.run("app.config")

    # The running server owns the job queue and recordings; a short-lived
    # task mustn't start a second scheduler or recorder that could launch jobs.
    runs = Application.fetch_env!(:jaxrl_dashboard, :runs)
    Application.put_env(:jaxrl_dashboard, :runs, Keyword.put(runs, :start_scheduler, false))

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
