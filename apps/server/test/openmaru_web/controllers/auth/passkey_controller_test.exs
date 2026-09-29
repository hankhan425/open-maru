defmodule OpenmaruWeb.Auth.PasskeyControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  import Ecto.Query

  alias Openmaru.Accounts.{Passkey, User}
  alias Openmaru.{ClockMock, Repo}
  alias Openmaru.Test.FakeAuthenticator

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @thirty_days 30 * 24 * 3600

  setup do
    stub(ClockMock, :now, fn -> @t0 end)
    :ok
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp registration_options(conn) do
    conn = post(conn, ~p"/api/v1/auth/passkey/register/options", %{})
    {conn, json_response(conn, 200)}
  end

  defp finish_registration(conn, options, credential) do
    post(recycle(conn), ~p"/api/v1/auth/passkey/register", %{
      "challenge_id" => options["challenge_id"],
      "credential" => credential
    })
  end

  defp stored_challenge(id) do
    Repo.one!(
      from c in "auth_challenges",
        where: c.id == type(^id, Ecto.UUID),
        select: %{
          kind: c.kind,
          challenge: c.challenge,
          expires_at: type(c.expires_at, :utc_datetime_usec)
        }
    )
  end

  defp decode64(string), do: FakeAuthenticator.decode64(string)

  defp assert_session_cookie(conn) do
    cookie = conn.resp_cookies[session_cookie()]
    assert %{value: token} = cookie
    assert byte_size(token) >= 43
    assert cookie.http_only == true
    assert cookie.secure == true
    assert cookie.same_site == "Lax"
    assert cookie.max_age == @thirty_days
    assert cookie.path == "/"

    [header] =
      conn
      |> get_resp_header("set-cookie")
      |> Enum.filter(&String.starts_with?(&1, session_cookie() <> "="))

    assert header =~ "HttpOnly"
    assert header =~ ~r/;\s*secure/i
    assert header =~ "SameSite=Lax"
    token
  end

  defp user_count, do: Repo.aggregate(User, :count)

  describe "registration options" do
    test "C01-T01 rp id/name, random 32-byte user handle, user verification required, challenge persisted",
         %{conn: conn} do
      {_conn, body} = registration_options(conn)
      public_key = body["public_key"]

      assert public_key["rp"] == %{"id" => "localhost", "name" => "openmaru"}
      assert byte_size(decode64(public_key["user"]["id"])) == 32
      assert is_binary(public_key["user"]["name"]) and public_key["user"]["name"] != ""
      assert public_key["authenticatorSelection"]["userVerification"] == "required"
      assert public_key["authenticatorSelection"]["residentKey"] == "required"
      assert %{"type" => "public-key", "alg" => -7} in public_key["pubKeyCredParams"]
      assert public_key["attestation"] == "none"
      assert public_key["timeout"] == 300_000

      challenge = decode64(public_key["challenge"])
      assert byte_size(challenge) == 32

      stored = stored_challenge(body["challenge_id"])
      assert stored.kind == "passkey_registration"
      assert stored.challenge == challenge
      assert stored.expires_at == DateTime.add(@t0, 300, :second)
    end

    test "C01-T01 every request gets a new challenge and user handle", %{conn: conn} do
      {conn, a} = registration_options(conn)
      {_conn, b} = registration_options(recycle(conn))

      refute a["challenge_id"] == b["challenge_id"]
      refute a["public_key"]["challenge"] == b["public_key"]["challenge"]
      refute a["public_key"]["user"]["id"] == b["public_key"]["user"]["id"]
    end
  end

  describe "registration" do
    test "C01-T02 a valid attestation creates a user without a handle, stores the passkey and sets the session cookie",
         %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      conn = finish_registration(conn, options, credential)
      body = json_response(conn, 201)

      assert "usr_" <> _ = body["id"]
      assert body["handle"] == nil
      assert_session_cookie(conn)

      user = Repo.get!(User, uuid!(body["id"], "usr"))
      assert user.handle == nil
      assert user.webauthn_user_handle == decode64(options["public_key"]["user"]["id"])

      assert [passkey] = Repo.all(Passkey)
      assert passkey.user_id == user.id
      assert passkey.credential_id == auth.credential_id
      assert passkey.sign_count == 0
      assert passkey.transports == ["internal", "hybrid"]

      assert conn |> recycle() |> get(~p"/api/v1/me") |> json_response(200) |> Map.get("id") ==
               body["id"]
    end

    test "C01-T02 an attestation without user verification is rejected", %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"],
          user_verified: false
        )

      conn = finish_registration(conn, options, credential)

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
      assert user_count() == 0
    end

    test "C01-T02 an attestation from another origin is rejected", %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"],
          origin: "https://evil.example"
        )

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn |> finish_registration(options, credential) |> json_response(400)

      assert user_count() == 0
    end

    test "C01-T02 a malformed credential is invalid_request", %{conn: conn} do
      for credential <- [
            nil,
            "x",
            %{"rawId" => "!!", "response" => %{}},
            %{"response" => %{"clientDataJSON" => "e30", "attestationObject" => "AA"}},
            %{"response" => %{"clientDataJSON" => "bm90IGpzb24", "attestationObject" => "oA"}}
          ] do
        # A fresh IP each round keeps the 11 requests under the auth rate limit.
        {conn, options} = registration_options(fresh_conn(unique_ip()))

        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn |> finish_registration(options, credential) |> json_response(400)
      end

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn
               |> post(~p"/api/v1/auth/passkey/register", %{"credential" => %{}})
               |> json_response(400)

      assert user_count() == 0
    end

    test "C01-T02 a credential id that is already registered is rejected", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      {conn, options} = registration_options(fresh_conn(conn))
      {credential, _auth} = FakeAuthenticator.attest(auth, options["public_key"])

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn |> finish_registration(options, credential) |> json_response(400)

      assert user_count() == 1
    end

    test "C01-T02 a signed-in user registering adds a passkey to their account", %{conn: conn} do
      %{conn: conn, user: user} = register_passkey(conn)
      handle = Repo.get!(User, uuid!(user["id"], "usr")).webauthn_user_handle

      conn = conn |> with_csrf() |> post(~p"/api/v1/auth/passkey/register/options", %{})
      options = json_response(conn, 200)
      assert decode64(options["public_key"]["user"]["id"]) == handle
      assert [%{"type" => "public-key", "id" => _}] = options["public_key"]["excludeCredentials"]

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      conn =
        conn
        |> with_csrf()
        |> post(~p"/api/v1/auth/passkey/register", %{
          "challenge_id" => options["challenge_id"],
          "credential" => credential
        })

      assert json_response(conn, 201)["id"] == user["id"]
      refute Map.has_key?(conn.resp_cookies, session_cookie())
      assert user_count() == 1
      assert Repo.aggregate(Passkey, :count) == 2
    end

    test "C01-T02 a registration begun anonymously cannot be finished by a signed-in user",
         %{conn: conn} do
      {_conn, options} = registration_options(fresh_conn(conn))

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      signed_in = conn |> sign_in(insert!(:user)) |> with_csrf()

      assert %{"error" => %{"code" => "invalid_request"}} =
               signed_in
               |> post(~p"/api/v1/auth/passkey/register", %{
                 "challenge_id" => options["challenge_id"],
                 "credential" => credential
               })
               |> json_response(400)

      assert Repo.aggregate(Passkey, :count) == 0
    end
  end

  describe "challenges" do
    test "C01-T03 a replayed registration challenge is invalid_request", %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      assert conn |> finish_registration(options, credential) |> json_response(201)

      replay = conn |> fresh_conn() |> finish_registration(options, credential)
      assert %{"error" => %{"code" => "invalid_request"}} = json_response(replay, 400)
      assert user_count() == 1
    end

    test "C01-T03 a registration challenge older than 5 minutes is invalid_request", %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      at(5 * 60 + 1)
      conn = finish_registration(conn, options, credential)

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
      assert user_count() == 0
    end

    test "C01-T03 a challenge is still valid just before 5 minutes", %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      at(5 * 60 - 1)
      assert conn |> finish_registration(options, credential) |> json_response(201)
    end

    test "C01-T03 a replayed or expired login challenge is invalid_request", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      conn = conn |> fresh_conn() |> post(~p"/api/v1/auth/passkey/login/options", %{})
      options = json_response(conn, 200)
      {assertion, _auth} = FakeAuthenticator.assert(auth, options["public_key"])
      body = %{"challenge_id" => options["challenge_id"], "credential" => assertion}

      assert conn |> recycle() |> post(~p"/api/v1/auth/passkey/login", body) |> json_response(200)

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn
               |> fresh_conn()
               |> post(~p"/api/v1/auth/passkey/login", body)
               |> json_response(400)

      conn = conn |> fresh_conn() |> post(~p"/api/v1/auth/passkey/login/options", %{})
      options = json_response(conn, 200)
      {assertion, _auth} = FakeAuthenticator.assert(auth, options["public_key"], sign_count: 10)
      at(5 * 60 + 1)

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn
               |> recycle()
               |> post(~p"/api/v1/auth/passkey/login", %{
                 "challenge_id" => options["challenge_id"],
                 "credential" => assertion
               })
               |> json_response(400)
    end

    test "C01-T03 an unknown challenge id or a challenge of the wrong kind is invalid_request",
         %{conn: conn} do
      {conn, options} = registration_options(conn)

      {credential, _auth} =
        FakeAuthenticator.attest(FakeAuthenticator.new(), options["public_key"])

      for challenge_id <- [Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn
                 |> finish_registration(%{"challenge_id" => challenge_id}, credential)
                 |> json_response(400)
      end

      login = conn |> recycle() |> post(~p"/api/v1/auth/passkey/login/options", %{})
      login_options = json_response(login, 200)

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn
               |> finish_registration(
                 %{"challenge_id" => login_options["challenge_id"]},
                 credential
               )
               |> json_response(400)

      # The registration challenge was not consumed by the failed attempts.
      assert conn |> finish_registration(options, credential) |> json_response(201)
    end
  end

  describe "login" do
    test "C01-T04 a valid assertion signs in with a correct session cookie and updates the passkey",
         %{conn: conn} do
      %{user: user, authenticator: auth} = register_passkey(conn)

      at(3600)
      {conn, auth} = passkey_login(conn, auth)

      assert json_response(conn, 200)["id"] == user["id"]
      assert_session_cookie(conn)

      passkey = Repo.get_by!(Passkey, credential_id: auth.credential_id)
      assert passkey.sign_count == 1
      assert passkey.last_used_at == DateTime.add(@t0, 3600, :second)

      assert conn |> recycle() |> get(~p"/api/v1/me") |> json_response(200) |> Map.get("id") ==
               user["id"]
    end

    test "C01-T04 authenticators without a counter (always 0) can sign in repeatedly",
         %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      {first, auth} = passkey_login(conn, auth, sign_count: 0)
      assert json_response(first, 200)
      {second, _auth} = passkey_login(conn, auth, sign_count: 0)
      assert json_response(second, 200)
    end

    test "C01-T05 a sign-count regression is 401 and writes an audit row", %{conn: conn} do
      %{user: user, authenticator: auth} = register_passkey(conn)
      {ok, auth} = passkey_login(conn, auth, sign_count: 5)
      assert json_response(ok, 200)

      {conn, _auth} = passkey_login(conn, auth, sign_count: 3)

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
      refute Map.has_key?(conn.resp_cookies, session_cookie())

      passkey = Repo.get_by!(Passkey, credential_id: auth.credential_id)
      assert passkey.sign_count == 5

      user_id = uuid!(user["id"], "usr")

      assert [row] =
               Repo.all(
                 from e in "audit_log",
                   where: e.action == "passkey.sign_count_regression",
                   select: %{
                     actor_kind: e.actor_kind,
                     actor_id: type(e.actor_id, Ecto.UUID),
                     target_type: e.target_type,
                     target_id: type(e.target_id, Ecto.UUID),
                     metadata: e.metadata
                   }
               )

      assert row.actor_kind == "person"
      assert row.actor_id == user_id
      assert row.target_type == "passkey"
      assert row.target_id == passkey.id
      assert row.metadata == %{"stored_sign_count" => 5, "sign_count" => 3}
    end

    test "C01-T05 an unchanged non-zero sign count is also a regression", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)
      {ok, auth} = passkey_login(conn, auth, sign_count: 5)
      assert json_response(ok, 200)

      {conn, _auth} = passkey_login(conn, auth, sign_count: 5)
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "C01-T06 an unknown credential id is 401 unauthenticated", %{conn: conn} do
      _ = register_passkey(conn)
      stranger = FakeAuthenticator.new()

      {conn, _auth} = passkey_login(conn, stranger)

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
      refute Map.has_key?(conn.resp_cookies, session_cookie())
    end

    test "C01-T06 an assertion without user verification is 401", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      {conn, _auth} = passkey_login(conn, auth, user_verified: false)
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "C01-T06 an assertion signed for another origin or rp id is 401", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      {conn, _auth} = passkey_login(conn, auth, origin: "https://evil.example")
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)

      {conn, _auth} = passkey_login(conn, auth, rp_id: "evil.example")
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "C01-T06 a user handle that does not match the credential's user is 401", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      {conn, _auth} = passkey_login(conn, auth, user_handle: :crypto.strong_rand_bytes(32))
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "C01-T06 a tampered signature is 401 and does not update the passkey", %{conn: conn} do
      %{authenticator: auth} = register_passkey(conn)

      conn = conn |> fresh_conn() |> post(~p"/api/v1/auth/passkey/login/options", %{})
      options = json_response(conn, 200)
      {assertion, _auth} = FakeAuthenticator.assert(auth, options["public_key"], sign_count: 7)
      other = FakeAuthenticator.new()
      {forged, _} = FakeAuthenticator.assert(other, options["public_key"], sign_count: 7)

      assertion =
        put_in(assertion, ["response", "signature"], forged["response"]["signature"])

      conn =
        conn
        |> recycle()
        |> post(~p"/api/v1/auth/passkey/login", %{
          "challenge_id" => options["challenge_id"],
          "credential" => assertion
        })

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
      assert Repo.get_by!(Passkey, credential_id: auth.credential_id).sign_count == 0
    end

    test "C01-T04 login options carry a persisted challenge and no allow list", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/passkey/login/options", %{})
      body = json_response(conn, 200)
      public_key = body["public_key"]

      assert public_key["rpId"] == "localhost"
      assert public_key["userVerification"] == "required"
      assert public_key["allowCredentials"] == []
      assert public_key["timeout"] == 300_000

      stored = stored_challenge(body["challenge_id"])
      assert stored.kind == "passkey_login"
      assert stored.challenge == decode64(public_key["challenge"])
    end
  end
end
