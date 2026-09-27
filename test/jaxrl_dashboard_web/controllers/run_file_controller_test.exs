defmodule JaxrlDashboardWeb.RunFileControllerTest do
  use JaxrlDashboardWeb.ConnCase, async: false

  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Videos

  setup :setup_run_dirs

  describe "video" do
    setup :register_and_log_in_user

    setup do
      run = recordable_run_fixture("vid")
      dir = Path.join(Videos.videos_dir(run.name), "20260926T120000Z")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "task-0.mp4"), "0123456789")
      %{path: ~p"/runs/vid/videos/20260926T120000Z/task-0.mp4"}
    end

    test "serves the whole file", %{conn: conn, path: path} do
      conn = get(conn, path)

      assert response(conn, 200) == "0123456789"
      assert response_content_type(conn, :mp4) =~ "video/mp4"
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "serves byte ranges", %{conn: conn, path: path} do
      ranged = fn range -> conn |> put_req_header("range", range) |> get(path) end

      conn = ranged.("bytes=2-5")
      assert response(conn, 206) == "2345"
      assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]

      assert response(ranged.("bytes=7-"), 206) == "789"
      assert response(ranged.("bytes=-3"), 206) == "789"
      assert response(ranged.("bytes=8-100"), 206) == "89"
      assert response(ranged.("bytes=10-"), 416) == ""
      assert response(ranged.("bytes=0-1,4-5"), 200) == "0123456789"
    end

    test "only serves video files of the run's sets", %{conn: conn} do
      File.write!(Path.join(Videos.job_dir("vid") |> tap(&File.mkdir_p!/1), "output.log"), "x")

      assert conn |> get(~p"/runs/vid/videos/job/output.log") |> response(404)
      assert conn |> get(~p"/runs/vid/videos/20260926T120000Z/task-1.mp4") |> response(404)

      assert_error_sent 404, fn ->
        get(conn, ~p"/runs/nope/videos/20260926T120000Z/task-0.mp4")
      end
    end
  end

  test "requires login", %{conn: conn} do
    conn = get(conn, ~p"/runs/vid/videos/20260926T120000Z/task-0.mp4")
    assert redirected_to(conn) == ~p"/log-in"
  end
end
