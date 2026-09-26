defmodule JaxrlDashboardWeb.RunComponents do
  @moduledoc """
  Components shared by the run pages.
  """
  use Phoenix.Component

  alias JaxrlDashboard.Runs.Run

  @doc """
  A colored badge for a run's status. Running runs that are being cancelled
  show as "stopping".
  """
  attr :run, Run, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium",
      status_class(@run)
    ]}>
      <span
        :if={@run.status == :running}
        class="size-1.5 rounded-full bg-current motion-safe:animate-pulse"
      />
      {status_label(@run)}
    </span>
    """
  end

  defp status_label(%Run{status: :running, cancel_requested_at: %DateTime{}}), do: "stopping"
  defp status_label(%Run{status: status}), do: Atom.to_string(status)

  defp status_class(%Run{status: :running, cancel_requested_at: %DateTime{}}),
    do: "bg-warning/15 text-warning"

  defp status_class(%Run{status: status}) do
    case status do
      :queued -> "bg-base-300 text-base-content/70"
      :running -> "bg-info/15 text-info"
      :succeeded -> "bg-success/15 text-success"
      :failed -> "bg-error/15 text-error"
      :lost -> "bg-error/15 text-error"
      :cancelled -> "bg-base-300 text-base-content/50 line-through"
    end
  end

  @doc """
  A timestamp shown in the viewer's timezone. Renders UTC on the server and
  is reformatted by the browser.
  """
  attr :id, :string, required: true
  attr :at, DateTime, default: nil

  def local_time(%{at: nil} = assigns), do: dash(assigns)

  def local_time(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() { this.format() },
        updated() { this.format() },
        format() {
          const date = new Date(this.el.dateTime)
          this.el.textContent = date.toLocaleString(undefined, {
            month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
          })
          this.el.title = date.toLocaleString()
        },
      }
    </script>
    <time id={@id} phx-hook=".LocalTime" datetime={DateTime.to_iso8601(@at)}>
      {Calendar.strftime(@at, "%b %-d %H:%M UTC")}
    </time>
    """
  end

  @doc """
  How long a run took, or a live-ticking elapsed time while it's running.
  """
  attr :id, :string, required: true
  attr :run, Run, required: true

  def duration(%{run: %Run{started_at: nil}} = assigns), do: dash(assigns)

  def duration(%{run: %Run{finished_at: nil}} = assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Elapsed">
      const format = (s) => {
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60
        const pad = (n) => String(n).padStart(2, "0")
        return h > 0 ? `${h}h ${pad(m)}m` : m > 0 ? `${m}m ${pad(sec)}s` : `${sec}s`
      }
      export default {
        mounted() {
          this.tick()
          this.timer = setInterval(() => this.tick(), 1000)
        },
        updated() { this.tick() },
        destroyed() { clearInterval(this.timer) },
        tick() {
          const since = Date.parse(this.el.dataset.since)
          this.el.textContent = format(Math.max(0, Math.floor((Date.now() - since) / 1000)))
        },
      }
    </script>
    <span id={@id} phx-hook=".Elapsed" data-since={DateTime.to_iso8601(@run.started_at)}>
      {format_duration(DateTime.diff(DateTime.utc_now(), @run.started_at))}
    </span>
    """
  end

  def duration(assigns) do
    ~H"""
    <span id={@id}>{format_duration(DateTime.diff(@run.finished_at, @run.started_at))}</span>
    """
  end

  defp dash(assigns) do
    ~H"""
    <span class="text-base-content/40">—</span>
    """
  end

  @doc "Formats seconds as `12s`, `3m 07s` or `1h 02m`."
  def format_duration(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"

  def format_duration(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{pad(rem(seconds, 60))}s"

  def format_duration(seconds), do: "#{div(seconds, 3600)}h #{pad(rem(div(seconds, 60), 60))}m"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
