# Stand-in for the org agent record (C03).
defmodule OpenmaruWeb.Plugs.ApiAuthTest.FakeAgent do
  @moduledoc false
  defstruct [:id, :ident]
end

defmodule OpenmaruWeb.Plugs.ApiAuthTest.EchoController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    actor = OpenmaruWeb.Plugs.ApiAuthTest.describe(conn.assigns[:current_actor])
    json(conn, %{actor: actor})
  end
end

# No SPEC-07 "M" route exists yet (C06, A01, A02, G03 add them), so these routes stand
# in for one and for a route without the flag.
defmodule OpenmaruWeb.Plugs.ApiAuthTest.Router do
  @moduledoc false
  use Phoenix.Router

  alias OpenmaruWeb.Plugs.ApiAuthTest.EchoController

  pipeline :api do
    plug OpenmaruWeb.Plugs.ApiAuth
    plug OpenmaruWeb.Plugs.CSRF
  end

  pipeline :mandate_ok do
    plug :allow_mandate_tokens
  end

  scope "/" do
    pipe_through [:mandate_ok, :api]
    get "/m", EchoController, :show
    post "/m", EchoController, :show
  end

  scope "/" do
    pipe_through :api
    get "/p", EchoController, :show
  end

  scope "/" do
    pipe_through [:api, :mandate_ok]
    get "/misordered", EchoController, :show
  end

  def allow_mandate_tokens(conn, opts),
    do: OpenmaruWeb.Plugs.ApiAuth.allow_mandate_tokens(conn, opts)
end

defmodule OpenmaruWeb.Plugs.ApiAuthTest do
  use OpenmaruWeb.ConnCase, async: true

  import Ecto.Query

  alias Openmaru.Accounts.{PAT, User}
  alias Openmaru.{ClockMock, Repo, TypeID}
  alias Openmaru.Mandates.TokenVerifierMock
  alias OpenmaruWeb.Plugs.ApiAuthTest.{FakeAgent, Router}

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @day 24 * 3600

  @doc false
  def describe(nil), do: nil
  def describe({:person, %User{id: id}}), do: %{kind: "person", id: id}
  def describe({:agent, %FakeAgent{id: id}, claims}), do: %{kind: "agent", id: id, claims: claims}

  def describe({:person_mandate, %User{id: id}, claims}),
    do: %{kind: "person_mandate", id: id, claims: claims}

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp me(conn), do: get(conn, ~p"/api/v1/me")

  defp test_route(conn, method \\ :get, path) do
    conn = %{conn | method: method |> Atom.to_string() |> String.upcase(), request_path: path}
    conn = %{conn | path_info: String.split(path, "/", trim: true)}
    conn = %{conn | secret_key_base: OpenmaruWeb.Endpoint.config(:secret_key_base)}
    Router.call(conn, Router.init([]))
  end

  defp claims, do: %{"mandate_id" => Ecto.UUID.generate(), "goal_id" => Ecto.UUID.generate()}

  setup do
    stub(ClockMock, :now, fn -> @t0 end)
    :ok
  end

  describe "personal access tokens" do
    test "C02-T02 a Bearer PAT authenticates GET /me", %{conn: conn} do
      user = insert!(:user, handle: "pat_user")
      {:ok, token, _pat} = PAT.create(user, %{"name" => "cli"})

      body = conn |> put_bearer(token) |> me() |> json_response(200)

      assert body["id"] == TypeID.encode("usr", user.id)
      assert body["handle"] == "pat_user"
      # No session cookie is created for a bearer request.
      refute Map.has_key?(
               conn |> put_bearer(token) |> me() |> Map.get(:resp_cookies),
               session_cookie()
             )
    end

    test "C02-T02 a revoked PAT is 401 invalid_token", %{conn: conn} do
      user = insert!(:user)
      {:ok, token, pat} = PAT.create(user, %{"name" => "cli"})
      assert conn |> put_bearer(token) |> me() |> json_response(200)

      :ok = PAT.revoke(user, pat.id)

      conn = conn |> fresh_conn() |> put_bearer(token) |> me()
      assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end

    test "C02-T02 an expired PAT is 401 invalid_token (Clock)", %{conn: conn} do
      user = insert!(:user)
      {:ok, token, _pat} = PAT.create(user, %{"name" => "cli", "ttl_days" => 1})

      at(@day - 1)
      assert conn |> put_bearer(token) |> me() |> json_response(200)

      at(@day)

      assert %{"error" => %{"code" => "invalid_token"}} =
               conn |> fresh_conn() |> put_bearer(token) |> me() |> json_response(401)
    end

    test "C02-T02 an unknown PAT is 401 invalid_token", %{conn: conn} do
      {:ok, token, _pat} = PAT.create(insert!(:user), %{"name" => "cli"})

      forged =
        String.slice(token, 0..-2//1) <> if(String.ends_with?(token, "A"), do: "B", else: "A")

      assert %{"error" => %{"code" => "invalid_token"}} =
               conn |> put_bearer(forged) |> me() |> json_response(401)
    end

    test "C02-T02 a suspended user's PAT is 403 forbidden", %{conn: conn} do
      user = insert!(:user)
      {:ok, token, _pat} = PAT.create(user, %{"name" => "cli"})
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [suspended_at: @t0])

      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> put_bearer(token) |> me() |> json_response(403)
    end

    test "C02-T02 a PAT is refused on session-only routes", %{conn: conn} do
      {:ok, token, _pat} = PAT.create(insert!(:user), %{"name" => "cli"})
      conn = put_bearer(conn, token)

      for {method, path} <- [
            {:get, ~p"/api/v1/auth/csrf"},
            {:post, ~p"/api/v1/auth/logout"},
            {:post, ~p"/api/v1/auth/device/approve"},
            {:post, ~p"/api/v1/auth/passkey/register/options"}
          ] do
        assert %{
                 "error" => %{
                   "code" => "forbidden",
                   "details" => %{"reason" => "session_required"}
                 }
               } =
                 conn
                 |> recycle()
                 |> put_bearer(token)
                 |> dispatch(@endpoint, method, path, %{})
                 |> json_response(403),
               "#{method} #{path}"
      end
    end
  end

  describe "precedence" do
    test "C02-T09 a Bearer header takes precedence over a valid session cookie", %{conn: conn} do
      cookie_user = insert!(:user)
      pat_user = insert!(:user)
      {:ok, token, _pat} = PAT.create(pat_user, %{"name" => "cli"})
      conn = conn |> sign_in(cookie_user) |> put_bearer(token)

      assert conn |> me() |> json_response(200) |> Map.fetch!("id") ==
               TypeID.encode("usr", pat_user.id)
    end

    test "C02-T09 a mutation carrying a bearer and a cookie needs no x-csrf-token", %{conn: conn} do
      cookie_user = insert!(:user)
      pat_user = insert!(:user)
      {:ok, token, _pat} = PAT.create(pat_user, %{"name" => "cli"})

      body =
        conn
        |> sign_in(cookie_user)
        |> put_bearer(token)
        |> patch(~p"/api/v1/me", %{"display_name" => "From the CLI"})
        |> json_response(200)

      assert body["id"] == TypeID.encode("usr", pat_user.id)
      assert Repo.reload!(pat_user).display_name == "From the CLI"
      refute Repo.reload!(cookie_user).display_name == "From the CLI"
    end

    test "C02-T09 an invalid bearer does not fall back to the cookie", %{conn: conn} do
      conn = conn |> sign_in(insert!(:user)) |> put_bearer("om_pat_" <> String.duplicate("A", 43))

      assert %{"error" => %{"code" => "invalid_token"}} = conn |> me() |> json_response(401)
    end

    test "C02-T09 without a bearer the session cookie authenticates", %{conn: conn} do
      user = insert!(:user)

      assert conn |> sign_in(user) |> me() |> json_response(200) |> Map.fetch!("id") ==
               TypeID.encode("usr", user.id)
    end
  end

  describe "mandate tokens" do
    test "C02-T10 on a :mandate_ok route the verified agent is the current actor", %{conn: conn} do
      agent = %FakeAgent{id: Ecto.UUID.generate(), ident: "builder"}
      claims = claims()

      expect(TokenVerifierMock, :verify, fn "om_mt_valid", facts ->
        assert facts == %{operation: :api, time: @t0}
        {:ok, {:agent, agent, claims}}
      end)

      conn = conn |> put_bearer("om_mt_valid") |> test_route("/m")

      assert conn.assigns.current_actor == {:agent, agent, claims}
      refute Map.has_key?(conn.assigns, :current_user)

      assert json_response(conn, 200) == %{
               "actor" => %{"kind" => "agent", "id" => agent.id, "claims" => claims}
             }
    end

    test "C02-T10 on any other route a mandate token is 403 forbidden", %{conn: conn} do
      expect(TokenVerifierMock, :verify, 0, fn _token, _facts -> flunk("not verified") end)

      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> put_bearer("om_mt_valid") |> test_route("/p") |> json_response(403)

      for {method, path} <- [
            {:get, ~p"/api/v1/me"},
            {:patch, ~p"/api/v1/me"},
            {:get, ~p"/api/v1/me/tokens"},
            {:post, ~p"/api/v1/auth/device/code"},
            {:get, ~p"/api/v1/socket-token"}
          ] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 conn
                 |> fresh_conn()
                 |> put_bearer("om_mt_valid")
                 |> dispatch(@endpoint, method, path, %{})
                 |> json_response(403),
               "#{method} #{path}"
      end
    end

    test "C02-T10 a person mandate is a person_mandate actor without current_user", %{
      conn: conn
    } do
      user = insert!(:user)
      claims = claims()

      expect(TokenVerifierMock, :verify, fn "om_mt_person", _facts ->
        {:ok, {:person_mandate, user, claims}}
      end)

      conn = conn |> put_bearer("om_mt_person") |> test_route("/m")

      assert conn.assigns.current_actor == {:person_mandate, user, claims}
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "C02-T10 a refused mandate token is 401 invalid_token with the reason", %{conn: conn} do
      expect(TokenVerifierMock, :verify, fn "om_mt_revoked", _facts -> {:error, :revoked} end)

      conn = conn |> put_bearer("om_mt_revoked") |> test_route("/m")

      assert %{"error" => %{"code" => "invalid_token", "details" => %{"reason" => "revoked"}}} =
               json_response(conn, 401)
    end

    test "C02-T10 until M01 the default verifier refuses every mandate token", %{conn: conn} do
      conn = conn |> put_bearer("om_mt_anything") |> test_route("/m")

      assert %{
               "error" => %{
                 "code" => "invalid_token",
                 "details" => %{"reason" => "not_implemented"}
               }
             } =
               json_response(conn, 401)

      assert Openmaru.Mandates.TokenVerifier.Unimplemented.verify("om_mt_x", %{
               operation: :api,
               time: @t0
             }) == {:error, :not_implemented}
    end

    test "C02-T10 a mutation with a mandate token needs no x-csrf-token, even with a cookie", %{
      conn: conn
    } do
      agent = %FakeAgent{id: Ecto.UUID.generate()}
      expect(TokenVerifierMock, :verify, fn _token, _facts -> {:ok, {:agent, agent, %{}}} end)

      conn =
        conn
        |> sign_in(insert!(:user))
        |> fetch_cookies()
        |> put_bearer("om_mt_valid")
        |> test_route(:post, "/m")

      assert %{"actor" => %{"kind" => "agent"}} = json_response(conn, 200)
    end

    test "C02-T10 :mandate_ok piped after the auth plug raises", %{conn: conn} do
      assert_raise ArgumentError, ~r/mandate_ok/, fn -> test_route(conn, "/misordered") end
    end
  end

  describe "malformed credentials" do
    test "C02-T11 a malformed Authorization header, unknown prefix or empty bearer is 401 invalid_token",
         %{conn: conn} do
      for header <- [
            "Bearer",
            "Bearer ",
            "Bearer  ",
            "Basic dXNlcjpwYXNz",
            "Token om_pat_abc",
            "om_pat_abc",
            "Bearerom_pat_abc",
            "Bearer om_pat_abc extra",
            "Bearer om_xx_abc",
            "Bearer abc",
            "Bearer pat_abc",
            "Bearer om_pat_",
            "Bearer om_mt_",
            "Bearer om_pat_ä",
            ""
          ] do
        conn = conn |> fresh_conn() |> put_req_header("authorization", header) |> me()

        assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401),
               "expected #{inspect(header)} to be rejected"

        assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
      end
    end

    test "C02-T11 the scheme is case-insensitive", %{conn: conn} do
      {:ok, token, _pat} = PAT.create(insert!(:user), %{"name" => "cli"})

      for scheme <- ["bearer", "BEARER", "Bearer"] do
        assert conn
               |> fresh_conn()
               |> put_req_header("authorization", scheme <> " " <> token)
               |> me()
               |> json_response(200)
      end
    end

    test "C02-T11 two Authorization headers are 401 invalid_token", %{conn: conn} do
      {:ok, token, _pat} = PAT.create(insert!(:user), %{"name" => "cli"})
      header = {"authorization", "Bearer " <> token}
      conn = %{conn | req_headers: [header, header | conn.req_headers]}

      assert %{"error" => %{"code" => "invalid_token"}} = conn |> me() |> json_response(401)
    end

    test "C02-T11 a bad credential is refused on public routes too", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_token"}} =
               conn
               |> put_req_header("authorization", "Bearer nope")
               |> post(~p"/api/v1/auth/device/code", %{})
               |> json_response(401)
    end

    test "C02-T11 a bearer is not required on public routes", %{conn: conn} do
      assert conn |> post(~p"/api/v1/auth/device/code", %{}) |> json_response(200)
    end
  end
end
