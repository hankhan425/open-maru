defmodule Openmaru.AccountsTest do
  use OpenmaruWeb.ConnCase, async: true
  use Oban.Testing, repo: Openmaru.Repo

  alias Openmaru.{Accounts, ClockMock, Repo}
  alias Openmaru.Accounts.{Challenge, Passkey, PruneWorker, User, UserSession}
  alias Openmaru.Test.FakeAuthenticator

  @t0 ~U[2026-03-01 12:00:00.000000Z]

  setup do
    stub(ClockMock, :now, fn -> @t0 end)
    :ok
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  describe "sessions" do
    test "C01-T14 activity within the first hour neither moves the expiry nor re-sends the cookie",
         %{conn: conn} do
      {:ok, token, session} = Accounts.create_session(insert!(:user))

      at(3599)
      assert {:ok, _user, same} = Accounts.get_session_user(token)
      refute same.extended
      assert same.expires_at == session.expires_at

      conn = conn |> put_req_cookie(session_cookie(), token) |> get(~p"/api/v1/me")
      assert json_response(conn, 200)
      refute Map.has_key?(conn.resp_cookies, session_cookie())

      at(3601)
      assert {:ok, _user, moved} = Accounts.get_session_user(token)
      assert moved.extended
      assert moved.expires_at == DateTime.add(@t0, 3601 + Accounts.session_ttl_seconds(), :second)
    end

    test "C01-T13 signing in as someone else revokes the session the request carried", %{
      conn: conn
    } do
      %{conn: registered, authenticator: auth} = register_passkey(conn)
      old_token = registered.resp_cookies[session_cookie()].value

      {:ok, other_token, _session} = Accounts.create_session(insert!(:user))

      conn =
        conn
        |> fresh_conn()
        |> put_req_cookie(session_cookie(), other_token)
        |> with_csrf()
        |> post(~p"/api/v1/auth/passkey/login/options", %{})

      options = json_response(conn, 200)
      {assertion, _auth} = FakeAuthenticator.assert(auth, options["public_key"])

      conn =
        conn
        |> with_csrf()
        |> post(~p"/api/v1/auth/passkey/login", %{
          "challenge_id" => options["challenge_id"],
          "credential" => assertion
        })

      assert json_response(conn, 200)
      assert {:error, %{code: :unauthenticated}} = Accounts.get_session_user(other_token)
      assert {:ok, _user, _session} = Accounts.get_session_user(old_token)
    end

    test "C01-T13 get_session_user rejects non-binary tokens" do
      assert {:error, %{code: :unauthenticated}} = Accounts.get_session_user(nil)
    end
  end

  describe "passkeys" do
    test "C01-T02 concurrent registrations by one user share the WebAuthn user handle" do
      user = insert!(:user, webauthn_user_handle: nil)

      {:ok, first} = Accounts.begin_passkey_registration(user)
      {:ok, second} = Accounts.begin_passkey_registration(user)
      assert first.public_key["user"]["id"] == second.public_key["user"]["id"]

      user = Repo.reload!(user)

      for ceremony <- [second, first] do
        {credential, _auth} =
          FakeAuthenticator.attest(FakeAuthenticator.new(), ceremony.public_key)

        assert {:ok, _user} =
                 Accounts.finish_passkey_registration(user, %{
                   "challenge_id" => ceremony.challenge_id,
                   "credential" => credential
                 })
      end

      assert Repo.aggregate(Passkey, :count) == 2
    end

    test "C01-T04 stored COSE keys round-trip" do
      key = FakeAuthenticator.cose_key(FakeAuthenticator.new())
      assert {:ok, ^key} = key |> Passkey.encode_cose_key() |> Passkey.decode_cose_key()
      assert :error = Passkey.decode_cose_key("not cbor")
    end
  end

  describe "handles" do
    test "C01-T10 set_handle stores lower case and reports taken handles" do
      insert!(:user, handle: "taken")
      user = insert!(:user, handle: nil)

      assert {:error, %{code: :handle_taken}} = Accounts.set_handle(user, "Taken")
      assert {:ok, %User{handle: "mine"}} = Accounts.set_handle(user, "MINE")
      assert {:ok, %User{handle: "mine"}} = Accounts.set_handle(Repo.reload!(user), "mine")

      assert {:error, %{code: :invalid_request, details: %{reason: "handle_immutable"}}} =
               Accounts.set_handle(Repo.reload!(user), "other")
    end

    test "C01-T11 a stale struct cannot overwrite a handle set meanwhile" do
      user = insert!(:user, handle: nil)
      assert {:ok, _} = Accounts.set_handle(user, "first")

      assert {:error, %{code: :invalid_request}} = Accounts.set_handle(user, "second")
      assert Repo.reload!(user).handle == "first"
    end
  end

  describe "pruning" do
    test "C01-T03 the hourly job deletes expired challenges and dead sessions only" do
      day = 24 * 3600
      {:ok, _expired_challenge} = Accounts.begin_passkey_login()
      {:ok, _token, revoked_long_ago} = Accounts.create_session(insert!(:user))
      :ok = Accounts.revoke_session(revoked_long_ago)
      {:ok, _token, _expiring_now} = Accounts.create_session(insert!(:user))

      at(30 * day)
      {:ok, live_challenge} = Accounts.begin_passkey_login()
      {:ok, _token, live} = Accounts.create_session(insert!(:user))
      {:ok, _token, revoked_today} = Accounts.create_session(insert!(:user))
      :ok = Accounts.revoke_session(revoked_today)

      assert :ok = perform_job(PruneWorker, %{})

      assert [%Challenge{id: id}] = Repo.all(Challenge)
      assert id == live_challenge.challenge_id

      assert Repo.all(UserSession) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([live.id, revoked_today.id])
    end
  end
end
