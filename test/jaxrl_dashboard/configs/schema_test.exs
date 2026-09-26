defmodule JaxrlDashboard.Configs.SchemaTest do
  # Runs against a snapshot of jaxrl's real config schema.
  use ExUnit.Case, async: true

  alias JaxrlDashboard.Configs.{Editor, Schema}

  setup_all do
    {:ok, raw} = JaxrlDashboard.FakeConfigValidator.schema()
    %{schema: Schema.new(raw)}
  end

  defp describe_at(schema, config, path),
    do: Schema.describe(schema, Schema.node_at(schema, config, path), Editor.get(config, path))

  test "top-level fields keep the model's order", %{schema: schema} do
    %{kind: :object, properties: properties} =
      Schema.describe(schema, Schema.root_node(schema), %{})

    assert Enum.map(properties, &elem(&1, 0)) ==
             ~w(seed max_env_steps updates_per_jit update_steps num_checkpoints learner environment logger snapshot_league)

    assert {"max_env_steps", _, true} = List.keyfind(properties, "max_env_steps", 0)
    assert {"seed", _, false} = List.keyfind(properties, "seed", 0)
  end

  test "describes jaxrl's field kinds", %{schema: schema} do
    config = %{"learner" => %{"model" => %{"obs_encoder" => %{"obs_type" => "grid_cnn"}}}}

    assert %{kind: :choice} = describe_at(schema, config, ["seed"])
    assert %{kind: :integer} = describe_at(schema, config, ["max_env_steps"])

    assert %{kind: :number} =
             describe_at(schema, config, ["learner", "optimizer", "learning_rate"])

    assert %{kind: :enum, values: ~w(adamw muon)} =
             describe_at(schema, config, ["learner", "optimizer", "type"])

    assert %{kind: :boolean} = describe_at(schema, config, ["snapshot_league"])

    assert %{kind: :optional} =
             describe_at(schema, config, ["learner", "model", "value_hidden_dim"])

    assert %{kind: :environment} = describe_at(schema, config, ["environment"])

    assert %{kind: :union, key: "obs_type", tags: tags, tag: "grid_cnn"} =
             describe_at(schema, config, ["learner", "model", "obs_encoder"])

    assert Enum.sort(tags) == ~w(grid_cnn grid_flattened linear)

    # Through the selected variant: kernels is a list of (int, int) tuples.
    assert %{kind: :list} = describe_at(schema, config, ~w(learner model obs_encoder kernels))

    assert %{kind: :tuple, items: [_, _]} =
             Schema.describe(
               schema,
               Schema.node_at(
                 schema,
                 put_in(config, ~w(learner model obs_encoder), %{
                   "obs_type" => "grid_cnn",
                   "kernels" => [[3, 3]]
                 }),
                 ~w(learner model obs_encoder kernels) ++ [0]
               ),
               [3, 3]
             )
  end

  test "environments dispatch on env_type to the registered model", %{schema: schema} do
    config = %{
      "environment" => %{"env_type" => "rust_vec", "env" => %{"env_type" => "rust_find_return"}}
    }

    assert %{kind: :environment, env_type: "rust_vec", node: node} =
             describe_at(schema, config, ["environment"])

    assert %{kind: :object} = Schema.describe(schema, node, config["environment"])
    assert %{kind: :integer} = describe_at(schema, config, ["environment", "num"])

    # rust_vec types its inner env as a union of the rust envs only.
    assert %{kind: :union, key: "env_type", tag: "rust_find_return", tags: rust_envs} =
             describe_at(schema, config, ["environment", "env"])

    assert "rust_snake" in rust_envs
    refute "snake" in rust_envs
    assert %{kind: :integer} = describe_at(schema, config, ["environment", "env", "num_agents"])

    # A plain vec wraps any registered env, dispatched on its own env_type.
    vec = %{"environment" => %{"env_type" => "vec", "env" => %{"env_type" => "snake"}}}

    assert %{kind: :environment, env_type: "snake"} =
             describe_at(schema, vec, ["environment", "env"])

    assert Schema.node_at(schema, config, ["environment", "nope"]) == nil
    assert "craftax" in Schema.env_types(schema)
  end

  test "new_value builds required structure and leaves required leaves empty", %{schema: schema} do
    config = Schema.new_value(schema, Schema.root_node(schema))

    # Required sections exist so they render; defaults come from the model.
    assert %{
             "learner" => %{"optimizer" => %{}, "model" => model, "trainer" => %{}},
             "environment" => %{}
           } = config

    refute Map.has_key?(config, "max_env_steps")
    # Optional sections with a default are left out: Pydantic fills them in.
    refute Map.has_key?(config, "logger")
    # A required union starts on its first variant, with the tag set.
    assert %{"obs_type" => _} = model["obs_encoder"]
  end

  test "switching env_type keeps the fields both types share", %{schema: schema} do
    old = %{"env_type" => "rust_vec", "num" => 64, "env" => %{"env_type" => "rust_snake"}}

    assert %{"env_type" => "vec", "num" => 64, "env" => %{"env_type" => "rust_snake"}} =
             Schema.switch_env_type(schema, old, "vec")

    assert Schema.switch_env_type(schema, old, "rust_find_return")
           |> Map.keys()
           |> Enum.sort()
           |> Enum.member?("num") == false
  end

  describe "coerce/4" do
    test "parses numbers, keeping text that doesn't parse", %{schema: schema} do
      int = Schema.node_at(schema, %{}, ["max_env_steps"])
      float = Schema.node_at(schema, %{}, ["learner", "optimizer", "learning_rate"])

      assert Schema.coerce(schema, int, "512") == 512
      assert Schema.coerce(schema, int, " 512 ") == 512
      assert Schema.coerce(schema, int, "5.5") == "5.5"
      assert Schema.coerce(schema, int, "") == :unset
      assert Schema.coerce(schema, float, "0.001") == 0.001
      assert Schema.coerce(schema, float, "1e-8") == 1.0e-8
      assert Schema.coerce(schema, float, "3") == 3.0
      assert Schema.coerce(schema, float, "abc") == "abc"
    end

    test "handles seed's int-or-random choice", %{schema: schema} do
      seed = Schema.node_at(schema, %{}, ["seed"])
      assert Schema.coerce(schema, seed, "42", 7) == 42
    end
  end
end
