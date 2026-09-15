defmodule DarkwoodWeb.JoinControllerTest do
  use DarkwoodWeb.ConnCase, async: true

  test "GET /join renders the form", %{conn: conn} do
    conn = get(conn, ~p"/join")
    assert html_response(conn, 200) =~ "join-form"
  end

  test "valid POST stores name and generated client ID", %{conn: conn} do
    conn = post(conn, ~p"/join", %{display_name: " Alice "})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :display_name) == "Alice"
    assert {:ok, _} = Ecto.UUID.cast(get_session(conn, :client_id))
  end

  test "invalid display name is rejected", %{conn: conn} do
    conn = post(conn, ~p"/join", %{display_name: String.duplicate("a", 81)})
    assert html_response(conn, 422) =~ "Display name must be"
    refute get_session(conn, :display_name)
  end

  test "local return_to is accepted", %{conn: conn} do
    conn = post(conn, ~p"/join", %{display_name: "Bob", return_to: "/incidents/42?focus=events"})
    assert redirected_to(conn) == "/incidents/42?focus=events"
  end

  test "external and protocol-relative return URLs are rejected", %{conn: conn} do
    for return_to <- ["https://example.com/steal", "//example.com/steal", "not/a/path"] do
      response = post(recycle(conn), ~p"/join", %{display_name: "Eve", return_to: return_to})
      assert redirected_to(response) == ~p"/"
    end
  end
end
