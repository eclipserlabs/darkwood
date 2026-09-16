defmodule Darkwood.Ingestion.Producer do
  @moduledoc """
  GenStage producer with back-pressure for the ingestion pipeline.

  The `IngestController` pushes external payloads here with `push/1`.
  Demand from Broadway processors controls how fast events flow,
  providing natural back-pressure under load.
  """
  use GenStage

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Enqueue an ingestion payload for async processing."
  def push(event) do
    GenStage.cast(__MODULE__, {:push, event})
  end

  @impl true
  def init(:ok) do
    {:producer, {:queue.new(), 0}}
  end

  @impl true
  def handle_cast({:push, event}, {queue, pending}) do
    queue = :queue.in(event, queue)
    dispatch({queue, pending}, [])
  end

  @impl true
  def handle_demand(incoming, {queue, pending}) when incoming > 0 do
    dispatch({queue, pending + incoming}, [])
  end

  defp dispatch({queue, 0}, acc) do
    {:noreply, Enum.reverse(acc), {queue, 0}}
  end

  defp dispatch({queue, pending}, acc) do
    case :queue.out(queue) do
      {{:value, event}, queue} -> dispatch({queue, pending - 1}, [event | acc])
      {:empty, queue} -> {:noreply, Enum.reverse(acc), {queue, pending}}
    end
  end
end
