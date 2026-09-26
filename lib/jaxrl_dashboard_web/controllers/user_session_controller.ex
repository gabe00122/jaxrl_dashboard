defmodule JaxrlDashboardWeb.UserSessionController do
  use JaxrlDashboardWeb, :controller

  alias JaxrlDashboard.{Accounts, RateLimiter}
  alias JaxrlDashboardWeb.UserAuth

  # Login attempts allowed per client IP per window. Argon2 is deliberately
  # slow, so this also stops login spam from pinning the CPU.
  #
  # Behind a reverse proxy every request comes from the proxy's IP, which makes
  # this a global limit. That's acceptable for a handful of users.
  @login_limit 10
  @login_window :timer.minutes(5)

  def new(conn, _params) do
    username = Phoenix.Flash.get(conn.assigns.flash, :username)
    render(conn, :new, form: Phoenix.Component.to_form(%{"username" => username}, as: "user"))
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password} = user_params})
      when is_binary(username) and is_binary(password) do
    with :ok <- RateLimiter.hit({:login, conn.remote_ip}, @login_limit, @login_window),
         %Accounts.User{} = user <- Accounts.get_user_by_username_and_password(username, password) do
      UserAuth.log_in_user(conn, user, user_params)
    else
      {:error, retry_after_ms} ->
        conn
        |> put_flash(
          :error,
          "Too many login attempts. Try again in #{div(retry_after_ms, 60_000) + 1} min."
        )
        |> redirect(to: ~p"/log-in")

      # Same message either way so usernames can't be enumerated.
      nil ->
        conn
        |> put_flash(:error, "Invalid username or password")
        |> put_flash(:username, String.slice(username, 0, 32))
        |> redirect(to: ~p"/log-in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid username or password")
    |> redirect(to: ~p"/log-in")
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
