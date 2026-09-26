defmodule JaxrlDashboard.Accounts do
  @moduledoc """
  User accounts. There is deliberately no public signup: users are created on
  the server with `mix dashboard.add_user`, which generates their password.
  """

  import Ecto.Query, warn: false
  alias JaxrlDashboard.Repo
  alias JaxrlDashboard.Accounts.{User, UserToken}

  ## Users

  def list_users do
    Repo.all(from u in User, order_by: u.username)
  end

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = get_user_by_username(username)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Creates a user with a freshly generated password.

  Returns `{:ok, user, password}`. The plaintext password is only available
  here; only its hash is stored.
  """
  def create_user(username) do
    password = generate_password()

    %User{}
    |> User.create_changeset(%{username: username, password: password})
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user, password}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Replaces a user's password with a freshly generated one and revokes all of
  their sessions. Returns `{:ok, user, password}`.
  """
  def reset_password(%User{} = user) do
    password = generate_password()
    changeset = User.password_changeset(user, %{password: password})

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_query(user))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user, password}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Deletes a user. Their session tokens are removed by the foreign key cascade.
  """
  def delete_user(%User{} = user), do: Repo.delete(user)

  @doc """
  Generates a random password: 120 bits of entropy, formatted as four groups
  of six lowercase base32 characters (e.g. `k3fq7a-...`) so it survives being
  read aloud or retyped.
  """
  def generate_password do
    :crypto.strong_rand_bytes(15)
    |> Base.encode32(case: :lower, padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(6)
    |> Enum.map_join("-", &Enum.join/1)
  end

  ## Sessions

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns `{user, token_inserted_at}` for a valid session token, or `nil`.
  """
  def get_user_by_session_token(token) do
    token |> UserToken.verify_session_token_query() |> Repo.one()
  end

  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end
end
