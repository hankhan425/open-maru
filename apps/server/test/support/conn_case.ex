defmodule OpenmaruWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use OpenmaruWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.

  Each test's `conn` comes from its own client IP (`10.x.y.z`), which recycled
  connections keep, so per-IP rate limits (auth: 10/min) never leak between tests.
  Use `fresh_conn/1` for a cookie-less connection from the same IP.
  """

  use ExUnit.CaseTemplate

  import Phoenix.ConnTest
  import Plug.Conn

  alias Openmaru.Test.FakeAuthenticator

  @endpoint OpenmaruWeb.Endpoint
  @session_cookie "_om_session"

  using do
    quote do
      # The default endpoint for testing
      @endpoint OpenmaruWeb.Endpoint

      use OpenmaruWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import OpenmaruWeb.ConnCase
      import Openmaru.Factory
      import Openmaru.Fixtures
      import Mox
    end
  end

  setup tags do
    Openmaru.DataCase.setup_sandbox(tags)
    Openmaru.Mocks.stub_defaults()
    Mox.verify_on_exit!()
    {:ok, conn: fresh_conn(unique_ip())}
  end

  @doc "A client IP no other test uses."
  @spec unique_ip() :: :inet.ip4_address()
  def unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  @doc "A connection without cookies or headers from `conn`'s client IP (or the given IP)."
  @spec fresh_conn(Plug.Conn.t() | :inet.ip_address()) :: Plug.Conn.t()
  def fresh_conn(%Plug.Conn{remote_ip: ip}), do: fresh_conn(ip)
  def fresh_conn(ip) when is_tuple(ip), do: %{build_conn() | remote_ip: ip}

  @doc "The name of the web session cookie."
  @spec session_cookie() :: String.t()
  def session_cookie, do: @session_cookie

  @doc """
  Signs `user` in by creating a session directly and putting its cookie on `conn`.
  Returns the connection and the session token.
  """
  @spec sign_in(Plug.Conn.t(), struct()) :: Plug.Conn.t()
  def sign_in(conn, user) do
    {:ok, token, _session} = Openmaru.Accounts.create_session(user)
    put_req_cookie(conn, @session_cookie, token)
  end

  @doc "Fetches the CSRF token for `conn`'s session cookie."
  @spec csrf_token(Plug.Conn.t()) :: String.t()
  def csrf_token(conn) do
    conn
    |> recycle()
    |> get("/api/v1/auth/csrf")
    |> json_response(200)
    |> Map.fetch!("csrf_token")
  end

  @doc """
  A recycled `conn` (same cookies and IP) carrying its session's CSRF token in
  `x-csrf-token`. `recycle/1` drops the header again, so call this before every
  mutating request.
  """
  @spec with_csrf(Plug.Conn.t()) :: Plug.Conn.t()
  def with_csrf(conn) do
    token = csrf_token(conn)
    conn |> recycle() |> put_req_header("x-csrf-token", token)
  end

  @doc """
  Registers a new user with a fresh `FakeAuthenticator` through the passkey API.
  Returns `%{conn: conn, user: user_json, authenticator: auth}`; `conn` carries the new
  session cookie.
  """
  @spec register_passkey(Plug.Conn.t()) :: %{
          conn: Plug.Conn.t(),
          user: map(),
          authenticator: FakeAuthenticator.t()
        }
  def register_passkey(conn) do
    conn = post(conn, "/api/v1/auth/passkey/register/options", %{})
    options = json_response(conn, 200)

    {credential, auth} = FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

    conn =
      conn
      |> recycle()
      |> post("/api/v1/auth/passkey/register", %{
        "challenge_id" => options["challenge_id"],
        "credential" => credential
      })

    %{conn: conn, user: json_response(conn, 201), authenticator: auth}
  end

  @doc """
  Signs in with `auth` through the passkey API from a cookie-less connection.
  `opts` go to `FakeAuthenticator.assert/3`, except `:headers` (`[{name, value}]`),
  which are sent with both requests. Returns the response connection and the
  authenticator with its new sign count.
  """
  @spec passkey_login(Plug.Conn.t(), FakeAuthenticator.t(), keyword()) ::
          {Plug.Conn.t(), FakeAuthenticator.t()}
  def passkey_login(conn, auth, opts \\ []) do
    {headers, opts} = Keyword.pop(opts, :headers, [])
    put_headers = &Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end)

    conn =
      conn |> fresh_conn() |> put_headers.() |> post("/api/v1/auth/passkey/login/options", %{})

    options = json_response(conn, 200)
    {assertion, auth} = FakeAuthenticator.assert(auth, options["public_key"], opts)

    conn =
      conn
      |> recycle()
      |> put_headers.()
      |> post("/api/v1/auth/passkey/login", %{
        "challenge_id" => options["challenge_id"],
        "credential" => assertion
      })

    {conn, auth}
  end

  @doc "Decodes an API id (`usr_…`) to its UUID."
  @spec uuid!(String.t(), String.t()) :: Ecto.UUID.t()
  def uuid!(id, prefix) do
    {:ok, uuid} = Openmaru.TypeID.decode(id, prefix)
    uuid
  end
end
