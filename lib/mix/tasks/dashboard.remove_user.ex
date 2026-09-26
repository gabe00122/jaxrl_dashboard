defmodule Mix.Tasks.Dashboard.RemoveUser do
  @shortdoc "Deletes a dashboard user and all their sessions"
  @moduledoc """
      $ mix dashboard.remove_user alice
  """
  use Mix.Task

  alias JaxrlDashboard.Accounts

  @impl true
  def run([username]) do
    Mix.Dashboard.start_app()

    user = Accounts.get_user_by_username(username) || Mix.raise("No user named #{username}")
    {:ok, _} = Accounts.delete_user(user)
    Mix.shell().info("Removed user #{user.username}.")
  end

  def run(_), do: Mix.raise("Usage: mix dashboard.remove_user USERNAME")
end
