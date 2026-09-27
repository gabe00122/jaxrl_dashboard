defmodule JaxrlDashboard.Projects.Jaxrl do
  @moduledoc """
  jaxrl (`mapox_trainer`): multi-agent gridworld RL. One `pmarl train`
  process per run, writing to `results/NAME`.
  """

  @behaviour JaxrlDashboard.Projects.Adapter

  alias JaxrlDashboard.Projects.Stage

  @impl true
  def train_args(config_path, results_dir, name),
    do: ["--config", config_path, "--base-dir", results_dir, "--name", name]

  @impl true
  def prepare_config(config), do: config

  @impl true
  def stages(name, _config), do: [Stage.single(name)]

  # `pmarl record` renders the rust environments.
  @impl true
  def recordable?(%{"environment" => %{"env_type" => "rust_" <> _}}), do: true
  def recordable?(_config), do: false

  @impl true
  def validator_script, do: "jaxrl_config_validator.py"
end
