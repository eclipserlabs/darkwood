defmodule Darkwood.Ingestion.RateLimiter do
  @moduledoc """
  Minimal sliding-window rate limiter for the ingest API.
  120 requests/minute per client IP (burst-tolerant).
  """
  use GenServer

  @table __MODULE__
  @limit 120
  @window_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def check(ip) when is_binary(ip) do
    now = System.monotonic_time(:millisecond)

    try do
      case :ets.lookup(@table, ip) do
        [{^ip, count, window_start}] when now - window_start < @window_ms ->
          if count >= @limit do
            {:error, :throttled}
          else
            :ets.update_element(@table, ip, {2, count + 1})
            :ok
          end

        _ ->
          :ets.insert(@table, {ip, 1, now})
          :ok
      end
    rescue
      ArgumentError -> :ok
    end
  end

  def check(_), do: :ok

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    # Opportunistic cleanup every window.
    :timer.send_interval(@window_ms, :prune)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.monotonic_time(:millisecond)

    try do
      :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:<, :"$3", now - @window_ms}], [true]}])
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end
end
