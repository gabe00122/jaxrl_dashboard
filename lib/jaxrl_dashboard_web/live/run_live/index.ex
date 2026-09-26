defmodule JaxrlDashboardWeb.RunLive.Index do
  use JaxrlDashboardWeb, :live_view

  import JaxrlDashboardWeb.RunComponents

  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.Settings

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Training runs
        <:subtitle>Runs start one at a time, oldest first.</:subtitle>
      </.header>

      <.form
        for={@form}
        id="enqueue-form"
        phx-change="validate"
        phx-submit="enqueue"
        class="grid gap-x-4 rounded-box border border-base-300 bg-base-200/40 p-4 sm:grid-cols-[1fr_1fr_auto] sm:items-start"
      >
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

      <.table
        id="runs"
        rows={@streams.runs}
        row_click={fn {_id, run} -> JS.navigate(~p"/runs/#{run.name}") end}
      >
        <:col :let={{_id, run}} label="Name">
          <span class="font-mono text-sm">{run.name}</span>
        </:col>
        <:col :let={{_id, run}} label="Status"><.status_badge run={run} /></:col>
        <:col :let={{_id, run}} label="Config">
          <span class="text-sm text-base-content/70">{run.config_source}</span>
        </:col>
        <:col :let={{_id, run}} label="Queued">
          <.local_time id={"run-#{run.id}-queued"} at={run.inserted_at} />
        </:col>
        <:col :let={{_id, run}} label="Duration">
          <.duration id={"run-#{run.id}-duration"} run={run} />
        </:col>
        <:col :let={{_id, run}} label="By">
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

      <p :if={@empty?} id="runs-empty" class="py-10 text-center text-base-content/60">
        No runs yet. Pick a config above to queue one.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()
    runs = Runs.list_runs()

    {:ok,
     socket
     |> assign(page_title: "Runs", config_files: Settings.config_files(), empty?: runs == [])
     |> assign(form: to_form(Runs.change_run()))
     |> stream(:runs, runs)}
  end

  @impl true
  def handle_event("validate", %{"run" => params}, socket) do
    changeset = Runs.change_run(params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("enqueue", %{"run" => params}, socket) do
    case Runs.enqueue_run(socket.assigns.current_scope, params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{run.name}")
         |> assign(form: to_form(Runs.change_run()))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Runs.cancel_run(Runs.get_run!(id)) do
      {:ok, _run} ->
        {:noreply, socket}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "That run already finished.")}
    end
  end

  @impl true
  def handle_info({:run_created, run}, socket) do
    {:noreply, socket |> assign(empty?: false) |> stream_insert(:runs, run, at: 0)}
  end

  def handle_info({:run_updated, run}, socket) do
    {:noreply, stream_insert(socket, :runs, run)}
  end
end
