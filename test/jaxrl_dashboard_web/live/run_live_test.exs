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

    test "imported runs without an end time don't show a live timer", %{conn: conn} do
      dir = Settings.experiment_dir("never-logged")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "config.json"), "{}")
      File.write!(Path.join(dir, "meta.json"), ~s({"start_time": "2026-07-19T22:51:46Z"}))
      Runs.import_existing_runs()
      run = Runs.get_run_by_name!("never-logged")
      assert run.started_at && is_nil(run.finished_at)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#run-#{run.id}-duration")
      assert view |> element("#runs-#{run.id}") |> render() =~ "—"
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

    test "sends the chart hook the full metrics history, then only new rows", %{
      conn: conn,
      run: run
    } do
      dir = Settings.experiment_dir(run.name)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "logs.jsonl"),
        ~s({"step": 0, "loss": 1.0}\n{"step": 1, "loss": NaN}\n)
      )

      {:ok, view, _html} = live(conn, ~p"/runs/detail")

      # Rows broadcast before the hook loads are skipped (the load covers them).
      Runs.broadcast_run(run.name, {:metrics, run.name, [%{step: 1, values: %{}, nan: []}]})
      refute_push_event(view, "metrics_append", _)

      view |> element("#metrics") |> render_hook("load_metrics", %{})

      assert_reply(view, %{
        steps: [0, 1],
        series: %{"loss" => [1.0, nil]},
        nan: %{"loss" => %{first: 1, last: 1, count: 1}}
      })

      # Already-sent steps are dropped; new ones are pushed.
      rows = [%{step: 1, values: %{}, nan: []}, %{step: 2, values: %{"loss" => 0.5}, nan: []}]
      Runs.broadcast_run(run.name, {:metrics, run.name, rows})

      assert_push_event(view, "metrics_append", %{rows: [%{step: 2}]})
    end

    test "appends streamed output lines and skips ones it already has", %{conn: conn, run: run} do
      job_dir = Settings.job_dir(run.name)
      File.mkdir_p!(job_dir)
      File.write!(Settings.output_path(run.name), "one\ntw")

      {:ok, view, _html} = live(conn, ~p"/runs/detail")
      assert has_element?(view, "#output-0", "one")
      assert has_element?(view, "#output-4", "tw")

      # The watcher sends the finished line at the same offset, plus a new one.
      Runs.broadcast_run(run.name, {:output, run.name, [{0, "one"}, {4, "two"}, {8, "three"}]})

      assert has_element?(view, "#output-4", "two")
      assert has_element?(view, "#output-8", "three")
      assert view |> element("#run-output") |> render() |> String.split("one") |> length() == 2
    end

    test "unknown runs 404", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/runs/nope") end
    end
  end

  describe "file downloads" do
    setup :register_and_log_in_user

    setup %{user: user} do
      write_config("return.json")

      {:ok, run} =
        Runs.enqueue_run(Scope.for_user(user), %{"config_source" => "return.json", "name" => "dl"})

      %{run: run}
    end

    test "serves a run's logs.jsonl and output.log", %{conn: conn, run: run} do
      File.mkdir_p!(Settings.experiment_dir(run.name))
      File.write!(JaxrlDashboard.Metrics.path(run.name), ~s({"step": 0}\n))
      File.mkdir_p!(Settings.job_dir(run.name))
      File.write!(Settings.output_path(run.name), "hello\n")

      conn1 = get(conn, ~p"/runs/dl/files/logs.jsonl")
      assert response(conn1, 200) == ~s({"step": 0}\n)
      assert get_resp_header(conn1, "content-disposition") |> hd() =~ "dl-logs.jsonl"

      assert conn |> get(~p"/runs/dl/files/output.log") |> response(200) == "hello\n"
    end

    test "only serves known file names", %{conn: conn} do
      assert conn |> get(~p"/runs/dl/files/config.json") |> response(404)
      assert conn |> get("/runs/dl/files/..%2F..%2Fetc%2Fpasswd") |> response(404)
    end

    test "404s for missing files and unknown runs", %{conn: conn} do
      assert conn |> get(~p"/runs/dl/files/logs.jsonl") |> response(404)
      assert_error_sent 404, fn -> get(conn, ~p"/runs/nope/files/logs.jsonl") end
    end
  end

  test "file downloads require login", %{conn: conn} do
    assert conn |> get(~p"/runs/dl/files/logs.jsonl") |> redirected_to() == ~p"/log-in"
  end
end
