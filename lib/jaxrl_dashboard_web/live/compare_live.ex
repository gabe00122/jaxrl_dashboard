defmodule JaxrlDashboardWeb.CompareLive do
  @moduledoc """
  Several runs' metrics on the same charts, lined up by step. Runs with
  several stages (llm_rl's PPO pipeline) are compared by their main stage.

  The selection lives in the URL (`/compare?runs=a,b,c`) so a comparison can
  be bookmarked or shared. Each run keeps its color slot while the page is
  open: removing one run never repaints the others, and added runs take the
  lowest free slot.
  """
  use JaxrlDashboardWeb, :live_view

  import JaxrlDashboardWeb.RunComponents

  alias JaxrlDashboard.{Metrics, Projects, Runs}
  alias JaxrlDashboard.Runs.Run

  # One per categorical palette slot; a 9th color would be indistinguishable.
  @max_runs 8

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:runs}>
      <.link
        navigate={~p"/"}
        class="-mb-2 inline-flex items-center gap-1 text-sm text-base-content/60 transition-colors hover:text-base-content"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> All runs
      </.link>

      <.header>
        Compare runs
        <:subtitle>Up to {@max_runs} runs, lined up by training step.</:subtitle>
      </.header>

      <%!-- The legend: every compared run with its line color. --%>
      <div id="compare-legend" class="flex flex-wrap items-center gap-2">
        <div
          :for={run <- @runs}
          id={"compare-run-#{run.name}"}
          class="inline-flex max-w-full min-w-0 items-center gap-2 rounded-full border border-base-300 bg-base-100 py-1 pr-1 pl-3 text-sm"
        >
          <span
            class="inline-block h-0.5 w-4 shrink-0 rounded-full"
            style={"background: var(--series-#{@slots[run.name] + 1})"}
          />
          <.link navigate={~p"/runs/#{run.name}"} class="min-w-0 truncate font-mono hover:underline">
            {run.name}
          </.link>
          <span class="contents max-sm:hidden">
            <.project_badge project={run.project} />
          </span>
          <.status_badge run={run} />
          <button
            type="button"
            phx-click="remove"
            phx-value-name={run.name}
            class="btn btn-ghost btn-xs btn-circle shrink-0"
            aria-label={"Remove #{run.name}"}
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>

        <.form
          :if={length(@runs) < @max_runs}
          for={%{}}
          id="add-run-form"
          phx-submit="add"
          class="flex w-full items-center gap-2 sm:w-auto [&_.fieldset]:mb-0 [&_.fieldset]:flex-1 [&_.fieldset]:py-0 [&_label]:block"
        >
          <.input
            type="text"
            name="name"
            value=""
            list="run-names"
            placeholder="Add a run..."
            autocomplete="off"
            aria-label="Run name"
          />
          <datalist id="run-names">
            <option :for={name <- @available_names} value={name} />
          </datalist>
          <.button class="btn">Add</.button>
        </.form>
      </div>

      <%!-- Rendered client-side by assets/js/hooks/metrics_charts.js --%>
      <div id="metrics" phx-hook="MetricsCharts" phx-update="ignore" data-mode="compare"></div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     assign(socket,
       page_title: "Compare runs",
       max_runs: @max_runs,
       runs: [],
       slots: %{},
       available_names: Runs.list_run_names(),
       # Last metrics step sent to the chart hook per run; nil until it loads.
       last_steps: %{},
       loaded?: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    names =
      params
      |> Map.get("runs", "")
      |> String.split(",", trim: true)
      |> Enum.uniq()
      |> Enum.take(@max_runs)

    runs = Runs.get_runs_by_names(names)
    new_names = Enum.map(runs, & &1.name)
    old_names = Enum.map(socket.assigns.runs, & &1.name)

    if connected?(socket) do
      Enum.each(new_names -- old_names, &Runs.subscribe_run/1)
      Enum.each(old_names -- new_names, &Runs.unsubscribe_run/1)
    end

    socket =
      assign(socket,
        runs: runs,
        slots: assign_slots(socket.assigns.slots, new_names),
        last_steps: Map.take(socket.assigns.last_steps, new_names)
      )

    # Once the hook has data, a changed selection means loading again.
    socket =
      if socket.assigns.loaded? and new_names != old_names,
        do: push_event(socket, "metrics_reload", %{}),
        else: socket

    {:noreply, socket}
  end

  # Runs that stay keep their slot; new ones take the lowest free slot.
  defp assign_slots(slots, names) do
    kept = Map.take(slots, names)
    free = Enum.to_list(0..(@max_runs - 1)) -- Map.values(kept)

    names
    |> Enum.reject(&Map.has_key?(kept, &1))
    |> Enum.zip(free)
    |> Map.new()
    |> Map.merge(kept)
  end

  @impl true
  def handle_event("load_metrics", _params, socket) do
    %{runs: runs, slots: slots} = socket.assigns

    payload =
      for run <- runs do
        run
        |> Projects.stage_dir(Projects.main_stage(run))
        |> Metrics.load()
        |> Map.merge(%{name: run.name, slot: slots[run.name]})
      end

    last_steps = Map.new(payload, &{&1.name, List.last(&1.steps, -1)})
    {:reply, %{runs: payload}, assign(socket, last_steps: last_steps, loaded?: true)}
  end

  def handle_event("add", %{"name" => name}, socket) do
    name = String.trim(name)
    names = Enum.map(socket.assigns.runs, & &1.name)

    cond do
      name in names ->
        {:noreply, socket}

      name not in socket.assigns.available_names ->
        {:noreply, put_flash(socket, :error, "No run named #{inspect(name)}.")}

      true ->
        {:noreply, push_patch(socket, to: compare_path(names ++ [name]))}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    names = for run <- socket.assigns.runs, run.name != name, do: run.name
    {:noreply, push_patch(socket, to: compare_path(names))}
  end

  defp compare_path([]), do: ~p"/compare"
  defp compare_path(names), do: ~p"/compare?#{[runs: Enum.join(names, ",")]}"

  @impl true
  def handle_info({:metrics, name, stage_id, rows}, socket) do
    main_stage? =
      Enum.any?(
        socket.assigns.runs,
        &(&1.name == name and Projects.main_stage(&1).id == stage_id)
      )

    case main_stage? && socket.assigns.last_steps do
      %{^name => last_step} ->
        case Enum.filter(rows, &(&1.step > last_step)) do
          [] ->
            {:noreply, socket}

          new_rows ->
            {:noreply,
             socket
             |> push_event("metrics_append", %{run: name, rows: new_rows})
             |> update(:last_steps, &Map.put(&1, name, List.last(new_rows).step))}
        end

      # Another stage, or not loaded yet: the hook's load reads the file,
      # which has these rows.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:output, _name, _lines}, socket), do: {:noreply, socket}

  def handle_info({:run_updated, %Run{} = run}, socket) do
    runs = Enum.map(socket.assigns.runs, &if(&1.id == run.id, do: run, else: &1))
    {:noreply, assign(socket, runs: runs)}
  end

  def handle_info({:run_created, %Run{name: name}}, socket) do
    {:noreply, update(socket, :available_names, &[name | &1])}
  end
end
