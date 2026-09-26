defmodule JaxrlDashboard.RateLimiter do
  @moduledoc """
  Fixed-window rate limiter backed by ETS. Counters live in memory, so they
  reset on restart, which is fine for throttling login attempts.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Records a hit for `key` and checks it against `limit` hits per `window_ms`.

  Returns `:ok` while under the limit, or `{:error, retry_after_ms}`.
  """
  def hit(key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    window_start = now - rem(now, window_ms)
    expires_at = window_start + window_ms
    bucket = {key, window_start}

    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0, expires_at})

    if count <= limit, do: :ok, else: {:error, expires_at - now}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
