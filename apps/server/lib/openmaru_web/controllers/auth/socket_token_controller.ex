defmodule OpenmaruWeb.Auth.SocketTokenController do
  @moduledoc "`GET /socket-token`: a 5-minute token for the realtime socket (SPEC-07 §3)."

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenmaruWeb.Auth.Schemas
  alias OpenmaruWeb.Schemas.ErrorResponse
  alias OpenmaruWeb.SocketToken

  tags(["auth"])

  operation(:show,
    summary: "Token for the realtime socket",
    description: "Valid for 5 minutes; pass it when connecting to `/socket`.",
    responses: [
      ok: {"The token", "application/json", Schemas.SocketToken},
      unauthorized: {"Not signed in", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def show(conn, _params) do
    json(conn, %{
      token: SocketToken.sign_socket_token(conn.assigns.current_user),
      expires_in: SocketToken.ttl_seconds()
    })
  end
end
