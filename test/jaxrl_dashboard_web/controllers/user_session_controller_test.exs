defmodule JaxrlDashboardWeb.UserSessionControllerTest do
  use JaxrlDashboardWeb.ConnCase, async: true

  import JaxrlDashboard.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "GET /log-in" do
    test "renders the login form with no signup link", %{conn: conn} do
      html = conn |> get(~p"/log-in") |> html_response(200)
      assert html =~ "Log in"
      refute html =~ ~r/sign ?up|register/i
    end

    test "redirects logged-in users to the dashboard", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(~p"/log-in")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /log-in" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/log-in", %{
          "user" => %{"username" => user.username, "password" => user.password}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      html = conn |> recycle() |> get(~p"/") |> html_response(200)
      assert html =~ user.username
      assert html =~ "Log out"
    end

    test "sets the remember-me cookie when asked", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/log-in", %{
          "user" => %{
            "username" => user.username,
            "password" => user.password,
            "remember_me" => "true"
          }
        })

      assert %{value: _, max_age: _} = conn.resp_cookies["_jaxrl_dashboard_web_user_remember_me"]
    end

    test "returns to the originally requested page", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/some/page")
        |> post(~p"/log-in", %{
          "user" => %{"username" => user.username, "password" => user.password}
        })

      assert redirected_to(conn) == "/some/page"
    end

    test "rejects a wrong password with a generic message", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/log-in", %{
          "user" => %{"username" => user.username, "password" => "not the password"}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end

    test "rejects malformed params", %{conn: conn} do
      conn = post(conn, ~p"/log-in", %{"user" => %{"username" => ["x"]}})
      assert redirected_to(conn) == ~p"/log-in"
    end

    test "throttles repeated attempts from one IP", %{conn: conn, user: user} do
      params = %{"user" => %{"username" => user.username, "password" => "not the password"}}

      for _ <- 1..10 do
        conn |> post(~p"/log-in", params) |> redirected_to()
      end

      # Even the correct password is refused once the limit is hit.
      conn =
        post(conn, ~p"/log-in", %{
          "user" => %{"username" => user.username, "password" => user.password}
        })

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many login attempts"
    end
  end

  describe "DELETE /log-out" do
    test "logs out and revokes the session token", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      token = get_session(conn, :user_token)

      conn = delete(conn, ~p"/log-out")

      assert redirected_to(conn) == ~p"/log-in"
      refute get_session(conn, :user_token)
      refute JaxrlDashboard.Accounts.get_user_by_session_token(token)
    end
  end
end
