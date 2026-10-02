defmodule OpenmaruWeb.Plugs.Session do
  @moduledoc """
  The web session cookie `_om_session` (SPEC-09 §1): signing in, and setting or
  clearing the cookie. `OpenmaruWeb.Plugs.ApiAuth` resolves the cookie on each request
  (its cookie branch), and its `require_*` plugs guard routes.

  The cookie is `HttpOnly; Secure; SameSite=Lax` on path `/`.
  """

  import Plug.Conn

  alias Openmaru.Accounts
  alias Openmaru.Accounts.{User, UserSession}

  @cookie "_om_session"

  @doc "The session cookie's name."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie

  @doc """
  Starts a session for `user` and sets its cookie. A session the request already
  carried (signing in as someone else) is revoked.
  """
  @spec sign_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def sign_in(conn, %User{} = user) do
    case conn.assigns[:current_session] do
      %UserSession{} = previous -> Accounts.revoke_session(previous)
      nil -> :ok
    end

    {:ok, token, session} = Accounts.create_session(user)

    conn
    |> assign(:current_user, user)
    |> assign(:current_session, session)
    |> assign(:current_actor, {:person, user})
    |> put_session_cookie(token, session)
  end

  @doc "Client details for the audit log: remote IP and user agent."
  @spec client_meta(Plug.Conn.t()) :: Accounts.meta()
  def client_meta(conn) do
    %{ip: conn.remote_ip, user_agent: conn |> get_req_header("user-agent") |> List.first()}
  end

  @doc "Sets the session cookie for `token`, expiring with `session`."
  @spec put_session_cookie(Plug.Conn.t(), String.t(), UserSession.t()) :: Plug.Conn.t()
  def put_session_cookie(conn, token, %UserSession{expires_at: expires_at}) do
    max_age = max(DateTime.diff(expires_at, Openmaru.Clock.now()), 0)

    put_resp_cookie(conn, @cookie, token,
      http_only: true,
      secure: true,
      same_site: "Lax",
      path: "/",
      max_age: max_age
    )
  end

  @doc "Clears the session cookie."
  @spec delete_session_cookie(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_session_cookie(conn) do
    delete_resp_cookie(conn, @cookie, http_only: true, secure: true, same_site: "Lax", path: "/")
  end
end
