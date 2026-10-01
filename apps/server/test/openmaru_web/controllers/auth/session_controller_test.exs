defmodule OpenmaruWeb.Auth.SessionControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  import Ecto.Query

  alias Openmaru.Accounts.{User, UserSession}
  alias Openmaru.{ClockMock, Repo}

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @day 24 * 3600

  setup do
    stub(ClockMock, :now, fn -> @t0 end)
    :ok
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp me(conn, token) do
    conn |> fresh_conn() |> put_req_cookie(session_cookie(), token) |> get(~p"/api/v1/me")
  end

  defp suspend!(user_id) do
    Repo.update_all(from(u in User, where: u.id == ^user_id), set: [suspended_at: @t0])
  end

  describe "logout" do
    test "C01-T13 logout revokes the session; reusing the cookie is 401", %{conn: conn} do
      {:ok, token, _session} = Openmaru.Accounts.create_session(insert!(:user))
      conn = put_req_cookie(conn, session_cookie(), token)

      logout = conn |> with_csrf() |> post(~p"/api/v1/auth/logout")

      assert response(logout, 204) == ""
      assert %{max_age: 0} = logout.resp_cookies[session_cookie()]
      assert [%{revoked_at: revoked_at}] = Repo.all(UserSession)
      assert revoked_at == @t0

      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn |> me(token) |> json_response(401)
    end

    test "C01-T13 logout without a session is 401", %{conn: conn} do
      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn |> post(~p"/api/v1/auth/logout") |> json_response(401)
    end

    test "C01-T13 logout revokes only the current session", %{conn: conn} do
      user = insert!(:user)
      {:ok, other_token, _session} = Openmaru.Accounts.create_session(user)

      conn |> sign_in(user) |> with_csrf() |> post(~p"/api/v1/auth/logout") |> response(204)

      assert conn |> me(other_token) |> json_response(200)
    end
  end

  describe "sliding expiry" do
    test "C01-T14 activity on day 29 extends the session; 31 idle days after it is 401", %{
      conn: conn
    } do
      user = insert!(:user)
      {:ok, token, _session} = Openmaru.Accounts.create_session(user)
      {:ok, idle_token, _session} = Openmaru.Accounts.create_session(user)

      at(29 * @day)
      conn = me(conn, token)
      assert json_response(conn, 200)
      assert json_response(me(conn, idle_token), 200)
      assert %{value: ^token, max_age: max_age} = conn.resp_cookies[session_cookie()]
      assert max_age == 30 * @day

      hash = :crypto.hash(:sha256, token)

      assert Repo.get_by!(UserSession, token_hash: hash).expires_at ==
               DateTime.add(@t0, 59 * @day, :second)

      # Day 58: 29 idle days, still valid; without the extension it expired on day 30.
      at(58 * @day)
      assert conn |> me(token) |> json_response(200)

      # Day 60: 31 idle days after the day-29 activity.
      at(60 * @day)

      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn |> me(idle_token) |> json_response(401)
    end

    test "C01-T14 31 idle days after sign-in is 401", %{conn: conn} do
      {:ok, token, _session} = Openmaru.Accounts.create_session(insert!(:user))

      at(31 * @day)

      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn |> me(token) |> json_response(401)
    end

    test "C01-T14 a session expires exactly 30 days after the last activity", %{conn: conn} do
      {:ok, token, _session} = Openmaru.Accounts.create_session(insert!(:user))

      at(30 * @day - 1)
      assert conn |> me(token) |> json_response(200)

      {:ok, token, _session} = Openmaru.Accounts.create_session(insert!(:user))
      at(30 * @day - 1 + 30 * @day)

      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn |> me(token) |> json_response(401)
    end

    test "C01-T14 the session row stores only a hash of the token", %{conn: conn} do
      {:ok, token, session} = Openmaru.Accounts.create_session(insert!(:user))

      assert byte_size(token) >= 43
      assert session.token_hash == :crypto.hash(:sha256, token)
      assert session.expires_at == DateTime.add(@t0, 30 * @day, :second)
      refute Repo.one!(from s in "user_sessions", select: s.token_hash) == token

      assert conn |> me(token) |> json_response(200)
    end
  end

  describe "suspended users" do
    test "C01-T15 a suspended user's passkey sign-in is 403 forbidden", %{conn: conn} do
      %{user: user, authenticator: auth} = register_passkey(conn)
      suspend!(uuid!(user["id"], "usr"))

      {conn, _auth} = passkey_login(conn, auth)

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
      refute Map.has_key?(conn.resp_cookies, session_cookie())
    end

    test "C01-T15 a suspended user's existing sessions are rejected", %{conn: conn} do
      user = insert!(:user)
      {:ok, token, _session} = Openmaru.Accounts.create_session(user)
      assert conn |> me(token) |> json_response(200)

      suspend!(user.id)

      assert %{"error" => %{"code" => "forbidden"}} = conn |> me(token) |> json_response(403)
    end
  end
end
