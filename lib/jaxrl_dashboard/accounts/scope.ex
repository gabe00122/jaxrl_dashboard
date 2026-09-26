defmodule JaxrlDashboard.Accounts.Scope do
  @moduledoc """
  The caller's scope, passed to contexts and used to scope PubSub topics.
  """

  alias JaxrlDashboard.Accounts.User

  defstruct user: nil

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
