defmodule Darkwood.IncidentsTest do
  use Darkwood.DataCase, async: true

  alias Darkwood.Incidents
  alias Darkwood.Incidents.{IncidentEvent}
  alias Darkwood.Repo

  test "creates and validates incidents" do
    assert {:ok, incident} =
             Incidents.create_incident(%{title: "Cache saturation", severity: :major})

    assert incident.severity == :major
    assert incident.status == :investigating
    assert {:error, changeset} = Incidents.create_incident(%{title: "x", severity: :critical})
    assert "should be at least 3 character(s)" in errors_on(changeset).title
  end

  test "rejects invalid severity and status" do
    assert {:error, changeset} =
             Incidents.create_incident(%{title: "Bad severity", severity: "extreme"})

    assert "is invalid" in errors_on(changeset).severity
    {:ok, incident} = Incidents.create_incident(%{title: "Status validation"})
    assert {:error, changeset} = Incidents.update_incident_status(incident, "unknown")
    assert "is invalid" in errors_on(changeset).status
  end

  test "sample creation is complete, transactional, and idempotent" do
    assert {:ok, first} = Incidents.create_sample_incident()
    assert length(Incidents.list_events(first)) == 5
    assert {:ok, second} = Incidents.create_sample_incident()
    assert first.id == second.id
    assert Enum.count(Incidents.list_incidents(), &(&1.title == first.title)) == 1
  end

  test "annotation requires author and body" do
    {:ok, incident} = Incidents.create_incident(%{title: "Annotation validation"})
    assert {:error, changeset} = Incidents.create_annotation(incident, %{})
    assert "can't be blank" in errors_on(changeset).author_name
    assert "can't be blank" in errors_on(changeset).body
  end

  test "rejects an event from another incident" do
    {:ok, first} = Incidents.create_incident(%{title: "First incident"})
    {:ok, second} = Incidents.create_incident(%{title: "Second incident"})

    {:ok, event} =
      Repo.insert(IncidentEvent.changeset(%IncidentEvent{incident_id: first.id}, event_attrs()))

    assert {:error, :event_not_in_incident} =
             Incidents.create_annotation(second, %{
               author_name: "Alice",
               body: "Wrong event",
               event_id: event.id
             })
  end

  test "updates incident status and publishes after persistence" do
    {:ok, incident} = Incidents.create_incident(%{title: "Status update"})
    :ok = Incidents.subscribe(incident.id)
    assert {:ok, updated} = Incidents.update_incident_status(incident, :resolved)
    assert updated.status == :resolved
    assert_receive {:incident_updated, %{id: id, status: :resolved}}
    assert id == incident.id
    assert Incidents.get_incident!(id).status == :resolved
  end

  defp event_attrs do
    %{occurred_at: DateTime.utc_now(), kind: :log, level: :info, message: "event"}
  end
end
