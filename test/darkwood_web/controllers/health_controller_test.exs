defmodule DarkwoodWeb.HealthControllerTest do
  use DarkwoodWeb.ConnCase, async: true

  test "GET /health returns ok with db check", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert %{"status" => "ok", "db" => "ok"} = json_response(conn, 200)
  end
end
