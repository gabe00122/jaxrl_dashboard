defmodule JaxrlDashboard.Configs.Schema do
  @moduledoc """
  Reads the JSON Schema of a project's `Config` (exported from its Pydantic
  models) to drive the config builder: what editor each value needs, what a
  newly added value looks like, and how form input turns into typed JSON.

  A node is `{schema, root}`, where `root` is the document the node's `$ref`s
  resolve against. In jaxrl, the `environment` field is open in the Config
  schema (`EnvironmentConfig` accepts any keys), so it's dispatched on
  `env_type` to the schema of the model that environment registered with
  mapox, the same way `EnvironmentFactory` validates it. Projects without
  such a field (llm_rl) have no `environments`.
  """

  defstruct [:config, :environments]

  @type t :: %__MODULE__{config: map(), environments: %{String.t() => map()}}
  @type schema_node :: {map(), map()}

  def new(%{"config" => config, "environments" => environments}),
    do: %__MODULE__{config: config, environments: environments}

  def root_node(%__MODULE__{config: config}), do: {config, config}

  def env_types(%__MODULE__{environments: environments}),
    do: environments |> Map.keys() |> Enum.sort()

  @doc """
  Describes the editor a node needs, given its current value (unions and
  environments depend on the value's tag).
  """
  def describe(%__MODULE__{} = schema, node, value) do
    case resolve(node) do
      :environment ->
        env_type = value_at(value, "env_type")
        env_node = env_type && env_node(schema, env_type)
        %{kind: :environment, env_type: env_type, node: env_node, meta: %{}}

      {%{"oneOf" => variants, "discriminator" => %{"propertyName" => key, "mapping" => mapping}} =
           s, root} ->
        tags = Enum.map(variants, &tag_of(&1, mapping))
        tag = value_at(value, key)
        selected = if tag in tags, do: variant_node(mapping, tag, root)
        %{kind: :union, key: key, tags: tags, tag: tag, node: selected, meta: meta(s)}

      {%{"anyOf" => options} = s, root} ->
        case Enum.split_with(options, &(&1 == %{"type" => "null"})) do
          {[_null], [inner]} ->
            %{kind: :optional, node: {inner, root}, meta: meta(s)}

          {_nulls, variants} ->
            nodes = Enum.map(variants, &{&1, root})

            %{
              kind: :choice,
              variants: nodes,
              index: choice_index(schema, nodes, value),
              meta: meta(s)
            }
        end

      {%{"properties" => properties} = s, root} ->
        order = Map.get(s, "x-order", properties |> Map.keys() |> Enum.sort())
        required = Map.get(s, "required", [])

        %{
          kind: :object,
          node: {s, root},
          properties: for(key <- order, do: {key, {properties[key], root}, key in required}),
          open?: Map.get(s, "additionalProperties", false) != false,
          meta: meta(s)
        }

      {%{"type" => "array", "prefixItems" => items} = s, root} ->
        %{kind: :tuple, items: Enum.map(items, &{&1, root}), meta: meta(s)}

      {%{"type" => "array"} = s, root} ->
        %{kind: :list, item: {Map.get(s, "items", %{}), root}, meta: meta(s)}

      {%{"enum" => values} = s, _root} ->
        %{kind: :enum, values: values, meta: meta(s)}

      {%{"const" => value} = s, _root} ->
        %{kind: :const, value: value, meta: meta(s)}

      {%{"type" => type} = s, _root} when type in ~w(integer number boolean string) ->
        %{kind: String.to_atom(type), meta: meta(s)}

      {s, _root} ->
        %{kind: :unknown, meta: meta(s)}
    end
  end

  # Title, description and default, for labels and placeholders.
  defp meta(s), do: Map.take(s, ["title", "description", "default"])

  @doc "The node for a registered environment type, or nil."
  def env_node(%__MODULE__{environments: environments}, env_type) do
    case environments do
      %{^env_type => env_schema} -> {env_schema, env_schema}
      _ -> nil
    end
  end

  @doc """
  Follows `$ref`s. Keys next to a `$ref` (like `default`) are kept.
  Returns `:environment` for the open environment config.
  """
  def resolve({%{"$ref" => "#/$defs/" <> name} = s, root}) do
    if name == "EnvironmentConfig" do
      :environment
    else
      resolve({Map.merge(root["$defs"][name], Map.delete(s, "$ref")), root})
    end
  end

  def resolve(node), do: node

  defp tag_of(%{"$ref" => ref}, mapping) do
    Enum.find_value(mapping, fn {tag, target} -> if target == ref, do: tag end)
  end

  defp variant_node(mapping, tag, root), do: {%{"$ref" => mapping[tag]}, root}

  defp value_at(value, key) when is_map(value), do: Map.get(value, key)
  defp value_at(_value, _key), do: nil

  # Which variant of an anyOf (like `int | "random"`) the value is.
  defp choice_index(schema, nodes, value) do
    Enum.find_index(nodes, &matches?(schema, &1, value)) || 0
  end

  defp matches?(schema, node, value) do
    case describe(schema, node, value) do
      %{kind: :const, value: const} -> value == const
      %{kind: :enum, values: values} -> value in values
      %{kind: :integer} -> is_integer(value)
      %{kind: :number} -> is_number(value)
      %{kind: :boolean} -> is_boolean(value)
      %{kind: :string} -> is_binary(value)
      %{kind: kind} when kind in [:object, :union, :environment] -> is_map(value)
      %{kind: kind} when kind in [:list, :tuple] -> is_list(value)
      _ -> false
    end
  end

  @doc """
  A fresh value for a node: its default if it has one, otherwise the smallest
  structure worth editing (required fields only, first union variant). Leaves
  that need a value are left out, so validation points at them.
  """
  def new_value(%__MODULE__{} = schema, node) do
    case resolve(node) do
      :environment ->
        %{}

      {%{"default" => default}, _root} when default != nil ->
        default

      _ ->
        case describe(schema, node, nil) do
          %{kind: :union, tags: [tag | _]} ->
            switch_variant(schema, node, tag)

          %{kind: :object, properties: properties} ->
            for {key, prop, true} <- properties,
                value = new_value(schema, prop),
                value != nil,
                into: %{},
                do: {key, value}

          %{kind: :choice, variants: [first | _]} ->
            new_value(schema, first)

          %{kind: :tuple, items: items} ->
            Enum.map(items, &new_value(schema, &1))

          %{kind: :list} ->
            []

          %{kind: :const, value: value} ->
            value

          _ ->
            nil
        end
    end
  end

  @doc """
  A new environment config of the given type. Fields the old one shares with
  the new type are kept, so switching `vec` to `rust_vec` keeps `num`.
  """
  def switch_env_type(%__MODULE__{} = schema, old_value, env_type) do
    case env_node(schema, env_type) do
      nil ->
        %{"env_type" => env_type}

      node ->
        %{properties: properties} = describe(schema, node, nil)
        known = for {key, _node, _required} <- properties, do: key
        kept = if is_map(old_value), do: Map.take(old_value, known), else: %{}

        schema
        |> new_value(node)
        |> Map.merge(kept)
        |> Map.put("env_type", env_type)
    end
  end

  @doc "A new value for a union switched to `tag`, with the tag set."
  def switch_variant(%__MODULE__{} = schema, node, tag) do
    %{key: key} = describe(schema, node, nil)
    variant = describe(schema, node, %{key => tag}).node
    schema |> new_value(variant) |> Map.put(key, tag)
  end

  @doc """
  The node at `path` within `config`, or nil if the path leaves the schema
  (for example a key the model doesn't have).
  """
  def node_at(%__MODULE__{} = schema, config, path) do
    do_node_at(schema, root_node(schema), config, path)
  end

  defp do_node_at(_schema, node, _value, []), do: node

  defp do_node_at(schema, node, value, [key | rest] = path) do
    case describe(schema, node, value) do
      %{kind: :object, properties: properties} ->
        case List.keyfind(properties, key, 0) do
          {^key, child, _required} -> do_node_at(schema, child, value_at(value, key), rest)
          nil -> nil
        end

      %{kind: :union, node: nil} ->
        nil

      %{kind: kind, node: inner} when kind in [:union, :optional] ->
        do_node_at(schema, inner, value, path)

      %{kind: :environment, node: nil} ->
        nil

      %{kind: :environment, node: env} ->
        do_node_at(schema, env, value, path)

      %{kind: :choice, variants: variants, index: index} ->
        do_node_at(schema, Enum.at(variants, index), value, path)

      %{kind: :list, item: item} when is_integer(key) ->
        do_node_at(schema, item, list_at(value, key), rest)

      %{kind: :tuple, items: items} when is_integer(key) ->
        case Enum.at(items, key) do
          nil -> nil
          item -> do_node_at(schema, item, list_at(value, key), rest)
        end

      _ ->
        nil
    end
  end

  defp list_at(value, index) when is_list(value), do: Enum.at(value, index)
  defp list_at(_value, _index), do: nil

  @doc """
  Turns a form input's string into a value for the node. Returns `:unset`
  for an emptied field (the key is removed, so the model's default applies).
  Text that doesn't parse is kept as-is so validation can point at it.
  """
  def coerce(%__MODULE__{} = schema, node, raw, current \\ nil) do
    case describe(schema, node, current) do
      %{kind: :optional, node: inner} -> coerce(schema, inner, raw, current)
      %{kind: :choice, variants: variants, index: i} -> coerce(schema, Enum.at(variants, i), raw)
      %{kind: :boolean} -> raw == "true"
      %{kind: :const, value: value} -> value
      _kind when raw == "" -> :unset
      %{kind: :integer} -> parse(raw, &Integer.parse/1)
      %{kind: :number} -> parse(raw, &parse_number/1)
      %{kind: :enum, values: values} -> Enum.find(values, raw, &(to_string(&1) == raw))
      _ -> raw
    end
  end

  defp parse(raw, parser) do
    case parser.(String.trim(raw)) do
      {value, ""} -> value
      _ -> raw
    end
  end

  # Float.parse doesn't take "1e-8"; jaxrl configs use that form.
  defp parse_number(text) do
    normalized = Regex.replace(~r/^(-?\d+)([eE])/, text, "\\1.0\\2")

    case Float.parse(normalized) do
      {value, ""} -> {value, ""}
      _ -> :error
    end
  end
end
