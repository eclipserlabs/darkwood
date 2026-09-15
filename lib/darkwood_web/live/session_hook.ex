defmodule DarkwoodWeb.SessionHook do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  def on_mount(:require_join, _params, session, socket) do
    case {session["display_name"], session["client_id"]} do
      {name, client_id} when is_binary(name) and is_binary(client_id) ->
        {:cont, socket |> assign(:display_name, name) |> assign(:client_id, client_id)}

      _ ->
        {:halt, redirect(socket, to: "/join")}
    end
  end
end
