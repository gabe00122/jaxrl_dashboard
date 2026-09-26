defmodule JaxrlDashboardWeb.RunLiveTest do
  use JaxrlDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Accounts.Scope
  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.Settings

  setup :setup_run_dirs

  test "requires login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/")
    assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/runs/anything")
  end

  describe "index" do
    setup :register_and_log_in_user

    setup do
      write_config("return.json", %{"seed" => 1})
      :ok
    end

    test "queues a run from a config file", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "No runs yet"
      assert html =~ "return.json"

      html =
        view
        |> form("#enqueue-form", run: %{config_source: "return.json", name: "first-try"})
        |> render_submit()

      assert html =~ "Queued first-try"
      assert has_element?(view, "#runs td", "first-try")
      refute has_element?(view, "#runs-empty")
      assert Runs.get_run_by_name!("first-try").user_id == user.id
    end

    test "shows validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#enqueue-form", run: %{config_source: "return.json", name: "Bad Name"})
        |> render_change()

      assert html =~ "use lowercase letters, digits, dashes and underscores"
    end

    test "shows runs queued elsewhere and their status changes", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, run} =
        Runs.enqueue_run(Scope.for_user(user), %{
          "config_source" => "return.json",
          "name" => "elsewhere"
        })

      assert render(view) =~ "elsewhere"

      Runs.claim_next_queued_run()
      assert view |> element("#runs-#{run.id}") |> render() =~ "running"
    end

    test "cancels a queued run", %{conn: conn, user: user} do
      {:ok, run} = Runs.enqueue_run(Scope.for_user(user), %{"config_source" => "return.json"})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#runs-#{run.id} a", "Cancel") |> render_click()

      assert Runs.get_run!(run.id).status == :cancelled
      assert view |> element("#runs-#{run.id}") |> render() =~ "cancelled"
      refute has_element?(view, "#runs-#{run.id} a", "Cancel")
    end
  end

  describe "show" do
    setup :register_and_log_in_user

    setup %{user: user} do
      write_config("return.json", %{"seed" => 1})

      {:ok, run} =
        Runs.enqueue_run(Scope.for_user(user), %{
          "config_source" => "return.json",
          "name" => "detail"
        })

      %{run: run}
    end

    test "shows the run, its config and output", %{conn: conn, run: run} do
      job_dir = Settings.job_dir(run.name)
      File.mkdir_p!(job_dir)
      File.write!(Path.join(job_dir, "output.log"), "Steps per second: 1.2M\n")

      {:ok, view, html} = live(conn, ~p"/runs/detail")

      assert html =~ "detail"
      assert html =~ "&quot;seed&quot;: 1"
      assert view |> element("#run-output") |> render() =~ "Steps per second: 1.2M"
      assert has_element?(view, "#cancel-run")
    end

    test "updates live when the run fails", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/detail")

      run = Runs.claim_next_queued_run()
      Runs.mark_finished(run, :failed, exit_code: 1, error: "training exited with code 1")

      assert view |> element("#run-error") |> render() =~ "training exited with code 1"
      refute has_element?(view, "#cancel-run")
    end

    test "cancel button cancels the run", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/detail")

      view |> element("#cancel-run") |> render_click()

      assert Runs.get_run!(run.id).status == :cancelled
      refute has_element?(view, "#cancel-run")
    end

    test "unknown runs 404", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/runs/nope") end
    end
  end
end
