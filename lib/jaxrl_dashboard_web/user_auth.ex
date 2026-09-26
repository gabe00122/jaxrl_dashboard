defmodule JaxrlDashboardWeb.UserAuth do
  use JaxrlDashboardWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias JaxrlDashboard.Accounts
  alias JaxrlDashboard.Accounts.Scope

  # The remember-me cookie must not outlive the token's validity in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_jaxrl_dashboard_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax",
    http_only: true
  ]

  # Active sessions get a fresh token once theirs is this old, so users who
  # keep using the dashboard don't get logged out at the 14 day mark.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in and redirects to the page they originally asked for.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || ~p"/")
  end

  @doc """
  Logs the user out, revoking the session token and disconnecting any
  LiveViews that were opened with it.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      JaxrlDashboardWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/log-in")
  end

  @doc """
  Plug that loads the current user from the session or remember-me cookie.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, nil)
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      end
    end
  end

  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Don't renew the session if this user is already logged in, so that open
  # tabs don't hit CSRF errors when a token is reissued.
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # Renew the session ID and clear the session to prevent fixation attacks.
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  LiveView `on_mount` hook. `:require_authenticated` re-checks the session
  token when the websocket connects, and redirects to login without one.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      with token when is_binary(token) <- session["user_token"],
           {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
        Scope.for_user(user)
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Plug for routes that require a logged-in user.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/log-in")
      |> halt()
    end
  end

  @doc """
  Plug for the login page: logged-in users are sent to the dashboard.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns.current_scope do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
