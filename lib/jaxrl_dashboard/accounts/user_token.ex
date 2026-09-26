defmodule JaxrlDashboard.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias JaxrlDashboard.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    belongs_to :user, JaxrlDashboard.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a session token to be stored in the signed session cookie.

  Tokens are also persisted so that individual sessions can be revoked:
  deleting a user or resetting their password invalidates every session.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  Returns a query for the user owning a valid (unexpired) session token,
  along with the token's creation time.
  """
  def verify_session_token_query(token) do
    from t in by_token_and_context_query(token, "session"),
      join: user in assoc(t, :user),
      where: t.inserted_at > ago(@session_validity_in_days, "day"),
      select: {user, t.inserted_at}
  end

  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  def by_user_query(user) do
    from UserToken, where: [user_id: ^user.id]
  end
end
