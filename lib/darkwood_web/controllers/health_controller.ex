defmodule DarkwoodWeb.HealthController do
  @moduledoc "Liveness/readiness probe for load balancers and k8s."
  use DarkwoodWeb, :controller

  def show(conn, _params) do
    db =
      try do
        Darkwood.Repo.query!("SELECT 1", [], timeout: 2_000)
        :ok
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end

    depth =
      try do
        Darkwood.Ingestion.Producer.depth()
      rescue
        _ -> :unknown
      catch
        _, _ -> :unknown
      end

    case db do
      :ok ->
        json(conn, %{status: "ok", db: "ok", ingestion: format_depth(depth)})

      :error ->
        conn |> put_status(:service_unavailable) |> json(%{status: "degraded", db: "error"})
    end
  end

  defp format_depth(:unknown), do: "unknown"
  defp format_depth(%{buffered: b}), do: %{buffered: b}
  defp format_depth(_), do: "unknown"
end
