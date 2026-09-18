defmodule Darkwood.Ingestion.Producer do
  @moduledoc """
  GenStage producer with back-pressure for the ingestion pipeline.

  Bounded in-memory buffer with load-shedding: `push/1` returns
  `{:error, :overloaded}` instead of growing without bound.
  """
  use GenStage
  require Logger

  @default_max_buffer 5_000

  def max_buffer do
    Application.get_env(:darkwood, __MODULE__, [])
    |> Keyword.get(:max_buffer, @default_max_buffer)
  end

  def start_link(opts) do
    max = Keyword.get(opts, :max_buffer, max_buffer())
    GenStage.start_link(__MODULE__, max, name: __MODULE__)
  end

  @doc """
  Enqueue an ingestion payload for async processing.

  Returns `:ok` or `{:error, :overloaded}` when the buffer is full.
  """
  def push(event) do
    try do
      GenStage.call(__MODULE__, {:push, event}, 5_000)
    catch
      :exit, {:timeout, _} ->
        :telemetry.execute([:darkwood, :ingestion, :drop], %{count: 1}, %{reason: :timeout})
        {:error, :overloaded}
    end
  end

  @doc "Current buffered + pending demand depth (best effort)."
  def depth do
    try do
      GenStage.call(__MODULE__, :depth, 2_000)
    catch
      _, _ -> :unknown
    end
  end

  @impl true
  def init(max_buffer) do
    {:producer, {:queue.new(), 0, 0, max_buffer}}
  end

  @impl true
  def handle_call({:push, event}, _from, {queue, pending, buffered, max_buffer}) do
    if buffered >= max_buffer do
      :telemetry.execute([:darkwood, :ingestion, :drop], %{count: 1}, %{reason: :overloaded})
      Logger.warning("[ingestion] dropping event: buffer full (#{buffered}/#{max_buffer})")
      {:reply, {:error, :overloaded}, [], {queue, pending, buffered, max_buffer}}
    else
      queue = :queue.in(event, queue)
      :telemetry.execute([:darkwood, :ingestion, :push], %{count: 1}, %{buffered: buffered + 1})
      {state, events} = dispatch({queue, pending, buffered + 1, max_buffer}, [])
      {:reply, :ok, events, state}
    end
  end

  def handle_call(:depth, _from, {queue, pending, buffered, max} = state) do
    {:reply, %{buffered: buffered, pending: pending, queue_len: :queue.len(queue)}, [], state}
  rescue
    _ -> {:reply, :unknown, [], state}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    # Back-compat for direct casts: apply same bound, drop on overload.
    {queue, pending, buffered, max_buffer} = state

    if buffered >= max_buffer do
      :telemetry.execute([:darkwood, :ingestion, :drop], %{count: 1}, %{reason: :overloaded})
      {:noreply, [], state}
    else
      queue = :queue.in(event, queue)
      {new_state, events} = dispatch({queue, pending, buffered + 1, max_buffer}, [])
      {:noreply, events, new_state}
    end
  end

  @impl true
  def handle_demand(incoming, {queue, pending, buffered, max_buffer}) when incoming > 0 do
    {state, events} = dispatch({queue, pending + incoming, buffered, max_buffer}, [])
    {:noreply, events, state}
  end

  defp dispatch({queue, 0, buffered, max}, acc) do
    {{queue, 0, buffered, max}, Enum.reverse(acc)}
  end

  defp dispatch({queue, pending, buffered, max}, acc) do
    case :queue.out(queue) do
      {{:value, event}, queue} ->
        dispatch({queue, pending - 1, buffered - 1, max}, [event | acc])

      {:empty, queue} ->
        {{queue, pending, buffered, max}, Enum.reverse(acc)}
    end
  end
end
