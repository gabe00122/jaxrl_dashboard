defmodule JaxrlDashboard.AccountsFixtures do
  alias JaxrlDashboard.Accounts

  def unique_username, do: "user#{System.unique_integer([:positive])}"

  @doc """
  Creates a user. The generated plaintext password is returned in the
  virtual `:password` field so tests can log in with it.
  """
  def user_fixture do
    {:ok, user, password} = Accounts.create_user(unique_username())
    %{user | password: password}
  end
end
