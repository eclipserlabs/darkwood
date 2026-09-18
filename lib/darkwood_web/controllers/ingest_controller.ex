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
    with :ok <- check_auth(conn),
         :ok <- check_rate_limit(conn) do
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
              case Pipeline.push(incident_id, attrs) do
                :ok ->
                  conn
                  |> put_status(:accepted)
                  |> json(%{status: "accepted", incident_id: incident_id})

                {:error, :overloaded} ->
                  conn
                  |> put_resp_header("retry-after", "1")
                  |> put_status(:too_many_requests)
                  |> json(%{errors: %{detail: "Ingestion overloaded, retry shortly"}})
              end

            {:error, detail} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: %{detail: detail}})
          end
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{errors: %{detail: "Invalid API key"}})

      {:error, :throttled} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "Rate limit exceeded"}})
    end
  end

  defp check_auth(conn) do
    case Application.get_env(:darkwood, :ingest_api_key) do
      nil -> :ok
      "" -> :ok
      expected -> if valid_key?(conn, expected), do: :ok, else: {:error, :unauthorized}
    end
  end

  defp valid_key?(conn, expected) do
    provided =
      conn |> get_req_header("x-api-key") |> List.first() ||
        bearer_token(conn) || conn.params["api_key"]

    is_binary(provided) and Plug.Crypto.secure_compare(provided, expected)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp check_rate_limit(conn) do
    ip = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    Darkwood.Ingestion.RateLimiter.check(ip)
  rescue
    _ -> :ok
  end

  defp validate(%{"kind" => kind, "level" => level, "message" => message, "metadata" => metadata} = attrs) do
    cond do
      is_nil(message) or (is_binary(message) and String.trim(message) == "") ->
        {:error, "message can't be blank"}

      is_binary(message) and String.length(message) > 5000 ->
        {:error, "message is too long"}

      to_string(kind || "") not in @kinds ->
        {:error, "kind is invalid"}

      to_string(level || "") not in @levels ->
        {:error, "level is invalid"}

      not is_map(metadata) ->
        {:error, "metadata is invalid"}

      map_size(metadata) > 50 ->
        {:error, "metadata has too many keys"}

      (attrs["fingerprint"] || "") != "" and String.length(to_string(attrs["fingerprint"] || "")) > 128 ->
        {:error, "fingerprint is too long"}

      true ->
        :ok
    end
  end
end
