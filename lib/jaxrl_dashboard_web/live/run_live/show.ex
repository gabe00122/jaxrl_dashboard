defmodule JaxrlDashboardWeb.RunLive.Show do
  use JaxrlDashboardWeb, :live_view

  import JaxrlDashboardWeb.RunComponents

  alias JaxrlDashboard.Runs
  alias JaxrlDashboard.Runs.{Launcher, Run, Settings}

  @output_refresh_interval 1_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.link navigate={~p"/"} class="text-sm text-base-content/60 hover:text-base-content">
        <.icon name="hero-arrow-left-micro" class="size-4" /> All runs
      </.link>

      <.header>
        <span class="font-mono">{@run.name}</span>
        <:subtitle><.status_badge run={@run} /></:subtitle>
        <:actions>
          <.button
            :if={@run.status in [:queued, :running] and is_nil(@run.cancel_requested_at)}
            id="cancel-run"
            phx-click="cancel"
            data-confirm={"Cancel #{@run.name}?"}
            class="btn btn-error btn-soft btn-sm"
          >
            <.icon name="hero-stop" class="size-4" /> Cancel run
          </.button>
        </:actions>
      </.header>

      <div
        :if={@run.error}
        id="run-error"
        class="rounded-box border border-error/30 bg-error/10 px-4 py-3 text-sm text-error"
      >
        {@run.error}
      </div>

      <dl class="grid grid-cols-2 gap-x-6 gap-y-3 rounded-box border border-base-300 p-4 text-sm sm:grid-cols-4">
        <.detail label="Config">{@run.config_source || "—"}</.detail>
        <.detail label="Queued by">{(@run.user && @run.user.username) || "—"}</.detail>
        <.detail label="Queued"><.local_time id="run-queued" at={@run.inserted_at} /></.detail>
        <.detail label="Started"><.local_time id="run-started" at={@run.started_at} /></.detail>
        <.detail label="Finished"><.local_time id="run-finished" at={@run.finished_at} /></.detail>
        <.detail label="Duration"><.duration id="run-duration" run={@run} /></.detail>
        <.detail label="Exit code">{@run.exit_code || "—"}</.detail>
        <.detail label="Results">
          <span class="font-mono text-xs break-all">{@experiment_dir}</span>
        </.detail>
      </dl>

      <section>
        <h2 class="mb-2 text-sm font-semibold">Output</h2>
        <%!-- column-reverse keeps the view pinned to the newest output --%>
        <div class="flex max-h-[32rem] flex-col-reverse overflow-auto rounded-box bg-neutral p-4 text-neutral-content">
          <pre id="run-output" class="whitespace-pre-wrap break-all font-mono text-xs leading-relaxed">{output_or_placeholder(@output, @run)}</pre>
        </div>
      </section>

      <details class="rounded-box border border-base-300">
        <summary class="cursor-pointer px-4 py-3 text-sm font-semibold">Config</summary>
        <pre class="overflow-auto border-t border-base-300 p-4 font-mono text-xs">{Jason.encode!(@run.config, pretty: true)}</pre>
      </details>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-base-content/60">{@label}</dt>
      <dd class="mt-0.5">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp output_or_placeholder("", %Run{status: :queued}), do: "Waiting in the queue..."
  defp output_or_placeholder("", _run), do: "No output."
  defp output_or_placeholder(output, _run), do: output

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    run = Runs.get_run_by_name!(name)

    if connected?(socket) do
      Runs.subscribe()
      schedule_output_refresh(run)
    end

    {:ok,
     assign(socket,
       page_title: run.name,
       run: run,
       output: Launcher.read_output_tail(run),
       experiment_dir: Settings.experiment_dir(run.name)
     )}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    case Runs.cancel_run(socket.assigns.run) do
      {:ok, run} ->
        {:noreply, assign(socket, run: run)}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "The run already finished.")}
    end
  end

  @impl true
  def handle_info({:run_updated, %Run{id: id} = run}, %{assigns: %{run: %Run{id: id}}} = socket) do
    # Pick up the last lines once the run ends, and start polling when it starts.
    if Run.finished?(run) or socket.assigns.run.status == :queued do
      send(self(), :refresh_output)
    end

    {:noreply, assign(socket, run: run)}
  end

  def handle_info({event, _other_run}, socket) when event in [:run_created, :run_updated] do
    {:noreply, socket}
  end

  def handle_info(:refresh_output, socket) do
    run = socket.assigns.run
    schedule_output_refresh(run)
    {:noreply, assign(socket, output: Launcher.read_output_tail(run))}
  end

  # Polls the log file while the run is live. Moves to a shared tailer
  # process along with the metrics.
  defp schedule_output_refresh(%Run{status: :running}),
    do: Process.send_after(self(), :refresh_output, @output_refresh_interval)

  defp schedule_output_refresh(_run), do: :ok
end
