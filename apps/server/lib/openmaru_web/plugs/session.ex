defmodule OpenmaruWeb.Plugs.Session do
  @moduledoc """
  Web sessions from the `_om_session` cookie (SPEC-09 §1).

  `call/2` resolves the cookie with `Openmaru.Accounts.get_session_user/1` and assigns
  `:current_user`, `:current_session` and `:current_actor` (`{:person, user}`). When the
  lookup slides the expiry, the cookie is re-sent with a fresh 30-day `max-age`. An
  unknown, expired or revoked cookie is cleared; a suspended user's session leaves the
  request anonymous with `:auth_error` set, which `require_user/2` returns (403).

  The cookie is `HttpOnly; Secure; SameSite=Lax` on path `/`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Openmaru.{Accounts, Error}
  alias Openmaru.Accounts.{User, UserSession}
  alias OpenmaruWeb.FallbackController

  @cookie "_om_session"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    case conn.cookies[@cookie] do
      nil -> conn
      token -> load(conn, token)
    end
  end

  defp load(conn, token) do
    case Accounts.get_session_user(token) do
      {:ok, user, session} ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_session, session)
        |> assign(:current_actor, {:person, user})
        |> refresh_cookie(token, session)

      {:error, %Error{code: :unauthenticated}} ->
        delete_session_cookie(conn)

      {:error, %Error{} = error} ->
        assign(conn, :auth_error, error)
    end
  end

  defp refresh_cookie(conn, token, %UserSession{extended: true} = session),
    do: put_session_cookie(conn, token, session)

  defp refresh_cookie(conn, _token, _session), do: conn

  @doc "Function plug: halts with 401 `unauthenticated` (or `:auth_error`) unless signed in."
  @spec require_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_user(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _opts), do: conn

  def require_user(conn, _opts) do
    error = conn.assigns[:auth_error] || Error.new(:unauthenticated, "Not signed in")
    conn |> FallbackController.call({:error, error}) |> halt()
  end

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
