defmodule JaxrlDashboard.Configs.EditorTest do
  use ExUnit.Case, async: true

  alias JaxrlDashboard.Configs.{Editor, Schema}

  setup_all do
    {:ok, raw} = JaxrlDashboard.FakeConfigValidator.schema()
    %{schema: Schema.new(raw)}
  end

  @config %{
    "seed" => "random",
    "max_env_steps" => 512,
    "learner" => %{
      "optimizer" => %{"type" => "adamw", "learning_rate" => 0.001},
      "model" => %{
        "obs_encoder" => %{"obs_type" => "grid_cnn", "kernels" => [[3, 3]], "channels" => [16]},
        "layer" => %{"feed_forward" => %{"size" => 64}}
      }
    },
    "environment" => %{
      "env_type" => "rust_vec",
      "num" => 8,
      "env" => %{"env_type" => "rust_snake"}
    }
  }

  test "sets typed values from form strings", %{schema: schema} do
    config = Editor.apply_input(schema, @config, ~w(learner optimizer learning_rate), "3e-4")
    assert get_in(config, ~w(learner optimizer learning_rate)) == 3.0e-4

    config = Editor.apply_input(schema, config, ["max_env_steps"], "1024")
    assert config["max_env_steps"] == 1024
  end

  test "emptying a field removes it so the default applies", %{schema: schema} do
    config = Editor.apply_input(schema, @config, ["max_env_steps"], "")
    refute Map.has_key?(config, "max_env_steps")
  end

  test "edits inside lists and tuples", %{schema: schema} do
    config = Editor.apply_input(schema, @config, ~w(learner model obs_encoder kernels 0 1), "5")
    assert get_in(config, ~w(learner model obs_encoder kernels)) == [[3, 5]]

    config = Editor.apply_input(schema, config, ~w(learner model obs_encoder channels 0), "32")
    assert get_in(config, ~w(learner model obs_encoder channels)) == [32]
  end

  test "adds and removes list items", %{schema: schema} do
    path = ~w(learner model obs_encoder kernels)
    config = Editor.add_item(schema, @config, path)
    assert Editor.get(config, path) == [[3, 3], [nil, nil]]

    config = Editor.remove(config, path ++ [0])
    assert Editor.get(config, path) == [[nil, nil]]
  end

  test "switching a union variant replaces its fields and sets the tag", %{schema: schema} do
    config =
      Editor.apply_input(schema, @config, ~w(learner model obs_encoder __variant), "linear")

    assert get_in(config, ~w(learner model obs_encoder)) == %{"obs_type" => "linear"}
  end

  test "an optional union can be turned on and off", %{schema: schema} do
    path = ~w(learner model layer history)
    config = Editor.apply_input(schema, @config, path ++ ["__variant"], "attention")
    assert %{"type" => "attention"} = Editor.get(config, path)

    config = Editor.apply_input(schema, config, path ++ ["__variant"], "")
    refute Map.has_key?(get_in(config, ~w(learner model layer)), "history")
  end

  test "seed switches between random and a number", %{schema: schema} do
    %{variants: variants} =
      Schema.describe(schema, Schema.node_at(schema, @config, ["seed"]), "random")

    int_index = Enum.find_index(variants, &(Schema.describe(schema, &1, nil).kind == :integer))

    config = Editor.apply_input(schema, @config, ["seed", "__choice"], to_string(int_index))
    config = Editor.apply_input(schema, config, ["seed"], "7")
    assert config["seed"] == 7
  end

  test "switching env_type rebuilds the environment", %{schema: schema} do
    config = Editor.apply_input(schema, @config, ["environment", "__env_type"], "vec")

    assert %{"env_type" => "vec", "num" => 8, "env" => %{"env_type" => "rust_snake"}} =
             config["environment"]

    config = Editor.apply_input(schema, config, ["environment", "env", "__env_type"], "snake")
    assert config["environment"]["env"]["env_type"] == "snake"
  end

  test "changes to paths outside the schema are ignored", %{schema: schema} do
    assert Editor.apply_input(schema, @config, ["not_a_field"], "1") == @config
  end

  test "removes keys the model doesn't have" do
    config = put_in(@config, ~w(learner optimizer typo), 1)
    assert Editor.remove(config, ~w(learner optimizer typo)) == @config
  end
end
