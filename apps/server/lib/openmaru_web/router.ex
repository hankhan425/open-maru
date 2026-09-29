defmodule OpenmaruWeb.Router do
  use OpenmaruWeb, :router

  pipeline :probe do
    plug :accepts, ["json"]
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: OpenmaruWeb.ApiSpec
    plug OpenmaruWeb.Plugs.Idempotency
  end

  scope "/", OpenmaruWeb do
    pipe_through :probe

    get "/healthz", HealthController, :show
  end

  scope "/api/v1" do
    pipe_through :api

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end
end
