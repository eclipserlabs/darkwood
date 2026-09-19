defmodule DarkwoodWeb.HealthController do
  @moduledoc "Liveness/readiness probe for load balancers and k8s."
  use DarkwoodWeb, :controller

  def show(conn, _params) do
    case check_db() do
      :ok ->
        json(conn, %{status: "ok", db: "ok"})

      :error ->
        conn |> put_status(:service_unavailable) |> json(%{status: "degraded", db: "error"})
    end
  end

  defp check_db do
    Darkwood.Repo.query!("SELECT 1", [], timeout: 2_000)
    :ok
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
