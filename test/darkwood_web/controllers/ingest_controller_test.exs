defmodule DarkwoodWeb.IngestControllerTest do
  use DarkwoodWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Darkwood.Incidents

  test "POST /api/v1/incidents/:id/ingest returns 202 and processes async", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API ingest test"})

    conn =
      post(conn, ~p"/api/v1/incidents/#{incident.id}/ingest", %{
        kind: "error",
        level: "error",
        message: "external boom",
        metadata: %{service: "worker"}
      })

    assert json_response(conn, 202)["status"] == "accepted"

    assert_eventually(fn ->
      length(Incidents.list_events(incident.id)) >= 1
    end)

    assert [%{message: "external boom"}] = Incidents.list_events(incident.id)
  end

  test "invalid payload returns 422", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API invalid test"})

    conn =
      post(conn, ~p"/api/v1/incidents/#{incident.id}/ingest", %{
        kind: "nope",
        level: "error",
        message: "x"
      })

    assert json_response(conn, 422)
  end

  test "unknown incident returns 404", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/incidents/999999/ingest", %{
        kind: "error",
        level: "error",
        message: "ghost"
      })

    assert json_response(conn, 404)
  end

  test "high-volume identical payloads aggregate and LiveView stays responsive", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "Flood API test"})
    payload = %{kind: "error", level: "error", message: "flood", metadata: %{}}

    for _ <- 1..100 do
      post(recycle(conn), ~p"/api/v1/incidents/#{incident.id}/ingest", payload)
    end

    assert_eventually(
      fn ->
        events = Incidents.list_events(incident.id)
        events != [] and hd(events).metadata["count"] != nil
      end,
      10_000
    )

    events = Incidents.list_events(incident.id)
    assert length(events) in 1..5

    joined = init_test_session(conn, %{"display_name" => "Alice", "client_id" => Ecto.UUID.generate()})
    {:ok, view, _html} = live(joined, ~p"/incidents/#{incident}")
    assert has_element?(view, "#event-timeline")
    assert has_element?(view, "#annotations")
  end

  defp assert_eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true ->
        Process.sleep(50)
        poll(fun, deadline)
    end
  end
end
