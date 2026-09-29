defmodule Openmaru.AuditTest do
  use OpenmaruWeb.ConnCase, async: true

  import Ecto.Query

  alias Openmaru.{Audit, Repo}
  alias Openmaru.Test.FakeAuthenticator

  defp rows(action) do
    Repo.all(
      from e in "audit_log",
        where: e.action == ^action,
        select: %{
          actor_kind: e.actor_kind,
          actor_id: type(e.actor_id, Ecto.UUID),
          ip_hash: e.ip_hash,
          user_agent: e.user_agent,
          metadata: e.metadata
        }
    )
  end

  defp ip_string(ip), do: ip |> :inet.ntoa() |> to_string()

  describe "append-only" do
    setup do
      {:ok, entry} = Audit.record(%{action: "test.append_only", metadata: %{"n" => 1}})
      %{entry: entry}
    end

    test "C01-T18 audit_log rejects UPDATE", %{entry: entry} do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(e in "audit_log", where: e.id == type(^entry.id, Ecto.UUID)),
              set: [action: "tampered"]
            )
          end)
        end

      assert Exception.message(error) =~ "append-only"
      assert [%{metadata: %{"n" => 1}}] = rows("test.append_only")
    end

    test "C01-T18 audit_log rejects DELETE", %{entry: entry} do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.delete_all(from(e in "audit_log", where: e.id == type(^entry.id, Ecto.UUID)))
          end)
        end

      assert Exception.message(error) =~ "append-only"
      assert [_row] = rows("test.append_only")
    end

    test "C01-T18 audit_log rejects TRUNCATE" do
      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.transaction(fn -> Repo.query!("TRUNCATE audit_log") end)
      end
    end
  end

  test "C01-T18 a passkey sign-in writes a success row with a hashed IP", %{conn: conn} do
    %{user: user, authenticator: auth} = register_passkey(conn)

    {conn, _auth} = passkey_login(conn, auth, headers: [{"user-agent", "TestBrowser/1.0"}])

    assert json_response(conn, 200)

    rows = rows("auth.sign_in_succeeded")
    login = Enum.find(rows, &(&1.metadata["method"] == "passkey" and &1.user_agent != nil))

    assert login, "expected a passkey sign-in row, got #{inspect(rows)}"
    assert login.actor_kind == "person"
    assert login.actor_id == uuid!(user["id"], "usr")
    assert login.ip_hash == Audit.hash_ip(conn.remote_ip)
    refute login.ip_hash =~ ip_string(conn.remote_ip)
    assert login.user_agent == "TestBrowser/1.0"
  end

  test "C01-T18 a failed sign-in writes a failure row with a hashed IP", %{conn: conn} do
    {conn, _auth} = passkey_login(conn, FakeAuthenticator.new())
    assert json_response(conn, 401)

    assert [row] = rows("auth.sign_in_failed")
    assert row.actor_kind == nil
    assert row.actor_id == nil
    assert row.ip_hash == Audit.hash_ip(conn.remote_ip)
    assert row.metadata == %{"method" => "passkey", "reason" => "unknown_credential"}
  end

  test "C01-T18 the IP hash is keyed, stable and distinguishes addresses" do
    ip = {203, 0, 113, 7}

    assert Audit.hash_ip(ip) == Audit.hash_ip(ip)
    assert Audit.hash_ip(ip) == Audit.hash_ip("203.0.113.7")
    refute Audit.hash_ip(ip) == Audit.hash_ip({203, 0, 113, 8})

    unkeyed = :sha256 |> :crypto.hash("203.0.113.7") |> Base.encode16(case: :lower)
    refute Audit.hash_ip(ip) == unkeyed
    assert Audit.hash_ip(nil) == nil
  end
end
