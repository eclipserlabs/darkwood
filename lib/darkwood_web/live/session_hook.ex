defmodule DarkwoodWeb.SessionHook do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  def on_mount(:require_join, _params, session, socket) do
    with name when is_binary(name) <- session["display_name"],
         true <- String.trim(name) != "" and String.length(name) in 1..80,
         client_id when is_binary(client_id) <- session["client_id"],
         {:ok, _} <- Ecto.UUID.cast(client_id) do
      {:cont, socket |> assign(:display_name, String.trim(name)) |> assign(:client_id, client_id)}
    else
      _ ->
        {:halt, redirect(socket, to: "/join")}
    end
  end
end
