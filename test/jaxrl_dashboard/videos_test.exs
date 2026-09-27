defmodule JaxrlDashboard.VideosTest do
  # Runs real processes through run_job.sh and test/support/fake_record.sh.
  use JaxrlDashboard.DataCase, async: false

  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.{Runs, Videos}
  alias JaxrlDashboard.Videos.Recorder

  setup :setup_run_dirs

  defp fake_record(args) do
    [bash, script] = project("jaxrl").record_command |> Enum.take(2)
    put_project_setting("jaxrl", :record_command, [bash, script | args])
  end

  defp wait_for_state(name, state, timeout \\ 5_000) do
    wait_until(fn -> (status = Videos.status(name)).state == state && status end, timeout)
  end

  describe "recordable?/1" do
    defp run_with(config, project \\ "jaxrl"), do: %Runs.Run{project: project, config: config}

    test "only jaxrl runs on rust envs" do
      assert Videos.recordable?(run_with(%{"environment" => %{"env_type" => "rust_multi"}}))
      assert Videos.recordable?(run_with(%{"environment" => %{"env_type" => "rust_snake"}}))

      refute Videos.recordable?(run_with(%{"environment" => %{"env_type" => "craftax"}}))
      refute Videos.recordable?(run_with(%{}))

      # llm_rl has no record command.
      refute Videos.recordable?(
               run_with(%{"environment" => %{"env_type" => "rust_multi"}}, "llm_rl")
             )
    end
  end

  describe "parse_progress/1" do
    test "follows the task and step" do
      assert Videos.parse_progress(["Loading"]) == nil

      progress =
        Videos.parse_progress([
          "Recording task 1/2: find return (8 agents, 512 steps, 640x640)",
          "  find return: step 512/512",
          "  find return: done in 2.1s",
          "Recording task 2/2: snake (256 agents, 512 steps, 750x750)",
          "  snake: step 128/512"
        ])

      assert %{task: "snake", task_index: 2, task_count: 2, step: 128, steps: 512} = progress
      assert Videos.fraction(progress) == 0.625
    end
  end

  describe "status/1" do
    test "shows the newest complete set only" do
      run = recordable_run_fixture("sets")
      dir = Videos.videos_dir(run.name)

      write_set = fn id, videos ->
        File.mkdir_p!(Path.join(dir, id))
        manifest = %{"checkpoint_step" => 3, "videos" => videos}
        File.write!(Path.join([dir, id, "manifest.json"]), Jason.encode!(manifest))
      end

      assert Videos.status(run.name) == %{state: :idle, progress: nil, error: nil, set: nil}

      write_set.("20260101T000000Z", [%{"task" => "old", "file" => "task-0.mp4"}])
      # Incomplete: no manifest yet.
      File.mkdir_p!(Path.join(dir, "20260301T000000Z"))
      # Entries whose file names could point elsewhere are dropped.
      write_set.("20260201T000000Z", [
        %{"task" => "new", "file" => "task-0.mp4", "width" => 8, "height" => 6},
        %{"task" => "evil", "file" => "../../secret.mp4"}
      ])

      assert %{
               id: "20260201T000000Z",
               checkpoint_step: 3,
               videos: [%{task: "new", file: "task-0.mp4", width: 8, height: 6}]
             } = Videos.latest_set(run.name)

      Videos.prune(run.name)
      assert File.ls!(dir) == ["20260201T000000Z"]
    end

    test "video_path/3 only accepts set ids and video file names" do
      assert Videos.video_path("r", "20260201T000000Z", "task-1.mp4") =~
               ~r"/r/videos/20260201T000000Z/task-1.mp4$"

      assert Videos.video_path("r", "..", "task-1.mp4") == nil
      assert Videos.video_path("r", "20260201T000000Z", "../output.log") == nil
    end
  end

  describe "recorder" do
    test "records a set and reports progress on the run's topic" do
      fake_record(["--fake-sleep", "0.5"])
      run = recordable_run_fixture("rec")
      Runs.subscribe_run(run.name)
      start_supervised!(Recorder)

      assert {:ok, %{state: :recording}} = Recorder.start(run)
      assert {:error, message} = Recorder.start(run)
      assert message =~ "already being recorded"

      status = wait_for_state(run.name, :idle)
      assert %{checkpoint_step: 7, videos: [%{task: "task_0"}, %{task: "task_1"}]} = status.set
      assert_receive {:videos, "rec", %{state: :idle, set: %{}}}, 2_000
    end

    test "re-recording replaces the old set" do
      run = recordable_run_fixture("again")
      start_supervised!(Recorder)

      {:ok, _} = Recorder.start(run)
      %{set: %{id: first}} = wait_for_state(run.name, :idle)
      # Set ids have one-second resolution.
      Process.sleep(1_000)

      {:ok, _} = Recorder.start(run)
      wait_until(fn -> Videos.latest_set(run.name).id != first end)
      wait_until(fn -> not File.exists?(Path.join(Videos.videos_dir(run.name), first)) end)
    end

    test "reports failures with the output" do
      fake_record(["--fake-exit-code", "1"])
      run = recordable_run_fixture("broken")
      start_supervised!(Recorder)

      {:ok, _} = Recorder.start(run)

      status = wait_for_state(run.name, :failed)
      assert status.error.summary == "ValueError: fake failure"
      assert "Loading broken" in status.error.output
      assert status.set == nil
    end

    test "falls back to the exit code when there's no exception to show" do
      put_project_setting("jaxrl", :record_command, [
        "bash",
        "-c",
        "echo 'snake: step 1/2'; exit 137",
        "--"
      ])

      run = recordable_run_fixture("killed")
      start_supervised!(Recorder)

      {:ok, _} = Recorder.start(run)

      assert wait_for_state(run.name, :failed).error.summary == "exited with code 137."
    end

    test "refuses runs it can't record" do
      start_supervised!(Recorder)

      assert {:error, "Only jaxrl runs on rust environments can be recorded."} =
               Recorder.start(recordable_run_fixture("jax", env_type: "find_return"))

      assert {:error, "fresh hasn't saved a checkpoint yet."} =
               Recorder.start(recordable_run_fixture("fresh", checkpoint: false))
    end

    test "limits concurrent recordings, and cancelling frees the slot" do
      fake_record(["--fake-sleep", "60"])
      first = recordable_run_fixture("first")
      second = recordable_run_fixture("second")
      start_supervised!(Recorder)

      {:ok, _} = Recorder.start(first)

      assert {:error, "Already recording first. Try again once that finishes."} =
               Recorder.start(second)

      {:ok, pid} = JaxrlDashboard.Runs.Launcher.read_pid(Videos.job_dir("first"))
      :ok = Recorder.cancel("first")

      assert wait_for_state("first", :idle).set == nil
      # The fake recorder's `sleep` child is gone too, not just the wrapper.
      wait_until(fn -> System.cmd("pgrep", ["-g", "#{pid}"]) |> elem(0) == "" end)

      fake_record([])
      assert {:ok, _} = Recorder.start(second)
    end

    test "a restarted recorder adopts recordings in progress" do
      fake_record(["--fake-sleep", "0.5"])
      run = recordable_run_fixture("adopted")
      start_supervised!(Recorder)
      {:ok, _} = Recorder.start(run)
      stop_supervised!(Recorder)

      Runs.subscribe_run(run.name)
      start_supervised!(Recorder)

      assert_receive {:videos, "adopted", %{state: :idle, set: %{}}}, 5_000
    end
  end
end
