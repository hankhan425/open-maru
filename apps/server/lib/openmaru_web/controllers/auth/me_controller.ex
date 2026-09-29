defmodule OpenmaruWeb.Auth.MeController do
  @moduledoc "The signed-in user (SPEC-07 §1): `GET /me` and `PATCH /me` (handle, display name)."

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Openmaru.Accounts
  alias OpenmaruWeb.Auth.{Schemas, UserJSON}
  alias OpenmaruWeb.Schemas.ErrorResponse

  action_fallback OpenmaruWeb.FallbackController

  tags(["account"])

  operation(:show,
    summary: "The signed-in user",
    responses: [
      ok: {"The user", "application/json", Schemas.User},
      unauthorized: {"Not signed in", "application/json", ErrorResponse},
      forbidden: {"User suspended", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def show(conn, _params) do
    user = conn.assigns.current_user
    json(conn, UserJSON.user(user, user))
  end

  operation(:update,
    summary: "Set the handle (once) or the display name",
    request_body: {"Changes", "application/json", Schemas.UpdateMe},
    responses: [
      ok: {"The user", "application/json", Schemas.User},
      bad_request:
        {"Handle already set (`details.reason: handle_immutable`)", "application/json",
         ErrorResponse},
      conflict: {"handle_taken", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid or reserved handle, or display name too long", "application/json",
         ErrorResponse}
    ]
  )

  @doc false
  def update(conn, params) do
    with {:ok, user} <- Accounts.update_profile(conn.assigns.current_user, params) do
      json(conn, UserJSON.user(user, user))
    end
  end
end
