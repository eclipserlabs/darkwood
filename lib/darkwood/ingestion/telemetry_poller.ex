defmodule Darkwood.Ingestion.TelemetryPoller do
  @moduledoc "Emits ingestion buffer depth for telemetry_poller."

  def dispatch do
    case Darkwood.Ingestion.Producer.depth() do
      %{buffered: buffered} ->
        :telemetry.execute([:darkwood, :ingestion, :buffered], %{count: buffered}, %{})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
