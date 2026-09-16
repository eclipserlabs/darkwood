defmodule DarkwoodWeb.IngestController do
  @moduledoc """
  Async ingestion API for external log/error payloads.

  POST /api/v1/incidents/:id/ingest
  Accepts JSON: %{kind, level, message, metadata?, fingerprint?, occurred_at?}
  Pushes into the Broadway pipeline and returns 202 immediately.
  """
  use DarkwoodWeb, :controller

  alias Darkwood.Incidents.Incident
  alias Darkwood.Ingestion.Pipeline
  alias Darkwood.Repo

  @kinds ~w(request query http log error)
  @levels ~w(info warning error)

  def create(conn, %{"id" => id} = params) do
    case Repo.get(Incident, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Incident not found"}})

      %Incident{id: incident_id} ->
        attrs = %{
          "kind" => params["kind"],
          "level" => params["level"],
          "message" => params["message"],
          "metadata" => params["metadata"] || %{},
          "fingerprint" => params["fingerprint"],
          "occurred_at" => params["occurred_at"]
        }

        case validate(attrs) do
          :ok ->
            :ok = Pipeline.push(incident_id, attrs)

            conn
            |> put_status(:accepted)
            |> json(%{status: "accepted", incident_id: incident_id})

          {:error, detail} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: %{detail: detail}})
        end
    end
  end

  defp validate(%{"kind" => kind, "level" => level, "message" => message, "metadata" => metadata}) do
    cond do
      is_nil(message) or (is_binary(message) and String.trim(message) == "") ->
        {:error, "message can't be blank"}

      to_string(kind || "") not in @kinds ->
        {:error, "kind is invalid"}

      to_string(level || "") not in @levels ->
        {:error, "level is invalid"}

      not is_map(metadata) ->
        {:error, "metadata is invalid"}

      true ->
        :ok
    end
  end
end
