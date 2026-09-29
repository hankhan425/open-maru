defmodule OpenmaruWeb.HealthController do
  @moduledoc "`GET /healthz`: liveness plus a database check."

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenmaruWeb.Schemas.HealthResponse

  tags(["health"])

  operation(:show,
    summary: "Health check",
    description: "200 when the database answers; 503 `degraded` otherwise.",
    responses: [
      ok: {"Healthy", "application/json", HealthResponse},
      service_unavailable: {"Degraded", "application/json", HealthResponse}
    ]
  )

  @doc false
  def show(conn, _params) do
    case Openmaru.Health.check_db() do
      :ok ->
        json(conn, %{status: "ok", db: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "degraded", db: "error"})
    end
  end
end
