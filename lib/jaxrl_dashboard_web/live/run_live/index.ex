defmodule JaxrlDashboardWeb.RunLive.Index do
  use JaxrlDashboardWeb, :live_view

  import JaxrlDashboardWeb.RunComponents

  alias JaxrlDashboard.{Projects, Runs}
  alias JaxrlDashboard.Projects.Project

  @max_compared 8

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:runs}>
      <.header>
        Training runs
        <:subtitle>Every project shares the GPU: runs start one at a time, oldest first.</:subtitle>
        <:actions>
          <.link
            navigate={~p"/configs/new?#{[project: @form[:project].value]}"}
            class="btn btn-sm"
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" /> Build a config
          </.link>
        </:actions>
      </.header>

      <.form
        for={@form}
        id="enqueue-form"
        phx-change="validate"
        phx-submit="enqueue"
        class="grid gap-x-4 rounded-box border border-base-300 bg-base-200/50 p-4 sm:grid-cols-[9rem_1fr_1fr_auto] sm:items-start"
      >
        <.input
          field={@form[:project]}
          type="select"
          label="Project"
          options={Enum.map(@projects, &{&1.label, &1.id})}
        />
        <.input
          field={@form[:config_source]}
          type="select"
          label="Config"
          prompt="Choose a config file"
          options={@config_files}
        />
        <.input field={@form[:name]} type="text" label="Name" placeholder="auto-generated" />
        <.button class="btn btn-primary sm:mt-6" phx-disable-with="Queueing...">
          <.icon name="hero-play" class="size-4" /> Queue run
        </.button>
      </.form>

      <nav
        id="project-filter"
        class="-mx-4 flex items-center gap-1 overflow-x-auto px-4 sm:mx-0 sm:flex-wrap sm:px-0"
        aria-label="Filter by project"
      >
        <.link
          :for={{id, label} <- [{nil, "All projects"} | Enum.map(@projects, &{&1.id, &1.label})]}
          patch={if id, do: ~p"/?#{[project: id]}", else: ~p"/"}
          id={"filter-#{id || "all"}"}
          aria-current={@filter == id && "page"}
          class={[
            "inline-flex shrink-0 items-center gap-1.5 rounded-full px-3 py-1 text-sm transition-colors",
            if(@filter == id,
              do: "bg-base-content text-base-100",
              else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          {label}
          <span class={[
            "text-xs tabular-nums",
            if(@filter == id, do: "text-base-100/70", else: "text-base-content/50")
          ]}>
            {if id, do: Map.get(@counts, id, 0), else: @counts |> Map.values() |> Enum.sum()}
          </span>
        </.link>
      </nav>

      <.table
        id="runs"
        rows={@streams.runs}
        row_click={fn {_id, run} -> JS.navigate(~p"/runs/#{run.name}") end}
      >
        <:col :let={{_id, run}} label="" class="max-md:align-top">
          <%!-- Its own phx-click, so ticking a box doesn't open the run. --%>
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            checked={run.name in @selected}
            phx-click="toggle_selected"
            phx-value-name={run.name}
            aria-label={"Select #{run.name} to compare"}
          />
        </:col>
        <:col :let={{_id, run}} label="Name" class="max-md:w-full">
          <span class="font-mono text-sm break-words">{run.name}</span>
          <%!-- Below md the badge columns are hidden, so they show here. --%>
          <span class="mt-1.5 flex flex-wrap items-center gap-1.5 md:hidden">
            <.status_badge run={run} />
            <.project_badge project={run.project} />
            <span class="text-xs text-base-content/60">
              <.local_time id={"run-#{run.id}-queued-compact"} at={run.inserted_at} />
            </span>
          </span>
        </:col>
        <:col :let={{_id, run}} label="Project" class="max-md:hidden">
          <.project_badge project={run.project} />
        </:col>
        <:col :let={{_id, run}} label="Status" class="max-md:hidden">
          <.status_badge run={run} />
        </:col>
        <:col :let={{_id, run}} label="Config" class="max-lg:hidden">
          <span class="text-sm text-base-content/70">{run.config_source}</span>
        </:col>
        <:col :let={{_id, run}} label="Queued" class="whitespace-nowrap max-md:hidden">
          <.local_time id={"run-#{run.id}-queued"} at={run.inserted_at} />
        </:col>
        <:col :let={{_id, run}} label="Duration" class="whitespace-nowrap max-md:align-top">
          <.duration id={"run-#{run.id}-duration"} run={run} />
        </:col>
        <:col :let={{_id, run}} label="By" class="max-lg:hidden">
          <span class="text-sm">{run.user && run.user.username}</span>
        </:col>
        <:action :let={{_id, run}}>
          <.link
            :if={run.status in [:queued, :running] and is_nil(run.cancel_requested_at)}
            phx-click={JS.push("cancel", value: %{id: run.id})}
            data-confirm={"Cancel #{run.name}?"}
            class="text-sm text-error hover:underline"
          >
            Cancel
          </.link>
        </:action>
      </.table>

      <%!-- Sticks to the bottom of the screen while picking runs further down. --%>
      <div
        :if={@selected != []}
        id="compare-bar"
        class="sticky bottom-4 z-20 mx-auto flex w-fit items-center gap-1 rounded-full border border-base-300 bg-base-100/90 py-1 pr-1 pl-4 text-sm shadow-lg backdrop-blur-md"
      >
        <span class="mr-2 tabular-nums">{length(@selected)} selected</span>
        <button type="button" phx-click="clear_selection" class="btn btn-ghost btn-sm rounded-full">
          Clear
        </button>
        <.link
          navigate={~p"/compare?#{[runs: Enum.join(@selected, ",")]}"}
          class="btn btn-primary btn-sm rounded-full"
        >
          <.icon name="hero-chart-bar-square-micro" class="size-4" /> Compare
        </.link>
      </div>

      <p :if={@empty?} id="runs-empty" class="py-10 text-center text-base-content/60">
        {if @filter, do: "No #{project_label(@filter)} runs yet.", else: "No runs yet."} Pick a config above to queue one.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     assign(socket,
       page_title: "Runs",
       projects: Projects.list(),
       counts: Runs.count_runs_by_project(),
       filter: nil,
       selected: []
     )
     |> assign_form(Runs.change_run(%{"project" => Projects.default().id}))}
  end

  # `?project=ID` shows only that project's runs, and queues in it by default.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = if Projects.get(params["project"]), do: params["project"]
    runs = Runs.list_runs(project: filter)

    socket =
      socket
      |> assign(filter: filter, empty?: runs == [])
      |> stream(:runs, runs, reset: true)

    # Following a project's tab makes it the one to queue in, unless the
    # form's already been filled in for another.
    socket =
      if filter && blank?(socket.assigns.form[:config_source].value),
        do: assign_form(socket, Runs.change_run(%{"project" => filter})),
        else: socket

    {:noreply, socket}
  end

  defp assign_form(socket, changeset, action \\ nil) do
    project =
      Projects.get(Ecto.Changeset.get_field(changeset, :project)) || Projects.default()

    assign(socket,
      form: to_form(changeset, action: action),
      config_files: Project.config_files(project)
    )
  end

  defp blank?(value), do: value in [nil, ""]

  defp project_label(id), do: Projects.get!(id).label

  @impl true
  # A different project has different config files: the chosen one is dropped.
  def handle_event("validate", %{"_target" => ["run", "project"], "run" => params}, socket) do
    {:noreply, assign_form(socket, Runs.change_run(Map.delete(params, "config_source")))}
  end

  def handle_event("validate", %{"run" => params}, socket) do
    {:noreply, assign_form(socket, Runs.change_run(params), :validate)}
  end

  def handle_event("enqueue", %{"run" => params}, socket) do
    case Runs.enqueue_run(socket.assigns.current_scope, params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{run.name}")
         |> assign_form(Runs.change_run(%{"project" => run.project}))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # Selection order is kept: it decides the runs' colors on the compare page.
  def handle_event("toggle_selected", %{"name" => name}, socket) do
    selected = socket.assigns.selected

    cond do
      name in selected ->
        {:noreply, reselect(socket, List.delete(selected, name), [name])}

      length(selected) >= @max_compared ->
        {:noreply,
         socket
         |> put_flash(:error, "You can compare up to #{@max_compared} runs at a time.")
         |> reselect(selected, [name])}

      true ->
        {:noreply, reselect(socket, selected ++ [name], [name])}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, reselect(socket, [], socket.assigns.selected)}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Runs.cancel_run(Runs.get_run!(id)) do
      {:ok, _run} ->
        {:noreply, socket}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "That run already finished.")}
    end
  end

  # Rows are stream items, so the changed ones are re-inserted to re-render
  # their checkboxes.
  defp reselect(socket, selected, changed_names) do
    socket = assign(socket, selected: selected)

    Enum.reduce(Runs.get_runs_by_names(changed_names), socket, fn run, socket ->
      stream_insert(socket, :runs, run)
    end)
  end

  @impl true
  def handle_info({:run_created, run}, socket) do
    socket = update(socket, :counts, &Map.update(&1, run.project, 1, fn n -> n + 1 end))

    if socket.assigns.filter in [nil, run.project] do
      {:noreply, socket |> assign(empty?: false) |> stream_insert(:runs, run, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:run_updated, run}, socket) do
    if socket.assigns.filter in [nil, run.project],
      do: {:noreply, stream_insert(socket, :runs, run)},
      else: {:noreply, socket}
  end
end
