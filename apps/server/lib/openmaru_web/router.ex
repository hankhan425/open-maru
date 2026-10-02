defmodule OpenmaruWeb.Router do
  use OpenmaruWeb, :router

  import OpenmaruWeb.Plugs.ApiAuth,
    only: [
      allow_mandate_tokens: 2,
      require_session: 2,
      require_user: 2,
      session_or_anonymous: 2
    ]

  pipeline :probe do
    plug :accepts, ["json"]
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: OpenmaruWeb.ApiSpec
    plug OpenmaruWeb.Plugs.ApiAuth
    plug OpenmaruWeb.Plugs.CSRF
    plug OpenmaruWeb.Plugs.Idempotency
  end

  # OAuth callbacks are browser navigations: answer HTML clients with redirects.
  pipeline :oauth do
    plug :accepts, ["html", "json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: OpenmaruWeb.ApiSpec
    plug OpenmaruWeb.Plugs.ApiAuth
  end

  # SPEC-07 "M": routes mandate tokens may reach (C06, A01, A02, G03 add them). Pipe
  # through it before :api, e.g. `pipe_through [:mandate_ok, :api]`, and guard the
  # routes with `require_actor/2`. Everywhere else a mandate token is 403 forbidden.
  pipeline :mandate_ok do
    plug :allow_mandate_tokens
  end

  # SPEC-09 §6: auth 10/min/IP (limit in config). Runs before the credential lookup.
  pipeline :auth_rate_limit do
    plug OpenmaruWeb.Plugs.RateLimit, bucket: :auth
  end

  # SPEC-07 auth column. S P: a person by session cookie or PAT.
  pipeline :signed_in do
    plug :require_user
  end

  # S: a session cookie only.
  pipeline :session_only do
    plug :require_session
  end

  # — / S: anonymous or a session cookie, never a bearer credential.
  pipeline :no_bearer do
    plug :session_or_anonymous
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
    pipe_through [:auth_rate_limit, :api, :no_bearer]

    post "/auth/passkey/register/options", PasskeyController, :registration_options
    post "/auth/passkey/register", PasskeyController, :register
    post "/auth/passkey/login/options", PasskeyController, :login_options
    post "/auth/passkey/login", PasskeyController, :login
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:auth_rate_limit, :oauth, :no_bearer]

    get "/auth/oauth/:provider", OAuthController, :request
    get "/auth/oauth/:provider/callback", OAuthController, :callback
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:auth_rate_limit, :api]

    post "/auth/device/code", DeviceController, :code
  end

  # Polled every 5 s for up to 10 minutes, so outside the 10/min auth budget; each
  # device code limits its own polling (slow_down).
  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through :api

    post "/auth/device/token", DeviceController, :token
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:auth_rate_limit, :api, :session_only]

    post "/auth/device/approve", DeviceController, :approve
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:api, :session_only]

    get "/auth/csrf", SessionController, :csrf
    post "/auth/logout", SessionController, :logout
    get "/me/tokens", TokenController, :index
    post "/me/tokens", TokenController, :create
    delete "/me/tokens/:id", TokenController, :delete
  end

  scope "/api/v1", OpenmaruWeb.Auth do
    pipe_through [:api, :signed_in]

    get "/me", MeController, :show
    patch "/me", MeController, :update
    get "/socket-token", SocketTokenController, :show
  end
end
