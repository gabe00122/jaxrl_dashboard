defmodule JaxrlDashboardWeb.RunLive.Show do
  use JaxrlDashboardWeb, :live_view

  import JaxrlDashboardWeb.RunComponents

  alias JaxrlDashboard.{Metrics, Projects, Runs, Videos}
  alias JaxrlDashboard.Runs.{LogFile, Run, Settings}
  alias JaxrlDashboard.Videos.Recorder

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
        <span class="font-mono text-lg break-words sm:text-xl">{@run.name}</span>
        <:subtitle>
          <span class="mt-1 inline-flex flex-wrap items-center gap-2">
            <.project_badge id="run-project" project={@run.project} />
            <.status_badge run={@run} />
          </span>
        </:subtitle>
        <:actions>
          <.link
            navigate={~p"/configs/new?#{[from: "run:" <> @run.name]}"}
            id="edit-config"
            class="btn btn-sm"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit as new config
          </.link>
          <.link
            navigate={~p"/compare?#{[runs: @run.name]}"}
            id="compare-run"
            class="btn btn-sm"
          >
            <.icon name="hero-chart-bar-square" class="size-4" /> Compare
          </.link>
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

      <dl class="grid grid-cols-2 gap-x-6 gap-y-4 rounded-box border border-base-300 bg-base-100 p-4 text-sm sm:grid-cols-4">
        <.detail label="Config">{@run.config_source || "—"}</.detail>
        <.detail label="Queued by">{(@run.user && @run.user.username) || "—"}</.detail>
        <.detail label="Queued"><.local_time id="run-queued" at={@run.inserted_at} /></.detail>
        <.detail label="Started"><.local_time id="run-started" at={@run.started_at} /></.detail>
        <.detail label="Finished"><.local_time id="run-finished" at={@run.finished_at} /></.detail>
        <.detail label="Duration"><.duration id="run-duration" run={@run} /></.detail>
        <.detail label="Exit code">{@run.exit_code || "—"}</.detail>
        <div class="col-span-2 sm:col-span-4">
          <dt class="text-xs text-base-content/60">Results</dt>
          <dd :for={stage <- @stages} class="mt-0.5 flex items-baseline gap-2">
            <span :if={length(@stages) > 1} class="w-24 shrink-0 text-xs text-base-content/60">
              {stage.label}
            </span>
            <span class="font-mono text-xs break-all">{Projects.stage_dir(@run, stage)}</span>
          </dd>
        </div>
      </dl>

      <section>
        <div class="mb-2 flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
            <h2 class="text-sm font-semibold">Metrics</h2>
            <.stage_tabs :if={length(@stages) > 1} stages={@stages} stage={@stage} logged={@logged} />
          </div>
        </div>
        <%!-- Rendered client-side by assets/js/hooks/metrics_charts.js --%>
        <div id="metrics" phx-hook="MetricsCharts" phx-update="ignore" data-mode="single"></div>
      </section>

      <.videos :if={@recordable?} run={@run} videos={@videos} />

      <section>
        <div class="mb-2 flex items-baseline justify-between gap-4">
          <h2 class="text-sm font-semibold">Output</h2>
          <.link
            :if={!@output_empty?}
            href={~p"/runs/#{@run.name}/files/output.log"}
            class="text-xs text-base-content/60 hover:text-base-content"
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-3.5" /> output.log
          </.link>
        </div>
        <%!-- column-reverse keeps the view pinned to the newest output --%>
        <div class="flex max-h-[28rem] flex-col-reverse overflow-auto rounded-box border border-base-300 bg-neutral p-4 text-neutral-content">
          <div
            id="run-output"
            phx-update="stream"
            class="font-mono text-xs leading-relaxed"
          >
            <div
              :for={{dom_id, line} <- @streams.output}
              id={dom_id}
              class="min-h-[1.625em] whitespace-pre-wrap break-all"
            >
              {line.text}
            </div>
          </div>
          <p :if={@output_empty?} id="run-output-empty" class="font-mono text-xs opacity-70">
            {if @run.status == :queued, do: "Waiting in the queue...", else: "No output."}
          </p>
        </div>
      </section>

      <details class="rounded-box border border-base-300">
        <summary class="cursor-pointer px-4 py-3 text-sm font-semibold">Config</summary>
        <pre class="overflow-auto border-t border-base-300 p-4 font-mono text-xs">{Jason.encode!(@run.config, pretty: true)}</pre>
      </details>
    </Layouts.app>
    """
  end

  attr :stages, :list, required: true
  attr :stage, :any, required: true
  attr :logged, MapSet, required: true, doc: "ids of stages that have logged metrics"

  # The stages a pipeline run goes through, in order; picking one shows its
  # metrics. Stages that haven't logged anything yet are dimmed.
  defp stage_tabs(assigns) do
    ~H"""
    <div
      id="stage-tabs"
      role="tablist"
      class="flex items-center gap-0.5 rounded-field bg-base-200 p-0.5"
    >
      <%= for {stage, index} <- Enum.with_index(@stages) do %>
        <.icon
          :if={index > 0}
          name="hero-chevron-right-micro"
          class="size-3.5 text-base-content/30"
        />
        <button
          type="button"
          role="tab"
          id={"stage-#{stage.id}"}
          aria-selected={to_string(stage.id == @stage.id)}
          phx-click="select_stage"
          phx-value-stage={stage.id}
          class={[
            "rounded-[calc(var(--radius-field)-2px)] px-2.5 py-1 text-xs font-medium transition-all duration-150",
            if(stage.id == @stage.id,
              do: "bg-base-100 text-base-content shadow-sm",
              else: "text-base-content/60 hover:text-base-content"
            ),
            !MapSet.member?(@logged, stage.id) && stage.id != @stage.id && "opacity-60"
          ]}
          title={if !MapSet.member?(@logged, stage.id), do: "No metrics logged yet"}
        >
          {stage.label}
        </button>
      <% end %>
    </div>
    """
  end

  attr :run, Run, required: true
  attr :videos, :map, required: true

  defp videos(assigns) do
    ~H"""
    <section id="videos">
      <div class="mb-2 flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
        <div class="flex flex-wrap items-baseline gap-x-3">
          <h2 class="text-sm font-semibold">Videos</h2>
          <span :if={@videos.set} id="videos-meta" class="text-xs text-base-content/60">
            checkpoint {@videos.set.checkpoint_step || "?"} · recorded
            <.local_time id="videos-recorded-at" at={@videos.set.created_at} />
          </span>
        </div>
        <%= if @videos.state == :recording do %>
          <.button
            id="cancel-recording"
            phx-click="cancel_recording"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark" class="size-4" /> Cancel
          </.button>
        <% else %>
          <.button
            id="record-videos"
            phx-click="record_videos"
            phx-disable-with="Starting..."
            class="btn btn-primary btn-soft btn-sm"
          >
            <.icon name="hero-video-camera" class="size-4" />
            {if @videos.set, do: "Re-record", else: "Record videos"}
          </.button>
        <% end %>
      </div>

      <div
        :if={@videos.state == :recording}
        id="videos-progress"
        class="mb-3 rounded-box border border-base-300 p-4"
      >
        <div class="flex items-center justify-between gap-4 text-sm">
          <span class="flex min-w-0 items-center gap-2">
            <span class="loading loading-spinner loading-xs shrink-0 text-primary"></span>
            <span class="truncate">{progress_label(@videos.progress)}</span>
          </span>
          <span class="font-mono text-xs tabular-nums text-base-content/60">
            {progress_percent(@videos.progress)}%
          </span>
        </div>
        <div class="mt-3 h-1.5 overflow-hidden rounded-full bg-base-300">
          <div
            class="h-full rounded-full bg-primary transition-[width] duration-700 ease-out"
            style={"width: #{progress_percent(@videos.progress)}%"}
          />
        </div>
      </div>

      <div
        :if={@videos.state == :failed}
        id="videos-error"
        class="mb-3 rounded-box border border-error/30 bg-error/10 text-sm text-error"
      >
        <div class="flex gap-2 px-4 py-3">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          <span class="min-w-0 break-words">Recording failed: {@videos.error.summary}</span>
        </div>
        <details :if={@videos.error.output != []} class="border-t border-error/20">
          <summary class="cursor-pointer px-4 py-2 text-xs">Output</summary>
          <pre class="max-h-72 overflow-auto px-4 pb-3 font-mono text-xs whitespace-pre-wrap text-base-content/80">{Enum.join(@videos.error.output, "\n")}</pre>
        </details>
      </div>

      <div
        :if={@videos.set}
        id="video-grid"
        class={[
          "grid items-start gap-4 sm:grid-cols-2",
          length(@videos.set.videos) > 2 && "lg:grid-cols-3"
        ]}
      >
        <figure
          :for={{video, index} <- Enum.with_index(@videos.set.videos)}
          id={"video-#{@videos.set.id}-#{index}"}
          class="overflow-hidden rounded-box border border-base-300 bg-black shadow-sm transition-shadow hover:shadow-md"
        >
          <video
            src={~p"/runs/#{@run.name}/videos/#{@videos.set.id}/#{video.file}"}
            width={video.width}
            height={video.height}
            class="block h-auto w-full"
            controls
            autoplay
            muted
            loop
            playsinline
            preload="metadata"
          />
          <figcaption class="flex items-center justify-between gap-3 border-t border-base-300 bg-base-200 px-3 py-2 text-xs">
            <span class="truncate font-mono font-medium">{video.task}</span>
            <.link
              href={~p"/runs/#{@run.name}/videos/#{@videos.set.id}/#{video.file}"}
              download={"#{@run.name}-#{video.task}.mp4"}
              class="shrink-0 text-base-content/60 transition-colors hover:text-base-content"
              title="Download"
            >
              <.icon name="hero-arrow-down-tray-micro" class="size-3.5" /> mp4
            </.link>
          </figcaption>
        </figure>
      </div>

      <div
        :if={is_nil(@videos.set) and @videos.state != :recording}
        id="videos-empty"
        class="flex flex-col items-center gap-1 rounded-box border border-dashed border-base-300 px-4 py-8 text-center"
      >
        <.icon name="hero-film" class="size-6 text-base-content/40" />
        <p class="text-sm font-medium">No videos yet</p>
        <p class="text-xs text-base-content/60">
          Records one episode of each task, played by the latest checkpoint.
        </p>
      </div>
    </section>
    """
  end

  defp progress_label(nil), do: "Loading the latest checkpoint..."

  defp progress_label(%{task: task, task_count: 1}), do: "Recording #{task}"

  defp progress_label(%{task: task, task_index: index, task_count: count}),
    do: "Recording #{task} (task #{index} of #{count})"

  defp progress_percent(progress), do: round(Videos.fraction(progress) * 100)

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

  # Output lines kept on the page; older ones are dropped from the DOM.
  @max_output_lines 1_000
  @output_tail_bytes 64 * 1024

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    run = Runs.get_run_by_name!(name)

    if connected?(socket) do
      Runs.subscribe()
      Runs.subscribe_run(name)
    end

    {lines, output_offset} =
      LogFile.read_tail_lines(Settings.output_path(name), @output_tail_bytes)

    recordable? = Videos.recordable?(run)
    stages = Projects.stages(run)

    logged =
      for stage <- stages,
          File.exists?(Metrics.path(Projects.stage_dir(run, stage))),
          into: MapSet.new(),
          do: stage.id

    {:ok,
     socket
     |> assign(
       page_title: run.name,
       run: run,
       stages: stages,
       # Shown: the furthest stage that has logged anything.
       stage: Enum.find(Enum.reverse(stages), hd(stages), &MapSet.member?(logged, &1.id)),
       logged: logged,
       # Once a stage is picked by hand, a later stage starting doesn't switch to it.
       stage_picked?: false,
       output_offset: output_offset,
       output_empty?: lines == [],
       recordable?: recordable?,
       videos: if(recordable?, do: Videos.status(name)),
       # Last metrics step sent to the chart hook; nil until it loads.
       metrics_last_step: nil
     )
     |> stream_configure(:output, dom_id: &"output-#{&1.offset}")
     |> stream(:output, Enum.map(lines, &output_item/1), limit: -@max_output_lines)}
  end

  defp output_item({offset, text}), do: %{offset: offset, text: text}

  @impl true
  def handle_event("cancel", _params, socket) do
    case Runs.cancel_run(socket.assigns.run) do
      {:ok, run} ->
        {:noreply, assign(socket, run: run)}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "The run already finished.")}
    end
  end

  def handle_event("record_videos", _params, socket) do
    case Recorder.start(socket.assigns.run) do
      {:ok, status} -> {:noreply, assign(socket, videos: status)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_recording", _params, socket) do
    :ok = Recorder.cancel(socket.assigns.run.name)
    {:noreply, socket}
  end

  def handle_event("select_stage", %{"stage" => id}, socket) do
    case Enum.find(socket.assigns.stages, &(&1.id == id)) do
      nil -> {:noreply, socket}
      stage -> {:noreply, socket |> assign(stage_picked?: true) |> show_stage(stage)}
    end
  end

  # The chart hook asks for the full history once it's mounted (and again
  # when the stage changes); after that it gets appended rows pushed as
  # "metrics_append".
  def handle_event("load_metrics", _params, socket) do
    %{run: run, stage: stage} = socket.assigns

    metrics =
      Projects.stage_dir(run, stage) |> Metrics.load() |> Map.merge(%{name: run.name, slot: 0})

    {:reply, %{runs: [metrics]}, assign(socket, metrics_last_step: List.last(metrics.steps, -1))}
  end

  defp show_stage(socket, stage) do
    if stage.id == socket.assigns.stage.id do
      socket
    else
      socket
      |> assign(stage: stage, metrics_last_step: nil)
      |> push_event("metrics_reload", %{})
    end
  end

  @impl true
  def handle_info({:run_updated, %Run{id: id} = run}, %{assigns: %{run: %Run{id: id}}} = socket) do
    {:noreply, assign(socket, run: run)}
  end

  def handle_info({event, _other_run}, socket) when event in [:run_created, :run_updated] do
    {:noreply, socket}
  end

  def handle_info({:metrics, name, stage_id, rows}, socket) do
    socket = note_logged(socket, stage_id)
    %{stage: stage, metrics_last_step: last_step} = socket.assigns

    # Other stages' rows are skipped, and so are rows from before the hook
    # has loaded: its load reads the file, which already has them.
    new_rows =
      if stage_id == stage.id and last_step != nil,
        do: Enum.filter(rows, &(&1.step > last_step)),
        else: []

    case new_rows do
      [] ->
        {:noreply, socket}

      new_rows ->
        {:noreply,
         socket
         |> push_event("metrics_append", %{run: name, rows: new_rows})
         |> assign(metrics_last_step: List.last(new_rows).step)}
    end
  end

  def handle_info({:videos, _name, status}, socket) do
    {:noreply, assign(socket, videos: status)}
  end

  def handle_info({:output, _name, lines}, socket) do
    case Enum.filter(lines, fn {offset, _} -> offset >= socket.assigns.output_offset end) do
      [] ->
        {:noreply, socket}

      new_lines ->
        {offset, text} = List.last(new_lines)

        socket =
          Enum.reduce(new_lines, socket, fn line, socket ->
            stream_insert(socket, :output, output_item(line), limit: -@max_output_lines)
          end)

        {:noreply,
         assign(socket, output_offset: offset + byte_size(text) + 1, output_empty?: false)}
    end
  end

  # A stage logging for the first time. Unless a stage was picked by hand,
  # the page follows the pipeline on to it.
  defp note_logged(socket, stage_id) do
    %{stages: stages, stage: current, logged: logged} = socket.assigns

    if MapSet.member?(logged, stage_id) do
      socket
    else
      socket = assign(socket, logged: MapSet.put(logged, stage_id))
      position = fn id -> Enum.find_index(stages, &(&1.id == id)) end

      if position.(stage_id) > position.(current.id) and not socket.assigns.stage_picked?,
        do: show_stage(socket, Enum.at(stages, position.(stage_id))),
        else: socket
    end
  end
end
