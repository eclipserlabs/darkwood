defmodule Darkwood.Ingestion.PipelineTest do
  use Darkwood.DataCase, async: false

  alias Darkwood.Incidents
  alias Darkwood.Ingestion.Pipeline

  test "identical payloads aggregate into a single row within the 5s window" do
    {:ok, incident} = Incidents.create_incident(%{title: "Ingestion flood test"})

    attrs = %{kind: :error, level: :error, message: "boom", metadata: %{service: "api"}}

    for _ <- 1..200 do
      assert {:ok, _} = Incidents.ingest_event(incident.id, attrs)
    end

    events = Incidents.list_events(incident.id)
    assert length(events) in 1..2

    aggregated = Enum.max_by(events, &aggregation_count/1)
    assert aggregation_count(aggregated) >= 100
  end

  test "unique payloads create distinct rows" do
    {:ok, incident} = Incidents.create_incident(%{title: "Unique ingestion test"})

    for i <- 1..50 do
      assert {:ok, _} =
               Incidents.ingest_event(incident.id, %{
                 kind: :log,
                 level: :info,
                 message: "unique-#{i}",
                 metadata: %{}
               })
    end

    assert length(Incidents.list_events(incident.id)) == 50
  end

  test "broadway processor handles messages and aggregates" do
    {:ok, incident} = Incidents.create_incident(%{title: "Broadway test"})

    payload = %{
      incident_id: incident.id,
      attrs: %{"kind" => "error", "level" => "error", "message" => "via-broadway", "metadata" => %{}}
    }

    ref = Broadway.test_message(Pipeline, payload)
    assert_receive {:ack, ^ref, [_successful], []}, 5_000

    ref2 = Broadway.test_message(Pipeline, payload)
    assert_receive {:ack, ^ref2, [_successful], []}, 5_000

    events = Incidents.list_events(incident.id)
    assert length(events) == 1
    assert aggregation_count(hd(events)) == 2
  end

  defp aggregation_count(%{metadata: meta}) when is_map(meta) do
    meta["count"] || meta[:count] || 1
  end
end
