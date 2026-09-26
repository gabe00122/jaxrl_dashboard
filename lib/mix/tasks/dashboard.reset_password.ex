defmodule Mix.Tasks.Dashboard.ResetPassword do
  @shortdoc "Generates a new password for a user and logs out all their sessions"
  @moduledoc """
  Replaces a user's password with a newly generated one, printed once, and
  revokes all of their existing sessions.

      $ mix dashboard.reset_password alice
  """
  use Mix.Task

  alias JaxrlDashboard.Accounts

  @impl true
  def run([username]) do
    Mix.Dashboard.start_app()

    user = Accounts.get_user_by_username(username) || Mix.raise("No user named #{username}")
    {:ok, user, password} = Accounts.reset_password(user)

    Mix.shell().info("""
    Reset password for #{user.username}. All their sessions were logged out.

      password: #{password}
    """)
  end

  def run(_), do: Mix.raise("Usage: mix dashboard.reset_password USERNAME")
end
