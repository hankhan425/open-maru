defmodule OpenmaruWeb.Auth.OAuthControllerTest do
  # Points the GitHub provider at a Bypass server through the application env.
  use OpenmaruWeb.ConnCase, async: false

  import Ecto.Query

  alias Openmaru.Accounts.{OAuthIdentity, User}
  alias Openmaru.{ClockMock, Repo}

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @web_url "http://localhost:5173"

  @octocat %{"id" => 583_231, "login" => "octocat", "name" => "The Octocat", "email" => nil}

  setup do
    stub(ClockMock, :now, fn -> @t0 end)

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    original = Application.fetch_env!(:openmaru, Openmaru.Accounts.OAuth)

    github =
      original
      |> Keyword.fetch!(:providers)
      |> Keyword.fetch!(:github)
      |> Keyword.merge(
        client_id: "gh-client",
        client_secret: "gh-secret",
        base_url: base,
        authorize_url: base <> "/login/oauth/authorize",
        token_url: base <> "/login/oauth/access_token"
      )

    google =
      original
      |> Keyword.fetch!(:providers)
      |> Keyword.fetch!(:google)
      |> Keyword.merge(client_id: "g-client", client_secret: "g-secret", base_url: base)

    Application.put_env(
      :openmaru,
      Openmaru.Accounts.OAuth,
      Keyword.update!(original, :providers, &Keyword.merge(&1, github: github, google: google))
    )

    on_exit(fn -> Application.put_env(:openmaru, Openmaru.Accounts.OAuth, original) end)

    %{bypass: bypass}
  end

  defp verified(email), do: [%{"email" => email, "primary" => true, "verified" => true}]
  defp unverified(email), do: [%{"email" => email, "primary" => true, "verified" => false}]

  defp stub_github(bypass, user, emails) do
    Bypass.expect_once(bypass, "POST", "/login/oauth/access_token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["code"] == "code-1"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"access_token":"gho_test","token_type":"bearer","scope":""}))
    end)

    Bypass.expect_once(bypass, "GET", "/user", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(user))
    end)

    Bypass.expect_once(bypass, "GET", "/user/emails", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(emails))
    end)
  end

  # Starts the flow, follows the provider "redirect" and calls back with the returned state.
  defp github_sign_in(conn, bypass, user, emails, accept \\ "application/json") do
    conn = get(conn, ~p"/api/v1/auth/oauth/github")

    %{"state" => state} =
      conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    stub_github(bypass, user, emails)

    conn
    |> recycle()
    |> put_req_header("accept", accept)
    |> get(~p"/api/v1/auth/oauth/github/callback", %{"code" => "code-1", "state" => state})
  end

  defp identities, do: Repo.all(from i in OAuthIdentity, order_by: i.inserted_at)

  test "C01-T07 the start redirects to GitHub with state and sets the state cookie", %{
    conn: conn,
    bypass: bypass
  } do
    conn = get(conn, ~p"/api/v1/auth/oauth/github")

    location = URI.parse(redirected_to(conn, 302))

    assert "#{location.scheme}://#{location.host}:#{location.port}" ==
             "http://localhost:#{bypass.port}"

    assert location.path == "/login/oauth/authorize"

    query = URI.decode_query(location.query)
    assert query["client_id"] == "gh-client"
    assert query["redirect_uri"] =~ "/api/v1/auth/oauth/github/callback"
    assert byte_size(query["state"]) >= 32

    cookie = conn.resp_cookies["_om_oauth"]
    assert cookie.http_only and cookie.secure and cookie.same_site == "Lax"
    assert cookie.max_age == 300
  end

  test "C01-T07 new identity → new user; the same identity again → the same user", %{
    conn: conn,
    bypass: bypass
  } do
    first = github_sign_in(conn, bypass, @octocat, verified("octocat@example.com"))
    body = json_response(first, 200)

    assert "usr_" <> _ = body["id"]
    assert body["handle"] == nil
    assert body["email"] == "octocat@example.com"
    assert %{value: _} = first.resp_cookies[session_cookie()]

    assert [identity] = identities()
    assert identity.provider == "github"
    assert identity.provider_uid == "583231"
    assert identity.user_id == uuid!(body["id"], "usr")

    second = github_sign_in(fresh_conn(conn), bypass, @octocat, verified("octocat@example.com"))

    assert json_response(second, 200)["id"] == body["id"]
    assert %{value: _} = second.resp_cookies[session_cookie()]
    assert Repo.aggregate(User, :count) == 1
    assert length(identities()) == 1
  end

  test "C01-T07 an unverified provider email is not stored on a new user", %{
    conn: conn,
    bypass: bypass
  } do
    conn = github_sign_in(conn, bypass, @octocat, unverified("octocat@example.com"))

    body = json_response(conn, 200)
    assert body["email"] == nil
    assert Repo.get!(User, uuid!(body["id"], "usr")).email == nil
  end

  test "C01-T07 the browser flow redirects to the web app with the session cookie", %{
    conn: conn,
    bypass: bypass
  } do
    conn = github_sign_in(conn, bypass, @octocat, verified("octocat@example.com"), "text/html")

    assert redirected_to(conn, 302) == @web_url <> "/"
    assert %{value: _} = conn.resp_cookies[session_cookie()]
    assert %{max_age: 0} = conn.resp_cookies["_om_oauth"]
  end

  test "C01-T08 not signed in and the provider email belongs to an existing user → 409 account_exists",
       %{conn: conn, bypass: bypass} do
    existing = insert!(:user, email: "octocat@example.com")

    conn = github_sign_in(conn, bypass, @octocat, verified("OctoCat@Example.com"))

    assert %{"error" => %{"code" => "account_exists"}} = json_response(conn, 409)
    refute Map.has_key?(conn.resp_cookies, session_cookie())
    assert identities() == []
    assert Repo.aggregate(User, :count) == 1
    assert Repo.get!(User, existing.id).email == "octocat@example.com"
  end

  test "C01-T08 the browser flow redirects to sign-in with the account_exists error", %{
    conn: conn,
    bypass: bypass
  } do
    insert!(:user, email: "octocat@example.com")

    conn = github_sign_in(conn, bypass, @octocat, unverified("octocat@example.com"), "text/html")

    assert redirected_to(conn, 302) == @web_url <> "/signin?error=account_exists"
    refute Map.has_key?(conn.resp_cookies, session_cookie())
    assert identities() == []
  end

  test "C01-T09 signed in with a provider-verified email → identity linked to the current user",
       %{conn: conn, bypass: bypass} do
    user = insert!(:user, email: "me@example.com")
    conn = sign_in(conn, user)

    conn = github_sign_in(conn, bypass, @octocat, verified("octocat@example.com"))

    assert json_response(conn, 200)["id"] == Openmaru.TypeID.encode("usr", user.id)
    assert [identity] = identities()
    assert identity.user_id == user.id
    assert identity.provider_uid == "583231"
    assert Repo.aggregate(User, :count) == 1
    assert Repo.get!(User, user.id).email == "me@example.com"

    # Signing in with the linked identity later reaches the same user.
    again = github_sign_in(fresh_conn(conn), bypass, @octocat, verified("octocat@example.com"))
    assert json_response(again, 200)["id"] == Openmaru.TypeID.encode("usr", user.id)
  end

  test "C01-T09 linking gives a user without an email the verified provider email", %{
    conn: conn,
    bypass: bypass
  } do
    user = insert!(:user, email: nil)

    conn = conn |> sign_in(user) |> github_sign_in(bypass, @octocat, verified("octo@example.com"))

    assert json_response(conn, 200)["email"] == "octo@example.com"
    assert Repo.get!(User, user.id).email == "octo@example.com"
  end

  test "C01-T09 signed in but the provider email is unverified → not linked", %{
    conn: conn,
    bypass: bypass
  } do
    user = insert!(:user)

    conn =
      conn |> sign_in(user) |> github_sign_in(bypass, @octocat, unverified("octo@example.com"))

    assert %{
             "error" => %{"code" => "forbidden", "details" => %{"reason" => "email_not_verified"}}
           } =
             json_response(conn, 403)

    assert identities() == []
  end

  test "C01-T09 signed in, identity already linked to another user → 409 account_exists", %{
    conn: conn,
    bypass: bypass
  } do
    owner = github_sign_in(conn, bypass, @octocat, verified("octocat@example.com"))
    owner_id = json_response(owner, 200)["id"]

    other = insert!(:user)

    conn =
      conn
      |> fresh_conn()
      |> sign_in(other)
      |> github_sign_in(bypass, @octocat, verified("octocat@example.com"))

    assert %{"error" => %{"code" => "account_exists"}} = json_response(conn, 409)
    assert [identity] = identities()
    assert identity.user_id == uuid!(owner_id, "usr")
  end

  test "C01-T15 a suspended user's OAuth sign-in is 403 forbidden", %{conn: conn, bypass: bypass} do
    first = github_sign_in(conn, bypass, @octocat, verified("octocat@example.com"))
    user_id = uuid!(json_response(first, 200)["id"], "usr")
    Repo.update_all(from(u in User, where: u.id == ^user_id), set: [suspended_at: @t0])

    conn = github_sign_in(fresh_conn(conn), bypass, @octocat, verified("octocat@example.com"))

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    refute Map.has_key?(conn.resp_cookies, session_cookie())
  end

  describe "state protection" do
    test "C01-T07 a callback whose state does not match is invalid_request", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/oauth/github")

      conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/auth/oauth/github/callback", %{"code" => "code-1", "state" => "forged"})

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
      assert Repo.aggregate(User, :count) == 0
    end

    test "C01-T07 a callback without the state cookie is invalid_request", %{conn: conn} do
      started = get(conn, ~p"/api/v1/auth/oauth/github")

      %{"state" => state} =
        started |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      conn =
        conn
        |> fresh_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/auth/oauth/github/callback", %{"code" => "code-1", "state" => state})

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end

    test "C01-T07 a state older than 5 minutes is invalid_request", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/oauth/github")

      %{"state" => state} =
        conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      stub(ClockMock, :now, fn -> DateTime.add(@t0, 301, :second) end)

      conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/auth/oauth/github/callback", %{"code" => "code-1", "state" => state})

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end

    test "C01-T07 a state is single use", %{conn: conn, bypass: bypass} do
      conn = get(conn, ~p"/api/v1/auth/oauth/github")
      cookie = conn.resp_cookies["_om_oauth"].value

      %{"state" => state} =
        conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      stub_github(bypass, @octocat, verified("octocat@example.com"))

      params = %{"code" => "code-1", "state" => state}

      assert conn
             |> recycle()
             |> put_req_header("accept", "application/json")
             |> get(~p"/api/v1/auth/oauth/github/callback", params)
             |> json_response(200)

      replay =
        conn
        |> fresh_conn()
        |> put_req_cookie("_om_oauth", cookie)
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/auth/oauth/github/callback", params)

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(replay, 400)
    end

    test "C01-T07 a provider error redirects the browser to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/oauth/github")

      %{"state" => state} =
        conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      conn =
        conn
        |> recycle()
        |> get(~p"/api/v1/auth/oauth/github/callback", %{
          "error" => "access_denied",
          "state" => state
        })

      assert redirected_to(conn, 302) == @web_url <> "/signin?error=invalid_request"
    end
  end

  describe "Google (OpenID Connect)" do
    setup %{bypass: bypass} do
      base = "http://localhost:#{bypass.port}"
      key = :public_key.generate_key({:rsa, 2048, 65_537})

      Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        json_resp(conn, %{
          "issuer" => base,
          "authorization_endpoint" => base <> "/o/oauth2/v2/auth",
          "token_endpoint" => base <> "/token",
          "jwks_uri" => base <> "/certs"
        })
      end)

      %{base: base, key: key}
    end

    defp json_resp(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end

    defp jwk({:RSAPrivateKey, _version, n, e, _d, _p, _q, _dp, _dq, _qi, _other}) do
      encode = &(&1 |> :binary.encode_unsigned() |> Base.url_encode64(padding: false))
      %{"kty" => "RSA", "alg" => "RS256", "use" => "sig", "n" => encode.(n), "e" => encode.(e)}
    end

    # Starts the flow, then answers the token request with an ID token whose claims
    # `claims_fun` builds from the nonce the server sent to the provider.
    defp google_sign_in(conn, %{bypass: bypass, base: base, key: key}, claims_fun) do
      conn = get(conn, ~p"/api/v1/auth/oauth/google")
      location = URI.parse(redirected_to(conn, 302))

      assert "#{location.scheme}://#{location.host}:#{location.port}#{location.path}" ==
               base <> "/o/oauth2/v2/auth"

      %{"state" => state, "nonce" => nonce} = URI.decode_query(location.query)
      assert byte_size(nonce) >= 32

      now = System.system_time(:second)

      claims =
        Map.merge(
          %{"iss" => base, "aud" => "g-client", "iat" => now, "exp" => now + 600},
          claims_fun.(nonce)
        )

      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

      {:ok, id_token} =
        Assent.JWTAdapter.AssentJWT.sign(claims, "RS256", pem, json_library: Jason)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        json_resp(conn, %{
          "access_token" => "ya29.test",
          "token_type" => "Bearer",
          "expires_in" => 3600,
          "id_token" => id_token
        })
      end)

      Bypass.expect_once(bypass, "GET", "/certs", fn conn ->
        json_resp(conn, %{"keys" => [jwk(key)]})
      end)

      conn
      |> recycle()
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/v1/auth/oauth/google/callback", %{"code" => "code-1", "state" => state})
    end

    test "C01-T07 Google: an ID token carrying the stored nonce signs in a new user", ctx do
      conn =
        google_sign_in(ctx.conn, ctx, fn nonce ->
          %{
            "sub" => "google-42",
            "nonce" => nonce,
            "email" => "g@example.com",
            "email_verified" => true,
            "name" => "Gee"
          }
        end)

      body = json_response(conn, 200)
      assert body["email"] == "g@example.com"
      assert body["display_name"] == "Gee"
      assert [%{provider: "google", provider_uid: "google-42"}] = identities()
    end

    test "C01-T07 Google: an ID token with a different nonce is invalid_request", ctx do
      conn =
        google_sign_in(ctx.conn, ctx, fn _nonce ->
          %{"sub" => "google-42", "nonce" => "replayed", "email_verified" => true}
        end)

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
      assert identities() == []
    end
  end

  test "C01-T07 an unknown provider is 404 not_found", %{conn: conn} do
    conn =
      conn |> put_req_header("accept", "application/json") |> get("/api/v1/auth/oauth/myspace")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end
end
