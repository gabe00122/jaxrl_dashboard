defmodule JaxrlDashboardWeb.RunVideosLiveTest do
  use JaxrlDashboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Videos
  alias JaxrlDashboard.Videos.Recorder

  setup :setup_run_dirs
  setup :register_and_log_in_user

  test "only rust-env runs have a videos section", %{conn: conn} do
    recordable_run_fixture("jax-env", env_type: "find_return")

    {:ok, view, _html} = live(conn, ~p"/runs/jax-env")

    refute has_element?(view, "#videos")
  end

  test "records videos with a button and shows one per task", %{conn: conn} do
    run = recordable_run_fixture("multi")
    start_supervised!(Recorder)
    {:ok, view, _html} = live(conn, ~p"/runs/multi")

    assert has_element?(view, "#videos-empty")
    refute has_element?(view, "#video-grid")

    view |> element("#record-videos") |> render_click()
    assert has_element?(view, "#videos-progress") or has_element?(view, "#video-grid")

    wait_until(fn -> Videos.status(run.name).state == :idle end)
    %{id: set_id} = Videos.latest_set(run.name)

    # The recorder's broadcast updates the page.
    wait_until(fn -> has_element?(view, "#video-grid") end)
    refute has_element?(view, "#videos-progress")
    refute has_element?(view, "#videos-empty")
    assert has_element?(view, "#videos-meta", "checkpoint 7")

    for {task, index} <- [{"task_0", 0}, {"task_1", 1}] do
      assert has_element?(view, "#video-#{set_id}-#{index} figcaption", task)

      assert has_element?(
               view,
               ~s(#video-#{set_id}-#{index} video[src="/runs/multi/videos/#{set_id}/task-#{index}.mp4"])
             )
    end

    assert has_element?(view, "#record-videos", "Re-record")
  end

  test "shows errors from starting a recording", %{conn: conn} do
    recordable_run_fixture("unsaved", checkpoint: false)
    start_supervised!(Recorder)
    {:ok, view, _html} = live(conn, ~p"/runs/unsaved")

    assert view |> element("#record-videos") |> render_click() =~
             "unsaved hasn&#39;t saved a checkpoint yet."
  end

  test "cancels a recording in progress", %{conn: conn} do
    [bash, script | _] = project("jaxrl").record_command
    put_project_setting("jaxrl", :record_command, [bash, script, "--fake-sleep", "60"])
    recordable_run_fixture("slow")
    start_supervised!(Recorder)
    {:ok, view, _html} = live(conn, ~p"/runs/slow")

    view |> element("#record-videos") |> render_click()
    assert has_element?(view, "#videos-progress", "Loading the latest checkpoint")

    view |> element("#cancel-recording") |> render_click()

    wait_until(fn -> has_element?(view, "#videos-empty") end)
    refute has_element?(view, "#videos-progress")
    assert has_element?(view, "#record-videos")
  end

  test "shows a failed recording", %{conn: conn} do
    [bash, script | _] = project("jaxrl").record_command
    put_project_setting("jaxrl", :record_command, [bash, script, "--fake-exit-code", "1"])
    recordable_run_fixture("fails")
    start_supervised!(Recorder)
    {:ok, view, _html} = live(conn, ~p"/runs/fails")

    view |> element("#record-videos") |> render_click()

    wait_until(fn -> has_element?(view, "#videos-error") end)
    assert has_element?(view, "#videos-error", "ValueError: fake failure")
  end
end
