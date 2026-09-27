defmodule JaxrlDashboard.MetricsTest do
  use ExUnit.Case, async: false

  import JaxrlDashboard.RunsFixtures

  alias JaxrlDashboard.Metrics

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

    test "parses an llm_rl row, whose stats are dotted keys" do
      assert Metrics.parse_line(~s({"step": 2, "rewards.mean": 0.5, "rewards.max": 1.0})) ==
               %{step: 2, values: %{"rewards.mean" => 0.5, "rewards.max" => 1.0}, nan: []}
    end

    test "leaves the step of a row without one unknown" do
      assert Metrics.parse_line(~s({"loss": 1.0})) == %{
               step: nil,
               values: %{"loss" => 1.0},
               nan: []
             }
    end

    test "rejects lines that aren't metrics rows" do
      assert Metrics.parse_line("") == nil
      assert Metrics.parse_line("{truncated") == nil
      assert Metrics.parse_line(~s({"step": "one", "loss": 1})) == nil
      assert Metrics.parse_line(~s([1, 2])) == nil
    end
  end

  test "parse_lines/1 drops rows without a step, whose place in the file isn't known" do
    lines = [{0, ~s({"loss": 1.0})}, {14, ~s({"step": 4, "loss": 2.0})}]
    assert [%{step: 4}] = Metrics.parse_lines(lines)
  end

  describe "load/1" do
    setup :setup_run_dirs

    test "returns the run's metrics as columns" do
      dir = experiment_dir("my-run")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "logs.jsonl"), """
      {"step": 0, "loss": 1.0}
      {"step": 1, "loss": NaN, "reward": 5}
      {"step": 2, "loss": NaN, "reward": 6}
      not json
      {"step": 3, "loss": 0.5}\
      """)

      assert Metrics.load(dir) == %{
               steps: [0, 1, 2, 3],
               series: %{"loss" => [1.0, nil, nil, 0.5], "reward" => [nil, 5, 6, nil]},
               nan: %{"loss" => %{first: 1, last: 2, count: 2}}
             }
    end

    test "numbers rows without a step by line (llm_rl logs from before it logged steps)" do
      dir = experiment_dir("stepless", "llm_rl")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "logs.jsonl"), ~s({"a": 1}\n{"a": 2}\n{"a": 3}\n))

      assert %{steps: [0, 1, 2], series: %{"a" => [1, 2, 3]}} = Metrics.load(dir)
    end

    test "is empty for a run without metrics" do
      assert Metrics.load(experiment_dir("nothing-here")) == %{steps: [], series: %{}, nan: %{}}
    end
  end
end
