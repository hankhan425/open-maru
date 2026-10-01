defmodule OpenmaruWeb.Auth.PasskeyController do
  @moduledoc """
  Passkey registration and sign-in (SPEC-07 §1 "Auth & account"). Registering while
  signed in adds a passkey to the current user; otherwise it creates a user and a
  session.
  """

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Openmaru.Accounts
  alias OpenmaruWeb.Auth.{Schemas, UserJSON}
  alias OpenmaruWeb.Plugs.Session
  alias OpenmaruWeb.Schemas.ErrorResponse

  action_fallback OpenmaruWeb.FallbackController

  tags(["auth"])

  operation(:registration_options,
    summary: "Start a passkey registration",
    responses: [ok: {"Creation options", "application/json", Schemas.PasskeyOptions}]
  )

  @doc false
  def registration_options(conn, _params) do
    {:ok, ceremony} = Accounts.begin_passkey_registration(conn.assigns[:current_user])
    json(conn, ceremony)
  end

  operation(:register,
    summary: "Finish a passkey registration",
    description: "Creates a user and a session (signed out) or adds a passkey (signed in).",
    request_body: {"Attestation", "application/json", Schemas.PasskeyCredential},
    responses: [
      created: {"The user", "application/json", Schemas.User},
      bad_request:
        {"Invalid, used or expired challenge or credential", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def register(conn, params) do
    current_user = conn.assigns[:current_user]

    with {:ok, user} <-
           Accounts.finish_passkey_registration(current_user, params, Session.client_meta(conn)) do
      conn = if current_user, do: conn, else: Session.sign_in(conn, user)
      conn |> put_status(:created) |> json(UserJSON.user(user, user))
    end
  end

  operation(:login_options,
    summary: "Start a passkey sign-in",
    responses: [ok: {"Request options", "application/json", Schemas.PasskeyOptions}]
  )

  @doc false
  def login_options(conn, _params) do
    {:ok, ceremony} = Accounts.begin_passkey_login()
    json(conn, ceremony)
  end

  operation(:login,
    summary: "Finish a passkey sign-in",
    request_body: {"Assertion", "application/json", Schemas.PasskeyCredential},
    responses: [
      ok: {"The user; sets the session cookie", "application/json", Schemas.User},
      bad_request: {"Invalid, used or expired challenge", "application/json", ErrorResponse},
      unauthorized: {"Assertion rejected", "application/json", ErrorResponse},
      forbidden: {"User suspended", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def login(conn, params) do
    with {:ok, user} <- Accounts.finish_passkey_login(params, Session.client_meta(conn)) do
      conn |> Session.sign_in(user) |> json(UserJSON.user(user, user))
    end
  end
end
