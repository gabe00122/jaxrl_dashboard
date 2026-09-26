defmodule JaxrlDashboard.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a user. Users are only ever created from the
  server-side mix tasks, never from the web.
  """
  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username])
    |> validate_length(:username, min: 2, max: 32)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_\-]+$/,
      message: "only letters, digits, underscores and dashes"
    )
    |> unsafe_validate_unique(:username, JaxrlDashboard.Repo)
    |> unique_constraint(:username)
    |> validate_password()
  end

  @doc """
  Changeset for replacing a user's password.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    # Long passwords are expensive to hash, so cap the length.
    |> validate_length(:password, min: 12, max: 72)
    |> hash_password()
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verifies the password.

  If there is no user, `Argon2.no_user_verify/0` is still run so the response
  time doesn't reveal whether a username exists.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end
end
