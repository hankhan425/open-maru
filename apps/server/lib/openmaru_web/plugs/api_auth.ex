defmodule OpenmaruWeb.Plugs.ApiAuth do
  @moduledoc """
  Resolves the request's credential into `conn.assigns.current_actor` (SPEC-07 §1,
  SPEC-09 §1). An `Authorization` header takes precedence over the session cookie: when
  the header is present the cookie is not read at all.

    * `Bearer om_pat_…` — a personal access token (`Openmaru.Accounts.PAT.verify/1`).
      Assigns `current_actor: {:person, user}`, `current_user` and `current_pat`.
    * `Bearer om_mt_…` — a mandate token, accepted only on routes piped through
      `:mandate_ok` (see `allow_mandate_tokens/2`) and verified by
      `Openmaru.Mandates.TokenVerifier`. Assigns `current_actor`
      `{:agent, agent, claims}` or `{:person_mandate, user, claims}`, and not
      `current_user`: a mandate token acts within its mandate, never as the person.
      On any other route it is 403 `forbidden` (`details.reason`
      `mandate_token_not_allowed`), before verification.
    * No header — the `_om_session` cookie (`Openmaru.Accounts.get_session_user/1`).
      Assigns `current_actor: {:person, user}`, `current_user` and `current_session`.
      When the lookup slides the expiry, the cookie is re-sent with a fresh 30-day
      `max-age`; an unknown, expired or revoked cookie is cleared. A suspended user's
      session leaves the request anonymous with `:auth_error` set, which the `require_*`
      plugs return (403).

  Only the cookie branch assigns `current_session`, so `OpenmaruWeb.Plugs.CSRF` checks
  exactly the cookie-authenticated requests: a mutation whose bearer header wins needs
  no `x-csrf-token`, even when it also carries a cookie.

  A header that is not a single `Bearer <token>` (another scheme, an empty token,
  several headers), an unknown token prefix, or a token that fails verification halts
  with 401 `invalid_token` and `www-authenticate: Bearer error="invalid_token"`, on
  every route including public ones. A suspended user's PAT halts with 403.

  Routes state who may call them with the function plugs below, which run after this
  one (SPEC-07 auth column):

    * `require_session/2` — S
    * `require_user/2` — S P
    * `require_actor/2` — S P M
    * `session_or_anonymous/2` — — / S (signing in, linking an identity)
  """

  @behaviour Plug

  import Plug.Conn

  alias Openmaru.{Accounts, Clock, Error}
  alias Openmaru.Accounts.{PAT, User, UserSession}
  alias Openmaru.Mandates.TokenVerifier
  alias OpenmaruWeb.FallbackController
  alias OpenmaruWeb.Plugs.Session

  # RFC 6750 §2.1: "Bearer" 1*SP b64token, the scheme case-insensitive.
  @bearer ~r/\Abearer +([A-Za-z0-9\-._~+\/]+=*) *\z/i
  @pat_prefix "om_pat_"
  @mandate_prefix "om_mt_"
  @mandate_ok :openmaru_mandate_ok
  @resolved :openmaru_api_auth

  @typedoc "Who is making the request."
  @type actor :: {:person, User.t()} | TokenVerifier.actor()

  @impl Plug
  def init(opts), do: Keyword.validate!(opts, operation: :api)

  @impl Plug
  def call(conn, opts) do
    conn = put_private(conn, @resolved, true)

    case get_req_header(conn, "authorization") do
      [] -> load_session(conn)
      [header] -> load_bearer(conn, header, opts)
      _several -> reject(conn, invalid_token("malformed"))
    end
  end

  ## Bearer credentials

  defp load_bearer(conn, header, opts) do
    case Regex.run(@bearer, header, capture: :all_but_first) do
      [token] -> load_token(conn, token, opts)
      nil -> reject(conn, invalid_token("malformed"))
    end
  end

  defp load_token(conn, @pat_prefix <> rest = token, _opts) when rest != "" do
    case PAT.verify(token) do
      {:ok, user, pat} ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_pat, pat)
        |> assign(:current_actor, {:person, user})

      {:error, %Error{} = error} ->
        reject(conn, error)
    end
  end

  defp load_token(conn, @mandate_prefix <> rest = token, opts) when rest != "" do
    if conn.private[@mandate_ok] do
      verify_mandate_token(conn, token, opts)
    else
      reject(conn, mandate_token_not_allowed())
    end
  end

  defp load_token(conn, _token, _opts), do: reject(conn, invalid_token("malformed"))

  defp verify_mandate_token(conn, token, opts) do
    facts = %{operation: Keyword.fetch!(opts, :operation), time: Clock.now()}

    case TokenVerifier.verify(token, facts) do
      {:ok, actor} ->
        assign(conn, :current_actor, actor)

      {:error, reason} ->
        reject(conn, invalid_token(Atom.to_string(reason), "Invalid mandate token"))
    end
  end

  ## Session cookie

  defp load_session(conn) do
    conn = fetch_cookies(conn)

    case conn.cookies[Session.cookie_name()] do
      nil -> conn
      token -> load_session(conn, token)
    end
  end

  defp load_session(conn, token) do
    case Accounts.get_session_user(token) do
      {:ok, user, session} ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_session, session)
        |> assign(:current_actor, {:person, user})
        |> refresh_cookie(token, session)

      {:error, %Error{code: :unauthenticated}} ->
        Session.delete_session_cookie(conn)

      {:error, %Error{} = error} ->
        assign(conn, :auth_error, error)
    end
  end

  defp refresh_cookie(conn, token, %UserSession{extended: true} = session),
    do: Session.put_session_cookie(conn, token, session)

  defp refresh_cookie(conn, _token, _session), do: conn

  ## Route requirements

  @doc """
  Pipeline plug for SPEC-07 **M** routes: lets mandate tokens through `call/2`. Pipe
  through it *before* the pipeline that runs `OpenmaruWeb.Plugs.ApiAuth`; afterwards it
  raises, since the credential was already resolved.
  """
  @spec allow_mandate_tokens(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def allow_mandate_tokens(conn, _opts) do
    if conn.private[@resolved] do
      raise ArgumentError,
            "pipe_through :mandate_ok before the pipeline that runs OpenmaruWeb.Plugs.ApiAuth"
    end

    put_private(conn, @mandate_ok, true)
  end

  @doc "S routes: a session cookie. Anonymous → 401; a bearer credential → 403 (`session_required`)."
  @spec require_session(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_session(%Plug.Conn{assigns: %{current_session: %UserSession{}}} = conn, _opts),
    do: conn

  def require_session(conn, _opts), do: refuse(conn, session_required())

  @doc "S P routes: a person, by session or PAT. Anonymous → 401; a mandate token → 403."
  @spec require_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_user(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _opts), do: conn
  def require_user(conn, _opts), do: refuse(conn, mandate_token_not_allowed())

  @doc "S P M routes (with `:mandate_ok`): any actor. Anonymous → 401."
  @spec require_actor(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_actor(%Plug.Conn{assigns: %{current_actor: _actor}} = conn, _opts), do: conn
  def require_actor(conn, _opts), do: refuse(conn, nil)

  @doc """
  — / S routes (passkey ceremonies, OAuth): anonymous or a session cookie. A bearer
  credential → 403 (`session_required`), so a leaked PAT cannot add a passkey or link
  an identity to its account.
  """
  @spec session_or_anonymous(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def session_or_anonymous(%Plug.Conn{assigns: %{current_session: %UserSession{}}} = conn, _opts),
    do: conn

  def session_or_anonymous(%Plug.Conn{assigns: %{current_actor: _actor}} = conn, _opts),
    do: conn |> FallbackController.call({:error, session_required()}) |> halt()

  def session_or_anonymous(conn, _opts), do: conn

  # An actor of the wrong kind gets `wrong_kind`; nobody gets 401 (or the session's
  # `:auth_error`, e.g. a suspended user).
  defp refuse(%Plug.Conn{assigns: %{current_actor: _actor}} = conn, %Error{} = wrong_kind),
    do: conn |> FallbackController.call({:error, wrong_kind}) |> halt()

  defp refuse(conn, _wrong_kind) do
    error = conn.assigns[:auth_error] || Error.new(:unauthenticated, "Not signed in")
    conn |> FallbackController.call({:error, error}) |> halt()
  end

  ## Errors

  defp reject(conn, %Error{code: :invalid_token} = error) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
    |> FallbackController.call({:error, error})
    |> halt()
  end

  defp reject(conn, %Error{} = error) do
    conn |> FallbackController.call({:error, error}) |> halt()
  end

  defp invalid_token(reason, message \\ "Invalid or malformed bearer token"),
    do: Error.new(:invalid_token, message, %{reason: reason})

  defp mandate_token_not_allowed do
    Error.new(:forbidden, "Mandate tokens cannot be used on this route", %{
      reason: "mandate_token_not_allowed"
    })
  end

  defp session_required do
    Error.new(:forbidden, "This route needs a signed-in web session", %{
      reason: "session_required"
    })
  end
end
