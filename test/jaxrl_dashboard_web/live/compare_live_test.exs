defmodule JaxrlDashboardWeb.CompareLiveTest do
  use JaxrlDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.{Metrics, Runs}

  setup :setup_run_dirs

  test "requires login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/compare")
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    setup do
      # Three imported runs with a couple of metric rows each.
      for {name, losses} <- [{"alpha", [1.0, 0.5]}, {"beta", [2.0, 1.5]}, {"gamma", [3.0]}] do
        dir = experiment_dir(name)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "config.json"), "{}")

        rows =
          losses
          |> Enum.with_index()
          |> Enum.map_join(fn {loss, step} -> ~s({"step": #{step}, "loss": #{loss}}\n) end)

        File.write!(Metrics.path(dir), rows)
      end

      Runs.import_existing_runs()
      :ok
    end

    defp slot_style(view, name) do
      [style] =
        view
        |> element("#compare-run-#{name} span[style]")
        |> render()
        |> then(&Regex.run(~r/style="([^"]+)"/, &1, capture: :all_but_first))

      style
    end

    test "shows the runs from the URL as a legend, skipping unknown ones", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compare?runs=beta,nope,alpha")

      assert has_element?(view, "#compare-run-beta")
      assert has_element?(view, "#compare-run-alpha")
      refute has_element?(view, "#compare-run-nope")
      assert slot_style(view, "beta") =~ "--series-1"
      assert slot_style(view, "alpha") =~ "--series-2"
    end

    test "sends every run's metrics with its color slot", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compare?runs=beta,alpha")

      view |> element("#metrics") |> render_hook("load_metrics", %{})

      assert_reply(view, %{
        runs: [
          %{name: "beta", slot: 0, steps: [0, 1], series: %{"loss" => [2.0, 1.5]}},
          %{name: "alpha", slot: 1, steps: [0, 1], series: %{"loss" => [1.0, 0.5]}}
        ]
      })

      # New rows for a compared run are pushed, tagged with the run.
      Runs.broadcast_run(
        "alpha",
        {:metrics, "alpha", "train", [%{step: 2, values: %{"loss" => 0.2}, nan: []}]}
      )

      assert_push_event(view, "metrics_append", %{run: "alpha", rows: [%{step: 2}]})
    end

    test "compares a pipeline run by its main stage", %{conn: conn, user: user} do
      write_config("ppo.json", %{"loss" => %{"type" => "ppo"}, "logger" => %{}}, "llm_rl")

      {:ok, _} =
        Runs.enqueue_run(JaxrlDashboard.Accounts.Scope.for_user(user), %{
          "project" => "llm_rl",
          "config_source" => "ppo.json",
          "name" => "piped"
        })

      for {dir, key} <- [{"piped-value", "value_loss.mean"}, {"piped", "rewards.mean"}] do
        File.mkdir_p!(experiment_dir(dir, "llm_rl"))
        File.write!(Metrics.path(experiment_dir(dir, "llm_rl")), ~s({"step": 0, "#{key}": 1.0}\n))
      end

      {:ok, view, _html} = live(conn, ~p"/compare?runs=alpha,piped")
      assert has_element?(view, "#compare-run-piped", "llm_rl")

      view |> element("#metrics") |> render_hook("load_metrics", %{})

      assert_reply(view, %{
        runs: [%{name: "alpha"}, %{name: "piped", series: %{"rewards.mean" => [1.0]} = series}]
      })

      refute Map.has_key?(series, "value_loss.mean")

      # Only the main stage's new rows are pushed.
      Runs.broadcast_run(
        "piped",
        {:metrics, "piped", "value", [%{step: 1, values: %{}, nan: []}]}
      )

      refute_push_event(view, "metrics_append", _)
      Runs.broadcast_run("piped", {:metrics, "piped", "rl", [%{step: 1, values: %{}, nan: []}]})
      assert_push_event(view, "metrics_append", %{run: "piped", rows: [%{step: 1}]})
    end

    test "removing a run keeps the others' colors and reloads the charts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compare?runs=alpha,beta,gamma")
      view |> element("#metrics") |> render_hook("load_metrics", %{})

      view |> element("#compare-run-beta button[aria-label='Remove beta']") |> render_click()

      assert_patch(view, ~p"/compare?#{[runs: "alpha,gamma"]}")
      refute has_element?(view, "#compare-run-beta")
      assert slot_style(view, "gamma") =~ "--series-3"
      assert_push_event(view, "metrics_reload", %{})

      # A run added now takes the free slot, not the next one.
      view |> form("#add-run-form", %{name: "beta"}) |> render_submit()
      assert_patch(view, ~p"/compare?#{[runs: "alpha,gamma,beta"]}")
      assert slot_style(view, "beta") =~ "--series-2"
    end

    test "rejects unknown run names", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compare?runs=alpha")
      html = view |> form("#add-run-form", %{name: "missing"}) |> render_submit()
      assert html =~ "No run named &quot;missing&quot;."
    end

    test "stops offering to add runs at 8", %{conn: conn} do
      names = for i <- 1..9, do: "extra-#{i}"

      for name <- names do
        File.mkdir_p!(experiment_dir(name))
        File.write!(Path.join(experiment_dir(name), "config.json"), "{}")
      end

      Runs.import_existing_runs()

      {:ok, view, _html} = live(conn, ~p"/compare?#{[runs: Enum.join(names, ",")]}")

      assert view
             |> element("#compare-legend")
             |> render()
             |> String.split("compare-run-")
             |> length() == 9

      refute has_element?(view, "#add-run-form")
    end
  end
end
