defmodule JaxrlDashboard.Projects.Stage do
  @moduledoc """
  One step of a run that writes its own results directory (`experiment`,
  under the project's results dir) with its own `logs.jsonl`.

  Most runs have a single stage named after the run. An llm_rl PPO pipeline
  has two: value warmup (`NAME-value`), then RL (`NAME`).
  """

  @enforce_keys [:id, :label, :experiment]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), label: String.t(), experiment: String.t()}

  @doc "The only stage of a single-stage run."
  def single(name), do: %__MODULE__{id: "train", label: "Training", experiment: name}
end
