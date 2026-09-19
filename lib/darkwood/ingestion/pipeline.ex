defmodule Darkwood.Ingestion.Pipeline do
  @moduledoc """
  Broadway pipeline for high-throughput event ingestion.

  Producer: `Darkwood.Ingestion.Producer` (GenStage, back-pressured).
  Processors: validate + aggregate/dedup via `Darkwood.Incidents.ingest_event/2`.
  Batcher: small batches to keep DB pressure bounded.

  Duplicate suppression (same incident + fingerprint within 5s) updates
  `metadata.count` / `metadata.last_seen` without broadcasting,
  so the LiveView is not flooded.
  """
  use Broadway

  alias Broadway.Message

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Darkwood.Ingestion.Producer, []},
        transformer: {__MODULE__, :transform, []},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 5, max_demand: 50]
      ],
      batchers: [
        default: [batch_size: 20, batch_timeout: 200]
      ]
    )
  end

  @doc """
  Enqueue an ingestion payload.

  `incident_id` is the integer DB id, `attrs` is a map with
  `kind`, `level`, `message`, `metadata`, optional `fingerprint`/`occurred_at`.
  Returns `:ok` immediately (async, back-pressured) or `{:error, :overloaded}`.
  """
  def push(incident_id, attrs) when is_map(attrs) do
    Darkwood.Ingestion.Producer.push(%{incident_id: incident_id, attrs: attrs})
  end

  @doc false
  def transform(event, _opts) do
    %Message{
      data: event,
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }
  end

  @impl true
  def handle_message(_, %Message{data: %{incident_id: incident_id, attrs: attrs}} = message, _) do
    start = System.monotonic_time()

    result =
      case Darkwood.Incidents.ingest_event(incident_id, attrs) do
        {:ok, _event} -> message
        {:error, reason} -> Message.failed(message, reason)
      end

    :telemetry.execute(
      [:darkwood, :ingestion, :processed],
      %{duration: System.monotonic_time() - start},
      %{incident_id: incident_id}
    )

    result
  end

  def handle_message(_, %Message{} = message, _) do
    Message.failed(message, :invalid_payload)
  end

  @impl true
  def handle_batch(_, messages, _, _) do
    messages
  end
end
