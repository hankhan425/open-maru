defmodule OpenmaruWeb.ApiSpec do
  @moduledoc """
  The OpenAPI document served at `/api/v1/openapi.json` (SPEC-07 §1). Operations come
  from controllers that declare `open_api_operation/1` (`OpenApiSpex.ControllerSpecs`).
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths}
  alias OpenmaruWeb.Schemas

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "openmaru API",
        version: to_string(Application.spec(:openmaru, :vsn))
      },
      paths: Paths.from_router(OpenmaruWeb.Router),
      components: %Components{
        schemas: %{
          "ErrorResponse" => Schemas.ErrorResponse.schema(),
          "HealthResponse" => Schemas.HealthResponse.schema()
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
