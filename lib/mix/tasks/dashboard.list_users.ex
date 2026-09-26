defmodule Mix.Tasks.Dashboard.ListUsers do
  @shortdoc "Lists dashboard users"
  @moduledoc """
      $ mix dashboard.list_users
  """
  use Mix.Task

  alias JaxrlDashboard.Accounts

  @impl true
  def run(_args) do
    Mix.Dashboard.start_app()

    case Accounts.list_users() do
      [] ->
        Mix.shell().info("No users. Create one with: mix dashboard.add_user USERNAME")

      users ->
        for user <- users do
          Mix.shell().info("#{user.username}\tcreated #{user.inserted_at}")
        end
    end
  end
end
