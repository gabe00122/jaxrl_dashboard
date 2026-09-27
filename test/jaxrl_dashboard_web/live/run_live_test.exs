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
          "project" => "jaxrl",
          "config_source" => "return.json",
          "name" => "elsewhere"
        })

      assert render(view) =~ "elsewhere"

      Runs.claim_next_queued_run()
      assert view |> element("#runs-#{run.id}") |> render() =~ "running"
    end

    test "imported runs without an end time don't show a live timer", %{conn: conn} do
      dir = experiment_dir("never-logged")
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

    test "selecting runs offers a comparison, in selection order", %{conn: conn, user: user} do
      scope = Scope.for_user(user)

      {:ok, a} =
        Runs.enqueue_run(scope, %{
          "project" => "jaxrl",
          "config_source" => "return.json",
          "name" => "run-a"
        })

      {:ok, b} =
        Runs.enqueue_run(scope, %{
          "project" => "jaxrl",
          "config_source" => "return.json",
          "name" => "run-b"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#compare-bar")

      view |> element("#runs-#{b.id} input[type=checkbox]") |> render_click()
      view |> element("#runs-#{a.id} input[type=checkbox]") |> render_click()

      assert has_element?(view, "#compare-bar", "2 selected")
      assert has_element?(view, "#runs-#{a.id} input[checked]")
      assert has_element?(view, ~s(#compare-bar a[href="/compare?runs=run-b%2Crun-a"]))

      # Ticking a box selects, it doesn't open the run.
      assert render(view) =~ "Training runs"

      view |> element("#runs-#{b.id} input[type=checkbox]") |> render_click()
      assert has_element?(view, ~s(#compare-bar a[href="/compare?runs=run-a"]))

      view |> element("#compare-bar button", "Clear") |> render_click()
      refute has_element?(view, "#compare-bar")
      refute has_element?(view, "#runs-#{a.id} input[checked]")
    end

    test "limits comparisons to 8 runs", %{conn: conn, user: user} do
      scope = Scope.for_user(user)

      runs =
        for i <- 1..9 do
          {:ok, run} =
            Runs.enqueue_run(scope, %{
              "project" => "jaxrl",
              "config_source" => "return.json",
              "name" => "r#{i}"
            })

          run
        end

      {:ok, view, _html} = live(conn, ~p"/")

      for run <- runs,
          do: view |> element("#runs-#{run.id} input[type=checkbox]") |> render_click()

      assert has_element?(view, "#compare-bar", "8 selected")
      assert render(view) =~ "You can compare up to 8 runs at a time."
      refute has_element?(view, "#runs-#{List.last(runs).id} input[checked]")
    end

    test "cancels a queued run", %{conn: conn, user: user} do
      {:ok, run} =
        Runs.enqueue_run(Scope.for_user(user), %{
          "project" => "jaxrl",
          "config_source" => "return.json"
        })

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
          "project" => "jaxrl",
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
      dir = experiment_dir(run.name)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "logs.jsonl"),
        ~s({"step": 0, "loss": 1.0}\n{"step": 1, "loss": NaN}\n)
      )

      {:ok, view, _html} = live(conn, ~p"/runs/detail")

      # Rows broadcast before the hook loads are skipped (the load covers them).
      Runs.broadcast_run(
        run.name,
        {:metrics, run.name, "train", [%{step: 1, values: %{}, nan: []}]}
      )

      refute_push_event(view, "metrics_append", _)

      view |> element("#metrics") |> render_hook("load_metrics", %{})

      assert_reply(view, %{
        runs: [
          %{
            name: "detail",
            slot: 0,
            steps: [0, 1],
            series: %{"loss" => [1.0, nil]},
            nan: %{"loss" => %{first: 1, last: 1, count: 1}}
          }
        ]
      })

      # Already-sent steps are dropped; new ones are pushed.
      rows = [%{step: 1, values: %{}, nan: []}, %{step: 2, values: %{"loss" => 0.5}, nan: []}]
      Runs.broadcast_run(run.name, {:metrics, run.name, "train", rows})

      assert_push_event(view, "metrics_append", %{run: "detail", rows: [%{step: 2}]})
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

  describe "projects" do
    setup :register_and_log_in_user

    setup %{user: user} do
      write_config("return.json", %{"seed" => 1})
      write_config("grpo.json", %{"loss" => %{"type" => "grpo"}, "logger" => %{}}, "llm_rl")
      write_config("ppo.json", %{"loss" => %{"type" => "ppo"}, "logger" => %{}}, "llm_rl")
      %{scope: Scope.for_user(user)}
    end

    test "the index filters by project and counts each one's runs", %{conn: conn, scope: scope} do
      {:ok, grid} =
        Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "return.json"})

      {:ok, llm} =
        Runs.enqueue_run(scope, %{"project" => "llm_rl", "config_source" => "grpo.json"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#runs-#{grid.id}")
      assert has_element?(view, "#runs-#{llm.id}", "llm_rl")
      assert has_element?(view, "#filter-all", "2")
      assert has_element?(view, "#filter-llm_rl", "1")

      view |> element("#filter-llm_rl") |> render_click()
      assert_patch(view, ~p"/?#{[project: "llm_rl"]}")
      refute has_element?(view, "#runs-#{grid.id}")
      assert has_element?(view, "#runs-#{llm.id}")

      # Following a project also makes it the one to queue in.
      assert has_element?(view, ~s(#enqueue-form option[value="llm_rl"][selected]))
      assert has_element?(view, "#enqueue-form option", "grpo.json")
      refute has_element?(view, "#enqueue-form option", "return.json")

      # New runs in other projects don't show up in the filtered list.
      {:ok, other} =
        Runs.enqueue_run(scope, %{"project" => "jaxrl", "config_source" => "return.json"})

      refute has_element?(view, "#runs-#{other.id}")
      assert has_element?(view, "#filter-jaxrl", "2")
    end

    test "queues a run in the chosen project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#enqueue-form option", "grpo.json")

      # Picking another project swaps the config files on offer.
      view |> form("#enqueue-form", run: %{project: "llm_rl"}) |> render_change()
      assert has_element?(view, "#enqueue-form option", "grpo.json")

      view
      |> form("#enqueue-form",
        run: %{project: "llm_rl", config_source: "grpo.json", name: "llm-1"}
      )
      |> render_submit()

      assert Runs.get_run_by_name!("llm-1").project == "llm_rl"
    end

    test "a pipeline run's page shows each stage's metrics, following the pipeline", %{
      conn: conn,
      scope: scope
    } do
      {:ok, run} =
        Runs.enqueue_run(scope, %{
          "project" => "llm_rl",
          "config_source" => "ppo.json",
          "name" => "piped"
        })

      value_dir = experiment_dir("piped-value", "llm_rl")
      File.mkdir_p!(value_dir)
      File.write!(Path.join(value_dir, "logs.jsonl"), ~s({"step": 0, "value_loss.mean": 2.0}\n))

      {:ok, view, _html} = live(conn, ~p"/runs/piped")

      assert has_element?(view, "#run-project", "llm_rl")
      assert has_element?(view, ~s(#stage-value[aria-selected="true"]))
      assert has_element?(view, "#stage-rl")

      assert has_element?(
               view,
               ~s(a[href="/runs/piped/files/logs.jsonl?stage=value"])
             )

      view |> element("#metrics") |> render_hook("load_metrics", %{})
      assert_reply(view, %{runs: [%{steps: [0], series: %{"value_loss.mean" => [2.0]}}]})

      # Rows of the shown stage are pushed...
      Runs.broadcast_run(run.name, {:metrics, run.name, "value", [row(1)]})
      assert_push_event(view, "metrics_append", %{rows: [%{step: 1}]})

      # ...and once the RL stage starts logging, the page moves on to it.
      Runs.broadcast_run(run.name, {:metrics, run.name, "rl", [row(0)]})
      assert_push_event(view, "metrics_reload", %{})
      assert has_element?(view, ~s(#stage-rl[aria-selected="true"]))

      # Picking a stage by hand sticks.
      view |> element("#stage-value") |> render_click()
      assert has_element?(view, ~s(#stage-value[aria-selected="true"]))
      Runs.broadcast_run(run.name, {:metrics, run.name, "rl", [row(1)]})
      assert has_element?(view, ~s(#stage-value[aria-selected="true"]))
    end

    test "a stage's logs.jsonl can be downloaded", %{conn: conn, scope: scope} do
      {:ok, _} =
        Runs.enqueue_run(scope, %{
          "project" => "llm_rl",
          "config_source" => "ppo.json",
          "name" => "dl2"
        })

      for {dir, row} <- [{"dl2-value", "value"}, {"dl2", "rl"}] do
        File.mkdir_p!(experiment_dir(dir, "llm_rl"))
        File.write!(Path.join(experiment_dir(dir, "llm_rl"), "logs.jsonl"), row)
      end

      assert conn |> get(~p"/runs/dl2/files/logs.jsonl?#{[stage: "value"]}") |> response(200) ==
               "value"

      # The main stage by default.
      conn1 = get(conn, ~p"/runs/dl2/files/logs.jsonl")
      assert response(conn1, 200) == "rl"
      assert get_resp_header(conn1, "content-disposition") |> hd() =~ "dl2-logs.jsonl"

      assert conn |> get(~p"/runs/dl2/files/logs.jsonl?#{[stage: "nope"]}") |> response(404)
    end
  end

  defp row(step), do: %{step: step, values: %{"x" => 1.0}, nan: []}

  describe "file downloads" do
    setup :register_and_log_in_user

    setup %{user: user} do
      write_config("return.json")

      {:ok, run} =
        Runs.enqueue_run(Scope.for_user(user), %{
          "project" => "jaxrl",
          "config_source" => "return.json",
          "name" => "dl"
        })

      %{run: run}
    end

    test "serves a run's logs.jsonl and output.log", %{conn: conn, run: run} do
      File.mkdir_p!(experiment_dir(run.name))
      File.write!(JaxrlDashboard.Metrics.path(experiment_dir(run.name)), ~s({"step": 0}\n))
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
