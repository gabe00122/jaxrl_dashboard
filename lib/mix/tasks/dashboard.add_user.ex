defmodule Mix.Tasks.Dashboard.AddUser do
  @shortdoc "Creates a dashboard user and prints their generated password"
  @moduledoc """
  Creates a user with a randomly generated password, printed once.

      $ mix dashboard.add_user alice
  """
  use Mix.Task

  alias JaxrlDashboard.Accounts

  @impl true
  def run([username]) do
    Mix.Dashboard.start_app()

    case Accounts.create_user(username) do
      {:ok, user, password} ->
        Mix.shell().info("""
        Created user #{user.username}.

          password: #{password}

        This password is not stored anywhere and won't be shown again.
        """)

      {:error, changeset} ->
        Mix.raise("Could not create user: #{Mix.Dashboard.format_errors(changeset)}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix dashboard.add_user USERNAME")
end
