defmodule OpenmaruWeb.Auth.SessionController do
  @moduledoc "The current web session: its CSRF token and logout (SPEC-07 §1, SPEC-09 §1)."

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Openmaru.Accounts
  alias OpenmaruWeb.Auth.Schemas
  alias OpenmaruWeb.Plugs.{CSRF, Session}
  alias OpenmaruWeb.Schemas.ErrorResponse

  tags(["auth"])

  operation(:csrf,
    summary: "CSRF token for the session",
    responses: [
      ok: {"The token", "application/json", Schemas.CsrfToken},
      unauthorized: {"Not signed in", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def csrf(conn, _params) do
    json(conn, %{csrf_token: CSRF.token(conn, conn.assigns.current_session)})
  end

  operation(:logout,
    summary: "Sign out",
    description: "Revokes the session and clears its cookie. Requires `x-csrf-token`.",
    responses: [
      no_content: "Signed out",
      unauthorized: {"Not signed in", "application/json", ErrorResponse},
      forbidden: {"Missing or invalid CSRF token", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def logout(conn, _params) do
    :ok = Accounts.revoke_session(conn.assigns.current_session)

    conn
    |> Session.delete_session_cookie()
    |> send_resp(:no_content, "")
  end
end
