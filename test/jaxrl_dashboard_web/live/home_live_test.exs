defmodule JaxrlDashboardWeb.HomeLiveTest do
  use JaxrlDashboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "redirects anonymous visitors to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/")
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "renders the dashboard", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Training runs"
      assert html =~ user.username
    end

    test "a revoked session can't connect the LiveView", %{conn: conn} do
      conn = get(conn, ~p"/")
      JaxrlDashboard.Accounts.delete_user_session_token(get_session(conn, :user_token))

      assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn)
    end
  end
end
