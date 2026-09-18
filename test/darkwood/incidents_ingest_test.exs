defmodule Darkwood.IncidentsIngestTest do
  use Darkwood.DataCase, async: false

  alias Darkwood.Incidents

  test "rejects oversized message and metadata" do
    {:ok, incident} = Incidents.create_incident(%{title: "Ingest validation limits"})

    long = String.duplicate("x", 5001)

    assert {:error, changeset} =
             Incidents.ingest_event(incident.id, %{kind: :log, level: :info, message: long})

    assert "is too long" in errors_on(changeset).message

    big_meta = for i <- 1..60, into: %{}, do: {"k#{i}", i}

    assert {:error, changeset} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "ok",
               metadata: big_meta
             })

    assert "has too many keys" in errors_on(changeset).metadata
  end

  test "aggregation broadcasts event_updated after commit" do
    {:ok, incident} = Incidents.create_incident(%{title: "Aggregation broadcast test"})
    :ok = Incidents.subscribe(incident.id)

    attrs = %{kind: :error, level: :error, message: "dup-signal"}

    assert {:ok, _} = Incidents.ingest_event(incident.id, attrs)
    assert {:ok, _} = Incidents.ingest_event(incident.id, attrs)

    assert_receive {:event_created, _}, 2_000
    assert_receive {:event_updated, %{metadata: %{"count" => 2}}}, 2_000
  end

  test "list functions respect limits" do
    {:ok, incident} = Incidents.create_incident(%{title: "Pagination limit test"})

    for i <- 1..5 do
      {:ok, _} =
        Incidents.ingest_event(incident.id, %{kind: :log, level: :info, message: "msg-#{i}"})
    end

    assert length(Incidents.list_events(incident.id, limit: 2)) == 2
    assert length(Incidents.list_incidents(limit: 1)) == 1
  end
end
