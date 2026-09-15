defmodule DarkwoodWeb.JoinController do
  use DarkwoodWeb, :controller

  def new(conn, params) do
    render(conn, :new, return_to: safe_return_to(params["return_to"]), error: nil)
  end

  def create(conn, %{"display_name" => name} = params) do
    name = String.trim(name)

    if String.length(name) in 1..80 do
      conn
      |> put_session(:display_name, name)
      |> put_session(:client_id, Ecto.UUID.generate())
      |> redirect(to: safe_return_to(params["return_to"]) || ~p"/")
    else
      conn
      |> put_status(:unprocessable_entity)
      |> render(:new,
        return_to: safe_return_to(params["return_to"]),
        error: "Display name must be between 1 and 80 characters."
      )
    end
  end

  def create(conn, params), do: create(conn, Map.put(params, "display_name", ""))

  defp safe_return_to(nil), do: nil

  defp safe_return_to(path) when is_binary(path) do
    uri = URI.parse(path)

    if String.valid?(path) and String.starts_with?(path, "/") and
         not String.starts_with?(path, "//") and not String.match?(path, ~r/[\\\x00-\x1F]/) and
         is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo) do
      path
    end
  rescue
    _ -> nil
  end
end
