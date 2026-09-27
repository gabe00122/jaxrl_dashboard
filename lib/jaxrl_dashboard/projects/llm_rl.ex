defmodule JaxrlDashboard.Projects.LlmRl do
  @moduledoc """
  llm_rl (`valm`): LLM finetuning with value approximation.

  Runs go through `valm pipeline`, which runs each stage as a subprocess:

    * PPO: build offline data (shared `offline_data/`, reused once it's
      there), then value warmup (`results/NAME-value`), then RL
      (`results/NAME`)
    * GRPO: RL only, there's no critic to warm up
  """

  @behaviour JaxrlDashboard.Projects.Adapter

  alias JaxrlDashboard.Projects.Stage

  @impl true
  def train_args(config_path, results_dir, name),
    do: [config_path, "--run-id", name, "--base-dir", results_dir]

  # The dashboard reads metrics from logs.jsonl, which valm's configs usually
  # turn off in favour of wandb. The TUI needs a terminal, which runs don't
  # have (use_tui only exists in newer valm versions, so it's only ever
  # turned off, never added).
  @impl true
  def prepare_config(%{"logger" => %{} = logger} = config) do
    logger =
      case logger do
        %{"use_tui" => true} -> %{logger | "use_tui" => false}
        _ -> logger
      end

    %{config | "logger" => Map.put(logger, "use_jsonl", true)}
  end

  def prepare_config(config), do: config

  @impl true
  def stages(name, %{"loss" => %{"type" => "ppo"}}) do
    [
      %Stage{id: "value", label: "Value warmup", experiment: "#{name}-value"},
      %Stage{id: "rl", label: "RL", experiment: name}
    ]
  end

  def stages(name, _config), do: [%Stage{id: "rl", label: "RL", experiment: name}]

  @impl true
  def recordable?(_config), do: false

  @impl true
  def validator_script, do: "llm_rl_config_validator.py"
end
