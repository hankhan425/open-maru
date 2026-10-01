defmodule OpenmaruWeb.Plugs.CSRF do
  @moduledoc """
  CSRF protection for cookie-authenticated mutations (SPEC-09 §1, CONVENTIONS §5).

  A `POST`, `PUT`, `PATCH` or `DELETE` that carries a valid session
  (`conn.assigns.current_session`, set by `OpenmaruWeb.Plugs.Session`) must send the
  session's token in `x-csrf-token`, or it fails with 403 `forbidden`. Requests without
  a session cookie (anonymous, or bearer-authenticated) are not checked.

  The token is an HMAC of the session's token hash under a key derived from the
  endpoint's `secret_key_base`: stable for the session's lifetime, different for every
  session, and never stored. Clients fetch it from `GET /api/v1/auth/csrf`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Openmaru.Accounts.UserSession
  alias Openmaru.Error
  alias OpenmaruWeb.FallbackController
  alias Plug.Crypto.KeyGenerator

  @header "x-csrf-token"
  @mutations ~w(POST PUT PATCH DELETE)
  @salt "openmaru csrf v1"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(
        %Plug.Conn{method: method, assigns: %{current_session: %UserSession{} = session}} = conn,
        _opts
      )
      when method in @mutations do
    expected = token(conn, session)

    case get_req_header(conn, @header) do
      [given | _] when byte_size(given) == byte_size(expected) ->
        if Plug.Crypto.secure_compare(given, expected), do: conn, else: reject(conn)

      _ ->
        reject(conn)
    end
  end

  def call(conn, _opts), do: conn

  @doc "The CSRF token for `session`."
  @spec token(Plug.Conn.t(), UserSession.t()) :: String.t()
  def token(conn, %UserSession{token_hash: token_hash}) do
    key = KeyGenerator.generate(conn.secret_key_base, @salt, cache: Plug.Crypto.Keys)

    :hmac
    |> :crypto.mac(:sha256, key, token_hash)
    |> Base.url_encode64(padding: false)
  end

  defp reject(conn) do
    error = Error.new(:forbidden, "Missing or invalid x-csrf-token", %{reason: "csrf"})
    conn |> FallbackController.call({:error, error}) |> halt()
  end
end
