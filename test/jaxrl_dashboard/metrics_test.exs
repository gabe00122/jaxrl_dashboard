defmodule JaxrlDashboard.MetricsTest do
  use ExUnit.Case, async: false

  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Metrics
  alias JaxrlDashboard.Runs.Settings

  describe "parse_line/1" do
    test "parses a jaxrl metrics row" do
      assert Metrics.parse_line(~s({"step": 3, "algo/actor_loss": 0.5, "env/reward": 2})) ==
               %{step: 3, values: %{"algo/actor_loss" => 0.5, "env/reward" => 2}, nan: []}
    end

    test "turns Python's NaN and Infinity into nil and records them" do
      line = ~s({"step": 7, "a": NaN, "b": Infinity, "c": -Infinity, "d": 1.0})

      assert Metrics.parse_line(line) == %{
               step: 7,
               values: %{"a" => nil, "b" => nil, "c" => nil, "d" => 1.0},
               nan: ["a", "b", "c"]
             }
    end

    test "leaves key names that mention NaN alone" do
      assert %{values: %{"NaN_count" => 2}} = Metrics.parse_line(~s({"step": 1, "NaN_count": 2}))
    end

    test "drops non-numeric values" do
      assert %{values: %{}} = Metrics.parse_line(~s({"step": 1, "note": "hi", "ok": true}))
    end

    test "rejects lines that aren't metrics rows" do
      assert Metrics.parse_line("") == nil
      assert Metrics.parse_line("{truncated") == nil
      assert Metrics.parse_line(~s({"no_step": 1})) == nil
      assert Metrics.parse_line(~s([1, 2])) == nil
    end
  end

  describe "load/1" do
    setup :setup_run_dirs

    test "returns the run's metrics as columns" do
      dir = Settings.experiment_dir("my-run")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "logs.jsonl"), """
      {"step": 0, "loss": 1.0}
      {"step": 1, "loss": NaN, "reward": 5}
      {"step": 2, "loss": NaN, "reward": 6}
      not json
      {"step": 3, "loss": 0.5}\
      """)

      assert Metrics.load("my-run") == %{
               steps: [0, 1, 2, 3],
               series: %{"loss" => [1.0, nil, nil, 0.5], "reward" => [nil, 5, 6, nil]},
               nan: %{"loss" => %{first: 1, last: 2, count: 2}}
             }
    end

    test "is empty for a run without metrics" do
      assert Metrics.load("nothing-here") == %{steps: [], series: %{}, nan: %{}}
    end
  end
end
