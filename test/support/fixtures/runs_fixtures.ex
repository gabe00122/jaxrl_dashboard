defmodule JaxrlDashboard.RunsFixtures do
  @moduledoc """
  Points the run settings at a fresh temp directory with its own config,
  results and data dirs. Changes global app config, so tests using it must
  not be async.
  """

  import ExUnit.Callbacks

  alias JaxrlDashboard.Runs.Settings

  def setup_run_dirs(_context \\ %{}) do
    root =
      Path.join(System.tmp_dir!(), "jaxrl_dashboard_test_#{System.unique_integer([:positive])}")

    dirs = [
      project_dir: root,
      config_dir: Path.join(root, "config"),
      results_dir: Path.join(root, "results"),
      data_dir: Path.join(root, "data")
    ]

    Enum.each(dirs, fn {_, dir} -> File.mkdir_p!(dir) end)

    original = Application.fetch_env!(:jaxrl_dashboard, :runs)
    Application.put_env(:jaxrl_dashboard, :runs, Keyword.merge(original, dirs))

    on_exit(fn ->
      Enum.each(JaxrlDashboard.Runs.Watcher.watched_names(), &JaxrlDashboard.Runs.Watcher.stop/1)
      Application.put_env(:jaxrl_dashboard, :runs, original)
      File.rm_rf!(root)
    end)

    %{run_dirs: Map.new(dirs)}
  end

  def put_run_setting(key, value) do
    runs = Application.fetch_env!(:jaxrl_dashboard, :runs)
    Application.put_env(:jaxrl_dashboard, :runs, Keyword.put(runs, key, value))
  end

  def write_config(file_name, config \\ %{"seed" => 0}) do
    File.write!(Path.join(Settings.config_dir(), file_name), Jason.encode!(config))
    file_name
  end

  @doc "Polls `fun` until it returns a truthy value, or fails after `timeout` ms."
  def wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      result = fun.() ->
        result

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("condition not met in time")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
