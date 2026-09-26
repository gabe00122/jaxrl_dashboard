defmodule JaxrlDashboardWeb.ConfigForm do
  @moduledoc """
  Renders an editor for any node of the config schema (see
  `JaxrlDashboard.Configs.Schema`): plain values as compact fields in a grid,
  nested models, unions, environments and lists as bordered sections.

  Inputs are named after their path (`config[learner][model][num_layers]`) so
  the LiveView can apply each change with `JaxrlDashboard.Configs.Editor`.
  Structural buttons send `add_item` / `remove` with the JSON-encoded path.
  """
  use Phoenix.Component

  import JaxrlDashboardWeb.CoreComponents, only: [icon: 1]

  alias JaxrlDashboard.Configs.Schema
  alias Phoenix.LiveView.JS

  @compact_kinds [:integer, :number, :boolean, :string, :enum, :const, :choice, :tuple]

  @doc "The fields of an object node: compact values first, then sections."
  attr :schema, Schema, required: true
  attr :node, :any, required: true
  attr :value, :any, required: true
  attr :path, :list, required: true
  attr :errors, :map, required: true
  attr :skip, :list, default: [], doc: "keys shown elsewhere, like a union's tag"

  def object_fields(assigns) do
    %{properties: properties} = Schema.describe(assigns.schema, assigns.node, assigns.value)
    value = if is_map(assigns.value), do: assigns.value, else: %{}

    children =
      for {key, node, required} <- properties, key not in assigns.skip do
        child_value = Map.get(value, key)
        kind = Schema.describe(assigns.schema, node, child_value)

        %{
          key: key,
          node: node,
          value: child_value,
          required: required,
          path: assigns.path ++ [key],
          compact: compact?(assigns.schema, kind)
        }
      end

    known = for {key, _node, _required} <- properties, do: key

    unknown =
      value |> Map.keys() |> Enum.reject(&(&1 in known or &1 in assigns.skip)) |> Enum.sort()

    assigns =
      assign(assigns,
        compact: Enum.filter(children, & &1.compact),
        sections: Enum.reject(children, & &1.compact),
        unknown:
          for(key <- unknown, do: %{key: key, value: value[key], path: assigns.path ++ [key]})
      )

    ~H"""
    <div class="space-y-4">
      <div :if={@compact != []} class="grid gap-x-4 gap-y-3 sm:grid-cols-2 xl:grid-cols-3">
        <.field
          :for={child <- @compact}
          schema={@schema}
          node={child.node}
          value={child.value}
          path={child.path}
          label={child.key}
          required={child.required}
          errors={@errors}
        />
      </div>

      <.section
        :for={child <- @sections}
        schema={@schema}
        node={child.node}
        value={child.value}
        path={child.path}
        label={child.key}
        errors={@errors}
      />

      <div
        :for={field <- @unknown}
        id={dom_id(field.path)}
        class="flex flex-wrap items-center gap-2 rounded-box border border-warning/40 bg-warning/10 px-3 py-2 text-sm"
      >
        <.icon name="hero-exclamation-triangle-micro" class="size-4 text-warning" />
        <span class="font-mono">{field.key}</span>
        <span class="text-base-content/60">isn't a field of this model</span>
        <code class="max-w-64 truncate text-xs">{Jason.encode!(field.value)}</code>
        <button
          type="button"
          phx-click={JS.push("remove", value: %{path: Jason.encode!(field.path)})}
          class="btn btn-ghost btn-xs ml-auto"
        >
          Remove
        </button>
      </div>
    </div>
    """
  end

  defp compact?(schema, %{kind: :optional, node: inner}) do
    inner_kind = Schema.describe(schema, inner, nil)
    inner_kind.kind in @compact_kinds
  end

  defp compact?(_schema, %{kind: kind}), do: kind in @compact_kinds

  # A single value with its label, hint and errors.
  attr :schema, Schema, required: true
  attr :node, :any, required: true
  attr :value, :any, required: true
  attr :path, :list, required: true
  attr :label, :string, required: true
  attr :required, :boolean, default: false
  attr :errors, :map, required: true

  defp field(assigns) do
    kind = Schema.describe(assigns.schema, assigns.node, assigns.value)
    messages = Map.get(assigns.errors, assigns.path, [])

    assigns =
      assign(assigns,
        kind: kind,
        id: dom_id(assigns.path),
        messages: messages,
        hint: hint(kind, assigns.value, assigns.required)
      )

    ~H"""
    <div class="min-w-0 space-y-1" id={"#{@id}-field"}>
      <label for={@id} class="flex items-baseline gap-1 text-xs font-medium text-base-content/80">
        <span class="truncate font-mono" title={@kind.meta["description"] || @label}>{@label}</span>
        <span :if={@required} class="text-error" title="Required">*</span>
      </label>
      <.input_for
        kind={@kind}
        schema={@schema}
        value={@value}
        path={@path}
        id={@id}
        invalid={@messages != []}
      />
      <p :if={@hint} class="text-xs text-base-content/50">{@hint}</p>
      <p :for={message <- @messages} class="text-xs text-error">{message}</p>
    </div>
    """
  end

  defp hint(%{meta: %{"default" => default}}, nil, false) when default != nil,
    do: "default: #{format_value(default)}"

  defp hint(%{meta: %{"description" => description}}, _value, _required), do: description
  defp hint(_kind, _value, _required), do: nil

  attr :kind, :map, required: true
  attr :schema, Schema, required: true
  attr :value, :any, required: true
  attr :path, :list, required: true
  attr :id, :string, required: true
  attr :invalid, :boolean, default: false

  defp input_for(%{kind: %{kind: :optional, node: inner}} = assigns) do
    assigns = assign(assigns, kind: Schema.describe(assigns.schema, inner, assigns.value))

    ~H"<.input_for kind={@kind} schema={@schema} value={@value} path={@path} id={@id} invalid={@invalid} />"
  end

  defp input_for(%{kind: %{kind: :boolean}} = assigns) do
    assigns =
      assign(assigns,
        checked:
          if(is_nil(assigns.value), do: assigns.kind.meta["default"] == true, else: assigns.value)
      )

    ~H"""
    <input type="hidden" name={input_name(@path)} value="false" />
    <input
      type="checkbox"
      id={@id}
      name={input_name(@path)}
      value="true"
      checked={@checked}
      class="toggle toggle-sm"
    />
    """
  end

  defp input_for(%{kind: %{kind: :enum}} = assigns) do
    ~H"""
    <select
      id={@id}
      name={input_name(@path)}
      class={["select select-sm w-full font-mono", @invalid && "select-error"]}
    >
      <option value="" selected={is_nil(@value)}>
        {if default = @kind.meta["default"], do: "default (#{default})", else: "Choose..."}
      </option>
      <option :for={option <- @kind.values} value={option} selected={@value == option}>
        {option}
      </option>
    </select>
    """
  end

  defp input_for(%{kind: %{kind: :const}} = assigns) do
    ~H"""
    <div id={@id} class="flex h-8 items-center">
      <span class="rounded-field bg-base-200 px-2 py-0.5 font-mono text-sm">
        {format_value(@kind.value)}
      </span>
    </div>
    """
  end

  defp input_for(%{kind: %{kind: :choice}} = assigns) do
    %{variants: variants, index: index} = assigns.kind
    selected = Enum.at(variants, index)

    assigns =
      assign(assigns,
        options:
          variants
          |> Enum.with_index()
          |> Enum.map(fn {node, i} -> {i, variant_label(assigns.schema, node)} end),
        index: index,
        selected: Schema.describe(assigns.schema, selected, assigns.value)
      )

    ~H"""
    <div class="flex gap-2">
      <select
        id={@id}
        name={input_name(@path ++ ["__choice"])}
        class="select select-sm w-32 shrink-0 font-mono"
      >
        <option :for={{i, label} <- @options} value={i} selected={i == @index}>{label}</option>
      </select>
      <.input_for
        :if={@selected.kind not in [:const]}
        kind={@selected}
        schema={@schema}
        value={@value}
        path={@path}
        id={"#{@id}-value"}
        invalid={@invalid}
      />
    </div>
    """
  end

  defp input_for(%{kind: %{kind: :tuple, items: items}} = assigns) do
    assigns = assign(assigns, items: Enum.with_index(items))

    ~H"""
    <div id={@id} class="flex gap-1">
      <.input_for
        :for={{node, i} <- @items}
        kind={Schema.describe(@schema, node, list_item(@value, i))}
        schema={@schema}
        value={list_item(@value, i)}
        path={@path ++ [i]}
        id={"#{@id}-#{i}"}
        invalid={@invalid}
      />
    </div>
    """
  end

  defp input_for(assigns) do
    assigns =
      assign(assigns,
        inputmode:
          case assigns.kind.kind do
            :integer -> "numeric"
            :number -> "decimal"
            _ -> "text"
          end,
        placeholder: if(default = assigns.kind.meta["default"], do: format_value(default))
      )

    ~H"""
    <input
      type="text"
      id={@id}
      name={input_name(@path)}
      value={format_value(@value)}
      inputmode={@inputmode}
      placeholder={@placeholder}
      autocomplete="off"
      spellcheck="false"
      phx-debounce="300"
      class={["input input-sm w-full min-w-0 font-mono", @invalid && "input-error"]}
    />
    """
  end

  defp variant_label(schema, node) do
    case Schema.describe(schema, node, nil) do
      %{kind: :const, value: value} -> format_value(value)
      %{kind: kind} -> Atom.to_string(kind)
    end
  end

  # A nested model, union, environment or list, in a bordered box.
  attr :schema, Schema, required: true
  attr :node, :any, required: true
  attr :value, :any, required: true
  attr :path, :list, required: true
  attr :label, :string, required: true
  attr :errors, :map, required: true

  defp section(assigns) do
    kind = Schema.describe(assigns.schema, assigns.node, assigns.value)

    assigns =
      assign(assigns,
        kind: kind,
        id: dom_id(assigns.path),
        messages: Map.get(assigns.errors, assigns.path, [])
      )

    ~H"""
    <fieldset id={@id} class="min-w-0 rounded-box border border-base-300 bg-base-100 px-4 pt-2 pb-4">
      <legend class="px-1 font-mono text-sm font-semibold">{@label}</legend>
      <p :if={@kind.meta["description"]} class="mb-2 text-xs text-base-content/60">
        {@kind.meta["description"]}
      </p>
      <p :for={message <- @messages} class="mb-2 text-xs text-error">{message}</p>
      <.section_body
        kind={@kind}
        schema={@schema}
        value={@value}
        path={@path}
        id={@id}
        errors={@errors}
      />
    </fieldset>
    """
  end

  attr :kind, :map, required: true
  attr :schema, Schema, required: true
  attr :value, :any, required: true
  attr :path, :list, required: true
  attr :id, :string, required: true
  attr :errors, :map, required: true
  attr :optional, :boolean, default: false

  defp section_body(%{kind: %{kind: :object}} = assigns) do
    ~H"""
    <.object_fields schema={@schema} node={@kind.node} value={@value} path={@path} errors={@errors} />
    """
  end

  defp section_body(%{kind: %{kind: :optional, node: inner}} = assigns) do
    inner_kind = Schema.describe(assigns.schema, inner, assigns.value)

    case inner_kind do
      %{kind: :union} ->
        section_body(assign(assigns, kind: inner_kind, optional: true))

      _ ->
        assigns = assign(assigns, inner: inner, inner_kind: inner_kind)

        ~H"""
        <label class="mb-3 flex items-center gap-2 text-sm">
          <select name={input_name(@path ++ ["__variant"])} class="select select-sm w-40">
            <option value="" selected={is_nil(@value)}>none</option>
            <option value="set" selected={!is_nil(@value)}>set</option>
          </select>
        </label>
        <.section_body
          :if={!is_nil(@value)}
          kind={@inner_kind}
          schema={@schema}
          value={@value}
          path={@path}
          id={@id}
          errors={@errors}
        />
        """
    end
  end

  defp section_body(%{kind: %{kind: :union}} = assigns) do
    ~H"""
    <div class="mb-3 flex items-center gap-2">
      <label for={"#{@id}-variant"} class="font-mono text-xs text-base-content/70">
        {@kind.key}
      </label>
      <select
        id={"#{@id}-variant"}
        name={input_name(@path ++ ["__variant"])}
        class="select select-sm w-48 font-mono"
      >
        <option :if={@optional} value="" selected={is_nil(@value)}>none</option>
        <option :if={!@optional and is_nil(@kind.node)} value="" selected>Choose...</option>
        <option :for={tag <- @kind.tags} value={tag} selected={@kind.tag == tag}>{tag}</option>
      </select>
    </div>
    <.object_fields
      :if={@kind.node}
      schema={@schema}
      node={@kind.node}
      value={@value}
      path={@path}
      errors={@errors}
      skip={[@kind.key]}
    />
    """
  end

  defp section_body(%{kind: %{kind: :environment}} = assigns) do
    assigns = assign(assigns, env_types: Schema.env_types(assigns.schema))

    ~H"""
    <div class="mb-3 flex items-center gap-2">
      <label for={"#{@id}-env-type"} class="font-mono text-xs text-base-content/70">env_type</label>
      <select
        id={"#{@id}-env-type"}
        name={input_name(@path ++ ["__env_type"])}
        class={["select select-sm w-56 font-mono", is_nil(@kind.node) && "select-error"]}
      >
        <option :if={is_nil(@kind.node)} value="" selected>
          {if @kind.env_type, do: "#{@kind.env_type} (unknown)", else: "Choose..."}
        </option>
        <option :for={type <- @env_types} value={type} selected={@kind.env_type == type}>
          {type}
        </option>
      </select>
    </div>
    <p :for={message <- Map.get(@errors, @path ++ ["env_type"], [])} class="mb-2 text-xs text-error">
      {message}
    </p>
    <.object_fields
      :if={@kind.node}
      schema={@schema}
      node={@kind.node}
      value={@value}
      path={@path}
      errors={@errors}
      skip={["env_type"]}
    />
    """
  end

  defp section_body(%{kind: %{kind: :list, item: item}} = assigns) do
    items = if is_list(assigns.value), do: assigns.value, else: []
    item_kind = Schema.describe(assigns.schema, item, nil)

    assigns =
      assign(assigns,
        items: Enum.with_index(items),
        item: item,
        compact: compact?(assigns.schema, item_kind)
      )

    ~H"""
    <div class="space-y-2">
      <div :for={{item_value, i} <- @items} class="flex items-start gap-2">
        <span class="w-6 pt-1.5 text-right font-mono text-xs text-base-content/50">{i}</span>
        <div class="min-w-0 flex-1">
          <%= if @compact do %>
            <.input_for
              kind={Schema.describe(@schema, @item, item_value)}
              schema={@schema}
              value={item_value}
              path={@path ++ [i]}
              id={"#{@id}-#{i}"}
              invalid={Map.has_key?(@errors, @path ++ [i])}
            />
            <p :for={message <- Map.get(@errors, @path ++ [i], [])} class="mt-1 text-xs text-error">
              {message}
            </p>
          <% else %>
            <.section
              schema={@schema}
              node={@item}
              value={item_value}
              path={@path ++ [i]}
              label={"#{List.last(@path)}[#{i}]"}
              errors={@errors}
            />
          <% end %>
        </div>
        <button
          type="button"
          phx-click={JS.push("remove", value: %{path: Jason.encode!(@path ++ [i])})}
          class="btn btn-ghost btn-xs btn-square mt-1 text-base-content/60"
          aria-label={"Remove item #{i}"}
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
      <button
        type="button"
        phx-click={JS.push("add_item", value: %{path: Jason.encode!(@path)})}
        class="btn btn-ghost btn-xs"
      >
        <.icon name="hero-plus-micro" class="size-4" /> Add
      </button>
    </div>
    """
  end

  defp section_body(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">
      This field can't be edited here. Current value:
      <code class="font-mono text-xs">{Jason.encode!(@value)}</code>
    </p>
    """
  end

  defp list_item(value, i) when is_list(value), do: Enum.at(value, i)
  defp list_item(_value, _i), do: nil

  @doc "The form input name for a path: `config[learner][model][num_layers]`."
  def input_name(path), do: "config" <> Enum.map_join(path, &"[#{&1}]")

  defp dom_id([]), do: "cfg"

  defp dom_id(path),
    do: "cfg-" <> Enum.map_join(path, "-", &String.replace(to_string(&1), ~r/[^A-Za-z0-9_]/, "_"))

  @doc "How a value is shown in an input."
  def format_value(nil), do: ""
  # Shortest round-trip form, except whole numbers like 10000.0, which that
  # would write as "1.0e4".
  def format_value(value) when is_float(value) and value == trunc(value) and abs(value) < 1.0e15,
    do: "#{trunc(value)}.0"

  def format_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  def format_value(value) when is_binary(value), do: value
  def format_value(value), do: Jason.encode!(value)
end
