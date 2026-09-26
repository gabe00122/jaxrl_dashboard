defmodule JaxrlDashboardWeb.ConfigLive.New do
  @moduledoc """
  The config builder. Starts from a config file, a run's config, or the
  schema's defaults (`?from=file:best.json`, `?from=run:NAME`), renders an
  editor generated from jaxrl's config schema, and checks the config against
  jaxrl's Pydantic models on every change. Valid configs can be queued as a
  run or saved as a new file in the jaxrl config directory.
  """
  use JaxrlDashboardWeb, :live_view

  import JaxrlDashboardWeb.ConfigForm, only: [object_fields: 1]

  alias JaxrlDashboard.{Configs, Runs}
  alias JaxrlDashboard.Configs.{Editor, Schema}
  alias JaxrlDashboard.Runs.Settings

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        New config
        <:subtitle>
          {if @source_label, do: "Based on #{@source_label}.", else: "Starting from jaxrl's defaults."} Checked against jaxrl's config models as you edit.
        </:subtitle>
        <:actions>
          <details id="start-from" class="dropdown dropdown-end">
            <summary class="btn btn-ghost btn-sm">
              <.icon name="hero-document-duplicate" class="size-4" /> Start from...
            </summary>
            <ul class="dropdown-content menu z-20 mt-1 max-h-96 w-64 flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
              <li>
                <.link patch={~p"/configs/new"} data-confirm={@dirty? && "Discard your changes?"}>
                  Defaults
                </.link>
              </li>
              <li class="menu-title">Config files</li>
              <li :for={file <- @config_files}>
                <.link
                  patch={~p"/configs/new?#{[from: "file:" <> file]}"}
                  data-confirm={@dirty? && "Discard your changes?"}
                  class="font-mono text-xs"
                >
                  {file}
                </.link>
              </li>
            </ul>
          </details>
        </:actions>
      </.header>

      <div
        :if={@schema_error}
        class="rounded-box border border-error/30 bg-error/10 px-4 py-3 text-sm text-error"
      >
        Couldn't load jaxrl's config schema: {@schema_error}
      </div>

      <div :if={@schema} class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem] lg:items-start">
        <.form for={%{}} id="config-form" phx-change="change" phx-submit="noop">
          <.object_fields
            schema={@schema}
            node={Schema.root_node(@schema)}
            value={@config}
            path={[]}
            errors={@error_map}
          />
        </.form>

        <aside class="space-y-4 lg:sticky lg:top-4">
          <section
            id="config-status"
            class={[
              "rounded-box border p-4 text-sm",
              @valid? && "border-success/40 bg-success/10",
              !@valid? && "border-error/30 bg-error/5"
            ]}
          >
            <p :if={@valid?} class="flex items-center gap-2 font-semibold">
              <.icon name="hero-check-circle" class="size-5 text-success" /> Valid config
            </p>
            <div :if={!@valid?}>
              <p class="flex items-center gap-2 font-semibold">
                <.icon name="hero-exclamation-circle" class="size-5 text-error" />
                {problem_count(@errors, @validation_error)}
              </p>
              <p :if={@validation_error} class="mt-2 text-error">{@validation_error}</p>
              <ul class="mt-2 max-h-64 space-y-1.5 overflow-y-auto">
                <li :for={error <- @errors} class="text-xs">
                  <span class="font-mono text-base-content/70">{format_path(error.path)}</span>
                  <span class="block text-error">{error.message}</span>
                </li>
              </ul>
            </div>
          </section>

          <.form
            for={@queue_form}
            id="queue-form"
            phx-submit="queue"
            class="space-y-2 rounded-box border border-base-300 bg-base-100 p-4"
          >
            <h2 class="text-sm font-semibold">Queue a run</h2>
            <.input field={@queue_form[:name]} type="text" placeholder="name (auto-generated)" />
            <.button class="btn btn-primary w-full" disabled={!@valid?}>
              <.icon name="hero-play" class="size-4" /> Queue run
            </.button>
          </.form>

          <.form
            for={@save_form}
            id="save-form"
            phx-submit="save"
            class="space-y-2 rounded-box border border-base-300 bg-base-100 p-4"
          >
            <h2 class="text-sm font-semibold">Save as a config file</h2>
            <p class="text-xs text-base-content/60">
              Adds a new file to jaxrl's config directory. Existing files are never overwritten.
            </p>
            <.input field={@save_form[:name]} type="text" placeholder="my_config" />
            <.button class="btn w-full" disabled={!@valid?}>
              <.icon name="hero-document-arrow-down" class="size-4" /> Save file
            </.button>
          </.form>

          <details class="rounded-box border border-base-300 bg-base-100">
            <summary class="cursor-pointer px-4 py-3 text-sm font-semibold">JSON</summary>
            <pre
              id="config-json"
              class="max-h-96 overflow-auto border-t border-base-300 p-4 font-mono text-xs"
            >{Jason.encode!(@config, pretty: true)}</pre>
          </details>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "New config",
        config_files: Settings.config_files(),
        queue_form: to_form(%{"name" => ""}, as: "run"),
        save_form: to_form(%{"name" => ""}, as: "file")
      )

    case Configs.schema() do
      {:ok, schema} -> {:ok, assign(socket, schema: schema, schema_error: nil)}
      {:error, reason} -> {:ok, assign(socket, schema: nil, schema_error: reason, config: %{})}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{schema: nil}} = socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    case Configs.load_source(params["from"], socket.assigns.schema) do
      {:ok, config, label} ->
        {:noreply,
         socket
         |> assign(base_config: config, base_label: label, source_label: label)
         |> assign_config(config)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't find #{params["from"]}. Starting from the defaults.")
         |> push_patch(to: ~p"/configs/new")}
    end
  end

  defp assign_config(socket, config) do
    {errors, validation_error} =
      case Configs.validate(config) do
        {:ok, errors} -> {errors, nil}
        {:error, reason} -> {[], "Couldn't check the config: #{reason}"}
      end

    dirty? = config != socket.assigns.base_config

    assign(socket,
      config: config,
      errors: errors,
      error_map: Enum.group_by(errors, & &1.path, & &1.message),
      validation_error: validation_error,
      valid?: errors == [] and validation_error == nil,
      dirty?: dirty?,
      source_label: source_label(socket.assigns.base_label, dirty?)
    )
  end

  defp source_label(nil, _dirty?), do: nil
  defp source_label(label, false), do: label
  defp source_label(label, true), do: "#{label} (edited)"

  @impl true
  def handle_event("change", %{"_target" => ["config" | target]} = params, socket) do
    case get_in(params, ["config" | target]) do
      raw when is_binary(raw) ->
        config = Editor.apply_input(socket.assigns.schema, socket.assigns.config, target, raw)
        {:noreply, assign_config(socket, config)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  def handle_event("add_item", %{"path" => path}, socket) do
    config = Editor.add_item(socket.assigns.schema, socket.assigns.config, Jason.decode!(path))
    {:noreply, assign_config(socket, config)}
  end

  def handle_event("remove", %{"path" => path}, socket) do
    {:noreply, assign_config(socket, Editor.remove(socket.assigns.config, Jason.decode!(path)))}
  end

  def handle_event("queue", %{"run" => %{"name" => name}}, socket) do
    attrs = %{
      "name" => blank_to_nil(name),
      "config" => socket.assigns.config,
      "config_source" => socket.assigns.source_label
    }

    case Runs.enqueue_config_run(socket.assigns.current_scope, attrs) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{run.name}")
         |> push_navigate(to: ~p"/runs/#{run.name}")}

      {:error, changeset} ->
        {:noreply, assign(socket, queue_form: to_form(changeset, as: "run"))}
    end
  end

  def handle_event("save", %{"file" => %{"name" => name}}, socket) do
    case Configs.save_file(String.trim(name), socket.assigns.config) do
      {:ok, file} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{file} to jaxrl's config directory")
         |> assign(config_files: Settings.config_files())
         |> push_patch(to: ~p"/configs/new?#{[from: "file:" <> file]}")}

      {:error, reason} ->
        form = to_form(%{"name" => name}, as: "file", errors: [name: {reason, []}])
        {:noreply, assign(socket, save_form: form)}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp problem_count(errors, validation_error) do
    case length(errors) do
      0 when validation_error != nil -> "Not checked"
      1 -> "1 problem"
      n -> "#{n} problems"
    end
  end

  defp format_path([]), do: "config"
  defp format_path(path), do: Enum.map_join(path, " › ", &to_string/1)
end
