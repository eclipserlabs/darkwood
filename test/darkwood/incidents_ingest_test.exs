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

  test "malformed occurred_at fails closed" do
    {:ok, incident} = Incidents.create_incident(%{title: "Ingest timestamp validation"})

    assert {:error, changeset} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "bad time",
               occurred_at: "not-a-timestamp"
             })

    assert "is invalid" in errors_on(changeset).occurred_at

    assert {:error, changeset} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "bad type",
               occurred_at: 123
             })

    assert "is invalid" in errors_on(changeset).occurred_at
    assert Incidents.list_events(incident.id) == []
  end

  test "out-of-range occurred_at is rejected" do
    {:ok, incident} = Incidents.create_incident(%{title: "Ingest timestamp range"})

    future = DateTime.utc_now() |> DateTime.add(86_400, :second)

    assert {:error, changeset} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "from the future",
               occurred_at: future
             })

    assert "is out of range" in errors_on(changeset).occurred_at

    ancient = DateTime.utc_now() |> DateTime.add(-31 * 24 * 3600, :second)

    assert {:error, _} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "too old",
               occurred_at: ancient
             })

    assert Incidents.list_events(incident.id) == []
  end

  test "valid occurred_at values are accepted" do
    {:ok, incident} = Incidents.create_incident(%{title: "Ingest valid timestamps"})

    iso = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    assert {:ok, _} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "iso time",
               occurred_at: iso
             })

    assert {:ok, _} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "struct time",
               occurred_at: DateTime.utc_now()
             })
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

  test "failed ingestion broadcasts nothing" do
    {:ok, incident} = Incidents.create_incident(%{title: "No broadcast on failure"})
    :ok = Incidents.subscribe(incident.id)

    assert {:error, _} =
             Incidents.ingest_event(incident.id, %{
               kind: :log,
               level: :info,
               message: "bad time",
               occurred_at: "garbage"
             })

    refute_receive {:event_created, _}, 200
    refute_receive {:event_updated, _}, 200
    assert Incidents.list_events(incident.id) == []
  end

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

  test "list functions respect limits" do
    {:ok, incident} = Incidents.create_incident(%{title: "Pagination limit test"})

    for i <- 1..5 do
      {:ok, _} =
        Incidents.ingest_event(incident.id, %{kind: :log, level: :info, message: "msg-#{i}"})
    end

    assert length(Incidents.list_events(incident.id, limit: 2)) == 2
    assert length(Incidents.list_incidents(limit: 1)) == 1
  end

  defp aggregation_count(%{metadata: meta}) when is_map(meta) do
    meta["count"] || meta[:count] || 1
  end
end
