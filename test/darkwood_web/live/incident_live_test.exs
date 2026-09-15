defmodule DarkwoodWeb.IncidentLiveTest do
  use DarkwoodWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Darkwood.Incidents

  defp joined(conn, name \\ "Alice") do
    init_test_session(conn, %{"display_name" => name, "client_id" => Ecto.UUID.generate()})
  end

  test "index redirects users without a display name", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/join"}}} = live(conn, ~p"/")
  end

  test "index lists and creates incidents", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "Worker backlog", severity: :major})
    {:ok, view, _html} = live(joined(conn), ~p"/")
    assert has_element?(view, "#incidents-#{incident.id}", "Worker backlog")

    view
    |> form("#incident-form",
      incident: %{
        title: "Database failover",
        severity: "critical",
        summary: "Primary unavailable"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/incidents/#{List.first(Incidents.list_incidents())}")
  end

  test "index exposes idempotent sample action when empty", %{conn: conn} do
    {:ok, view, _html} = live(joined(conn), ~p"/")
    assert has_element?(view, "#create-sample")
    view |> element("#create-sample") |> render_click()
    assert [%{title: "Checkout API 500 spike"}] = Incidents.list_incidents()
  end

  test "show orders timeline and supports annotations and status", %{conn: conn} do
    {:ok, incident} = Incidents.create_sample_incident()
    [first | _] = events = Incidents.list_events(incident)
    {:ok, view, _html} = live(joined(conn), ~p"/incidents/#{incident}")

    assert has_element?(view, "#incident-header", incident.title)
    html = render(view)
    positions = Enum.map(events, fn event -> :binary.match(html, event.message) |> elem(0) end)
    assert positions == Enum.sort(positions)

    view
    |> form("#annotation-form", annotation: %{body: "Watching error rate"})
    |> render_submit()

    assert [%{body: "Watching error rate", event_id: nil, author_name: "Alice"}] =
             Incidents.list_annotations(incident)

    view
    |> form("#event-annotation-form",
      annotation: %{event_id: first.id, body: "Request began here"}
    )
    |> render_submit()

    assert Enum.any?(
             Incidents.list_annotations(incident),
             &(&1.event_id == first.id and &1.body == "Request began here")
           )

    view |> element("#status-resolved") |> render_click()
    assert Incidents.get_incident!(incident.id).status == :resolved
    assert has_element?(view, "#incident-status", "resolved")
  end

  test "connected views receive annotation and status PubSub changes", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "Realtime test"})
    {:ok, view, _html} = live(joined(conn, "Alice"), ~p"/incidents/#{incident}")

    assert {:ok, _} =
             Incidents.create_annotation(incident, %{author_name: "Bob", body: "Remote note"})

    assert has_element?(view, "#annotations", "Remote note")
    assert {:ok, _} = Incidents.update_incident_status(incident, :identified)
    assert has_element?(view, "#incident-status", "identified")
  end

  test "independent joined sessions appear through Presence", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "Presence test"})
    {:ok, alice, _html} = live(joined(conn, "Alice"), ~p"/incidents/#{incident}")
    {:ok, _bob, _html} = live(joined(recycle(conn), "Bob"), ~p"/incidents/#{incident}")

    assert has_element?(alice, "#presence", "Alice")
    assert has_element?(alice, "#presence", "Bob")
  end
end
