defmodule JaxrlDashboardWeb.ConfigLiveTest do
  use JaxrlDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.{FakeConfigValidator, Runs}

  setup :setup_run_dirs

  @base %{
    "seed" => "random",
    "max_env_steps" => 512,
    "update_steps" => 100,
    "learner" => %{
      "optimizer" => %{"type" => "adamw", "learning_rate" => 0.001},
      "model" => %{
        "obs_encoder" => %{"obs_type" => "grid_cnn", "kernels" => [[3, 3]], "channels" => [16]},
        "layer" => %{"feed_forward" => %{"size" => 64}}
      },
      "trainer" => %{"trainer_type" => "ppo"}
    },
    "environment" => %{
      "env_type" => "rust_vec",
      "num" => 8,
      "env" => %{"env_type" => "rust_snake"}
    }
  }

  test "requires login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/configs/new")
  end

  describe "the builder" do
    setup :register_and_log_in_user

    setup do
      write_config("base.json", @base)
      :ok
    end

    defp open(conn), do: live(conn, ~p"/configs/new?#{[from: "file:base.json"]}")

    defp change(view, target, value) do
      view
      |> form("#config-form")
      |> render_change(
        Map.put(
          put_in(%{}, Enum.map(["config" | target], &Access.key(&1, %{})), value),
          "_target",
          ["config" | target]
        )
      )
    end

    defp json(view),
      do:
        view
        |> element("#config-json")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> Jason.decode!()

    test "renders the config as a form generated from the schema", %{conn: conn} do
      {:ok, view, html} = open(conn)

      assert html =~ "Based on base.json."
      assert has_element?(view, "#cfg-max_env_steps[value='512']")
      assert has_element?(view, "#cfg-learner-optimizer-learning_rate[value='0.001']")
      assert has_element?(view, "#cfg-learner-optimizer-type option[selected][value=adamw]")

      assert has_element?(
               view,
               "#cfg-learner-model-obs_encoder-variant option[selected][value=grid_cnn]"
             )

      assert has_element?(view, "#cfg-environment-env-type option[selected][value=rust_vec]")
      assert has_element?(view, "#config-status", "Valid config")
      assert json(view) == @base
    end

    test "edits values with their types", %{conn: conn} do
      {:ok, view, _html} = open(conn)

      change(view, ~w(learner optimizer learning_rate), "3e-4")
      change(view, ["max_env_steps"], "1024")

      assert json(view)["max_env_steps"] == 1024
      assert get_in(json(view), ~w(learner optimizer learning_rate)) == 3.0e-4
      assert render(view) =~ "Based on base.json (edited)."
    end

    test "shows validation problems at their fields and blocks queueing", %{conn: conn} do
      FakeConfigValidator.put_errors(fn config ->
        if config["max_env_steps"] == "lots",
          do: [%{path: ["max_env_steps"], message: "Input should be a valid integer"}],
          else: []
      end)

      {:ok, view, _html} = open(conn)
      change(view, ["max_env_steps"], "lots")

      assert has_element?(view, "#cfg-max_env_steps-field", "Input should be a valid integer")
      assert has_element?(view, "#cfg-max_env_steps.input-error")
      assert has_element?(view, "#config-status", "1 problem")
      assert has_element?(view, "#queue-form button[disabled]")
      assert has_element?(view, "#save-form button[disabled]")
    end

    test "switches union variants and environments", %{conn: conn} do
      {:ok, view, _html} = open(conn)

      change(view, ~w(learner model obs_encoder __variant), "linear")
      assert get_in(json(view), ~w(learner model obs_encoder)) == %{"obs_type" => "linear"}
      refute has_element?(view, "#cfg-learner-model-obs_encoder-kernels")

      change(view, ~w(learner model layer history __variant), "attention")
      assert has_element?(view, "#cfg-learner-model-layer-history-num_heads")

      change(view, ~w(environment __env_type), "vec")
      assert %{"env_type" => "vec", "num" => 8} = json(view)["environment"]
    end

    test "adds and removes list items", %{conn: conn} do
      {:ok, view, _html} = open(conn)

      view
      |> element(~s(#cfg-learner-model-obs_encoder-kernels button[phx-click*="add_item"]))
      |> render_click()

      assert get_in(json(view), ~w(learner model obs_encoder kernels)) == [[3, 3], [nil, nil]]

      view
      |> element(~s(#cfg-learner-model-obs_encoder-kernels button[aria-label="Remove item 0"]))
      |> render_click()

      assert get_in(json(view), ~w(learner model obs_encoder kernels)) == [[nil, nil]]
    end

    test "flags keys the model doesn't have and lets you remove them", %{conn: conn} do
      write_config("stale.json", put_in(@base, ~w(learner trainer vf_clip), 0.2))
      {:ok, view, _html} = live(conn, ~p"/configs/new?#{[from: "file:stale.json"]}")

      assert has_element?(view, "#cfg-learner-trainer-vf_clip", "isn't a field of this model")
      view |> element("#cfg-learner-trainer-vf_clip button", "Remove") |> render_click()

      refute has_element?(view, "#cfg-learner-trainer-vf_clip")
      refute Map.has_key?(json(view)["learner"]["trainer"], "vf_clip")
    end

    test "queues a run with the built config", %{conn: conn} do
      {:ok, view, _html} = open(conn)
      change(view, ["update_steps"], "7")

      {:ok, _run_view, html} =
        view
        |> form("#queue-form", run: %{name: "from-builder"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/runs/from-builder")

      assert html =~ "Queued from-builder"
      run = Runs.get_run_by_name!("from-builder")
      assert run.config["update_steps"] == 7
      assert run.config_source == "base.json (edited)"
    end

    test "saves a new config file", %{conn: conn} do
      {:ok, view, _html} = open(conn)
      change(view, ["update_steps"], "9")

      view |> form("#save-form", file: %{name: "tuned"}) |> render_submit()

      assert_patch(view, ~p"/configs/new?#{[project: "jaxrl", from: "file:tuned.json"]}")

      assert Jason.decode!(File.read!(Path.join(config_dir(), "tuned.json")))[
               "update_steps"
             ] == 9

      assert render(view) =~ "Saved tuned.json"
    end

    test "won't overwrite an existing file", %{conn: conn} do
      {:ok, view, _html} = open(conn)
      html = view |> form("#save-form", file: %{name: "base"}) |> render_submit()
      assert html =~ "base.json already exists"
    end

    test "starts from a run's config", %{conn: conn, user: user} do
      {:ok, _} =
        Runs.enqueue_run(JaxrlDashboard.Accounts.Scope.for_user(user), %{
          "project" => "jaxrl",
          "config_source" => "base.json",
          "name" => "earlier"
        })

      {:ok, view, html} = live(conn, ~p"/configs/new?#{[from: "run:earlier"]}")

      assert html =~ "Based on earlier."
      assert json(view) == @base
    end

    test "falls back to defaults for an unknown source", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/configs/new?project=jaxrl"}}} =
               live(conn, ~p"/configs/new?#{[from: "file:nope.json"]}")
    end
  end

  describe "the builder in another project" do
    setup :register_and_log_in_user

    @ppo %{
      "base_model" => "Qwen/Qwen3-4B-Instruct-2507",
      "loss" => %{"type" => "ppo", "gae_lambda" => 0.95},
      "logger" => %{"use_jsonl" => false, "use_wandb" => true},
      "env" => %{"name" => "wordle", "max_guesses" => 6}
    }

    setup do
      write_config("base.json", @base)
      write_config("ppo.json", @ppo, "llm_rl")
      :ok
    end

    test "works in the project from the URL, with its own files and schema", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/configs/new?#{[project: "llm_rl"]}")

      assert html =~ "Starting from llm_rl&#39;s defaults."
      assert has_element?(view, ~s(#project-llm_rl[aria-current="page"]))
      assert has_element?(view, "#start-from a", "ppo.json")
      refute has_element?(view, "#start-from a", "base.json")
      # llm_rl's schema: a tagged loss union, not jaxrl's learner.
      assert has_element?(view, ~s(#config-form [name="config[loss][__variant]"]))
      refute has_element?(view, ~s(#config-form [name^="config[learner]"]))
    end

    test "switching projects starts over in the other one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/configs/new?#{[from: "file:base.json"]}")
      assert has_element?(view, ~s(#project-jaxrl[aria-current="page"]))

      view |> element("#project-llm_rl") |> render_click()

      assert_patch(view, ~p"/configs/new?#{[project: "llm_rl"]}")
      assert has_element?(view, "#start-from a", "ppo.json")
    end

    test "says how the run will go before it's queued, then queues it", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/configs/new?#{[project: "llm_rl", from: "file:ppo.json"]}")

      assert view |> element("#queue-stages") |> render() =~ "Value warmup"
      assert view |> element("#queue-adjustments") |> render() =~ "logger.use_jsonl = true"

      view |> form("#queue-form", run: %{name: "wordle-ppo"}) |> render_submit()
      assert_redirect(view, ~p"/runs/wordle-ppo")

      run = Runs.get_run_by_name!("wordle-ppo")
      assert run.project == "llm_rl"
      assert run.config["logger"]["use_jsonl"] == true
    end

    test "opens a run's config in the run's project", %{conn: conn, user: user} do
      {:ok, _} =
        Runs.enqueue_run(JaxrlDashboard.Accounts.Scope.for_user(user), %{
          "project" => "llm_rl",
          "config_source" => "ppo.json",
          "name" => "earlier-llm"
        })

      {:ok, view, html} = live(conn, ~p"/configs/new?#{[from: "run:earlier-llm"]}")

      assert html =~ "Based on earlier-llm."
      assert has_element?(view, ~s(#project-llm_rl[aria-current="page"]))
    end

    test "saves files to the project's config directory", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/configs/new?#{[project: "llm_rl", from: "file:ppo.json"]}")

      view |> form("#save-form", file: %{name: "copy"}) |> render_submit()

      assert_patch(view, ~p"/configs/new?#{[project: "llm_rl", from: "file:copy.json"]}")
      assert "copy.json" in config_files("llm_rl")
      refute "copy.json" in config_files("jaxrl")
    end
  end
end
