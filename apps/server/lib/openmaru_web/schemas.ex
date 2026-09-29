defmodule OpenmaruWeb.Schemas do
  @moduledoc "Shared OpenAPI schemas."

  alias OpenApiSpex.Schema

  defmodule ErrorResponse do
    @moduledoc "The error envelope (SPEC-07 §2)."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      type: :object,
      required: [:error],
      properties: %{
        error: %Schema{
          type: :object,
          required: [:code, :message, :details],
          properties: %{
            code: %Schema{type: :string, description: "Stable snake_case error code"},
            message: %Schema{type: :string},
            details: %Schema{type: :object, additionalProperties: true}
          }
        }
      }
    })
  end

  defmodule HealthResponse do
    @moduledoc "Result of `GET /healthz`."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      type: :object,
      required: [:status, :db],
      properties: %{
        status: %Schema{type: :string, enum: ["ok", "degraded"]},
        db: %Schema{type: :string, enum: ["ok", "error"]}
      }
    })
  end
end
