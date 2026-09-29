defmodule OpenmaruWeb.Router do
  use OpenmaruWeb, :router

  import OpenmaruWeb.Plugs.Session, only: [require_user: 2]

  pipeline :probe do
    plug :accepts, ["json"]
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: OpenmaruWeb.ApiSpec
    plug OpenmaruWeb.Plugs.Session
    plug OpenmaruWeb.Plugs.CSRF
    plug OpenmaruWeb.Plugs.Idempotency
  end

  # OAuth callbacks are browser navigations: answer HTML clients with redirects.
  pipeline :oauth do
    plug :accepts, ["html", "json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: OpenmaruWeb.ApiSpec
    plug OpenmaruWeb.Plugs.Session
  end

  # SPEC-09 §6: auth 10/min/IP. Runs before the session lookup.
  pipeline :auth_rate_limit do
    plug OpenmaruWeb.Plugs.RateLimit, bucket: :auth, limit: 10, scale_ms: 60_000
  end

  pipeline :signed_in do
    plug :require_user
  end

  scope "/", OpenmaruWeb do
    pipe_through :probe

    get "/healthz", HealthController, :show
  end

  scope "/api/v1" do
    pipe_through :api

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:auth_rate_limit, :api]

    post "/auth/passkey/register/options", PasskeyController, :registration_options
    post "/auth/passkey/register", PasskeyController, :register
    post "/auth/passkey/login/options", PasskeyController, :login_options
    post "/auth/passkey/login", PasskeyController, :login
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:auth_rate_limit, :oauth]

    get "/auth/oauth/:provider", OAuthController, :request
    get "/auth/oauth/:provider/callback", OAuthController, :callback
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:api, :signed_in]

    get "/auth/csrf", SessionController, :csrf
    post "/auth/logout", SessionController, :logout
    get "/me", MeController, :show
    patch "/me", MeController, :update
  end
end
