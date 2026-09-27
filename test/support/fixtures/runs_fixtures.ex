defmodule JaxrlDashboard.RunsFixtures do
  @moduledoc """
  Points every project at its own fresh temp checkout (config and results
  dirs), and the dashboard's run data at a temp dir too. Changes global app
  config, so tests using it must not be async.

  Helpers that take a project default to jaxrl, the project most tests use.
  """

  import ExUnit.Callbacks

  alias JaxrlDashboard.Projects
  alias JaxrlDashboard.Projects.Project

  def setup_run_dirs(_context \\ %{}) do
    root =
      Path.join(System.tmp_dir!(), "jaxrl_dashboard_test_#{System.unique_integer([:positive])}")

    original_projects = Application.fetch_env!(:jaxrl_dashboard, :projects)
    original_runs = Application.fetch_env!(:jaxrl_dashboard, :runs)

    projects =
      for {id, opts} <- original_projects do
        dir = Path.join(root, Atom.to_string(id))

        dirs = [
          dir: dir,
          config_dir: Path.join(dir, Path.basename(opts[:config_dir])),
          results_dir: Path.join(dir, "results")
        ]

        Enum.each(dirs, fn {_, dir} -> File.mkdir_p!(dir) end)
        {id, Keyword.merge(opts, dirs)}
      end

    data_dir = Path.join(root, "data")
    File.mkdir_p!(data_dir)

    Application.put_env(:jaxrl_dashboard, :projects, projects)
    Application.put_env(:jaxrl_dashboard, :runs, Keyword.put(original_runs, :data_dir, data_dir))

    on_exit(fn ->
      Enum.each(JaxrlDashboard.Runs.Watcher.watched_names(), &JaxrlDashboard.Runs.Watcher.stop/1)
      Application.put_env(:jaxrl_dashboard, :projects, original_projects)
      Application.put_env(:jaxrl_dashboard, :runs, original_runs)
      File.rm_rf!(root)
    end)

    %{run_dirs: %{root: root, data_dir: data_dir}}
  end

  def put_run_setting(key, value) do
    runs = Application.fetch_env!(:jaxrl_dashboard, :runs)
    Application.put_env(:jaxrl_dashboard, :runs, Keyword.put(runs, key, value))
  end

  @doc "Changes one setting of a project, like its `train_command`."
  def put_project_setting(project_id, key, value) do
    projects = Application.fetch_env!(:jaxrl_dashboard, :projects)
    id = String.to_existing_atom(project_id)
    Application.put_env(:jaxrl_dashboard, :projects, put_in(projects, [id, key], value))
  end

  def project(id \\ "jaxrl"), do: Projects.get!(id)
  def config_dir(project_id \\ "jaxrl"), do: project(project_id).config_dir
  def results_dir(project_id \\ "jaxrl"), do: project(project_id).results_dir
  def config_files(project_id \\ "jaxrl"), do: Project.config_files(project(project_id))

  def experiment_dir(name, project_id \\ "jaxrl"),
    do: Project.experiment_dir(project(project_id), name)

  def write_config(file_name, config \\ %{"seed" => 0}, project_id \\ "jaxrl") do
    File.write!(Path.join(config_dir(project_id), file_name), Jason.encode!(config))
    file_name
  end

  @doc """
  An imported run on a rust env with a saved checkpoint, so it can be
  recorded. Pass `checkpoint: false` to leave out the checkpoint.
  """
  def recordable_run_fixture(name, opts \\ []) do
    dir = experiment_dir(name)
    File.mkdir_p!(dir)

    if Keyword.get(opts, :checkpoint, true),
      do: File.mkdir_p!(Path.join([dir, "checkpoints", "7"]))

    config = %{"environment" => %{"env_type" => Keyword.get(opts, :env_type, "rust_multi")}}
    File.write!(Path.join(dir, "config.json"), Jason.encode!(config))
    {[^name], []} = JaxrlDashboard.Runs.import_existing_runs()
    JaxrlDashboard.Runs.get_run_by_name!(name)
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
