defmodule JaxrlDashboard.Configs.Editor do
  @moduledoc """
  Edits a config (plain JSON-shaped maps and lists) one change at a time, as
  the builder form reports them. Paths are lists of map keys and list indices.

  Form inputs are named after their path (`config[learner][model][num_layers]`),
  so LiveView's `_target` says which one changed. A few inputs control
  structure rather than a value; their names end in a control segment:

    * `__variant` - which variant of a union (or "" for none on an optional)
    * `__choice` - which option of an `anyOf`, like `seed: int | "random"`
    * `__env_type` - which registered environment an environment config is
  """

  alias JaxrlDashboard.Configs.Schema

  @controls ~w(__variant __choice __env_type)

  @doc """
  Applies a form change. `target` is the input's name as a list of strings
  (from `_target`, without the leading "config"), `raw` its string value.
  """
  def apply_input(%Schema{} = schema, config, target, raw) do
    {path, control} = parse_target(config, target)
    node = Schema.node_at(schema, config, path)
    current = get(config, path)

    value =
      cond do
        node == nil -> :ignore
        control == nil -> Schema.coerce(schema, node, raw, current)
        true -> control_value(schema, node, control, raw, current)
      end

    if value == :ignore, do: config, else: put(config, path, value)
  end

  defp control_value(schema, node, "__variant", raw, _current) do
    case Schema.describe(schema, node, nil) do
      _any when raw == "" -> :unset
      %{kind: :union} -> Schema.switch_variant(schema, node, raw)
      %{kind: :optional, node: inner} -> optional_value(schema, inner, raw)
    end
  end

  defp control_value(schema, node, "__choice", raw, _current) do
    %{variants: variants} = Schema.describe(schema, node, nil)
    Schema.new_value(schema, Enum.at(variants, String.to_integer(raw)))
  end

  defp control_value(_schema, _node, "__env_type", "", _current), do: %{}

  defp control_value(schema, _node, "__env_type", raw, current),
    do: Schema.switch_env_type(schema, current, raw)

  defp optional_value(schema, inner, raw) do
    case Schema.describe(schema, inner, nil) do
      %{kind: :union} -> Schema.switch_variant(schema, inner, raw)
      _ -> Schema.new_value(schema, inner)
    end
  end

  # String segments from the form become integers where the config has a list.
  defp parse_target(config, target) do
    {control, keys} =
      case List.last(target) do
        last when last in @controls -> {last, Enum.drop(target, -1)}
        _ -> {nil, target}
      end

    {path, _value} =
      Enum.map_reduce(keys, config, fn key, value ->
        if is_list(value) do
          index = String.to_integer(key)
          {index, Enum.at(value, index)}
        else
          {key, get(value, [key])}
        end
      end)

    {path, control}
  end

  @doc "Appends a new item to the list at `path`."
  def add_item(%Schema{} = schema, config, path) do
    case Schema.node_at(schema, config, path) do
      nil ->
        config

      node ->
        %{kind: :list, item: item} = Schema.describe(schema, node, get(config, path))
        put(config, path, List.wrap(get(config, path)) ++ [Schema.new_value(schema, item)])
    end
  end

  @doc "Removes the list item or map key at `path`."
  def remove(config, path) do
    {parent_path, [last]} = Enum.split(path, -1)

    case get(config, parent_path) do
      list when is_list(list) -> put(config, parent_path, List.delete_at(list, last))
      map when is_map(map) -> put(config, parent_path, Map.delete(map, last))
      _ -> config
    end
  end

  @doc "The value at `path`, or nil."
  def get(value, []), do: value
  def get(map, [key | rest]) when is_map(map), do: get(Map.get(map, key), rest)

  def get(list, [index | rest]) when is_list(list) and is_integer(index),
    do: get(Enum.at(list, index), rest)

  def get(_value, _path), do: nil

  @doc """
  Sets the value at `path`, creating maps along the way. `:unset` removes a
  map key (list items become nil instead, keeping positions).
  """
  def put(_value, [], new), do: if(new == :unset, do: nil, else: new)

  def put(list, [index | rest], new) when is_list(list) and is_integer(index) do
    list =
      if index >= length(list),
        do: list ++ List.duplicate(nil, index - length(list) + 1),
        else: list

    List.replace_at(list, index, put(Enum.at(list, index), rest, new))
  end

  def put(map, [key], :unset) when is_map(map), do: Map.delete(map, key)

  def put(map, [key | rest], new) do
    map = if is_map(map), do: map, else: %{}
    Map.put(map, key, put(Map.get(map, key), rest, new))
  end
end
