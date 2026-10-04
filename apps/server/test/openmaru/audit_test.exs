defmodule Openmaru.AuditTest do
  use OpenmaruWeb.ConnCase, async: true

  use Oban.Testing, repo: Openmaru.Repo

  import Ecto.Query

  alias Openmaru.{Audit, ClockMock, Repo}
  alias Openmaru.Audit.{IpKey, IpKeySweeper}
  alias Openmaru.Test.FakeAuthenticator

  defp rows(action) do
    Repo.all(
      from e in "audit_log",
        where: e.action == ^action,
        select: %{
          actor_kind: e.actor_kind,
          actor_id: type(e.actor_id, Ecto.UUID),
          ip_hash: e.ip_hash,
          ip_hash_key_id: e.ip_hash_key_id,
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
    assert login.ip_hash_key_id == Audit.ip_hash_key_id()
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

  test "C01-T18 rows record the id of the key that hashed the IP" do
    {:ok, with_ip} = Audit.record(%{action: "test.key_id", ip: {203, 0, 113, 7}})
    {:ok, without_ip} = Audit.record(%{action: "test.key_id"})

    assert with_ip.ip_hash_key_id == Audit.ip_hash_key_id()
    assert without_ip.ip_hash == nil and without_ip.ip_hash_key_id == nil

    # The key row names the wrapping key that sealed it by fingerprint.
    wrapping_key = Application.fetch_env!(:openmaru, Audit)[:ip_key_wrapping_key]
    assert Repo.get!(IpKey, with_ip.ip_hash_key_id).wrapping_key_id == Audit.key_id(wrapping_key)
    assert Audit.key_id(wrapping_key) =~ ~r/\A[0-9a-f]{8}\z/
    refute Audit.key_id(wrapping_key <> "rotated") == Audit.key_id(wrapping_key)
    refute Audit.key_id(wrapping_key) =~ wrapping_key
  end

  describe "IP hash keys (OQ-6)" do
    @noon ~U[2031-03-10 12:00:00.000000Z]
    @ip {203, 0, 113, 7}

    defp at(datetime), do: stub(ClockMock, :now, fn -> datetime end)
    defp hours(n), do: DateTime.add(@noon, n * 3600, :second)

    test "C01-T18 each UTC day hashes with its own random key, stored sealed" do
      at(@noon)
      key_id = Audit.ip_hash_key_id()
      hash = Audit.hash_ip(@ip)

      at(hours(11))
      assert Audit.ip_hash_key_id() == key_id
      assert Audit.hash_ip(@ip) == hash

      at(hours(12))
      refute Audit.ip_hash_key_id() == key_id
      refute Audit.hash_ip(@ip) == hash

      key = Repo.get!(IpKey, key_id)
      assert key.day == ~D[2031-03-10]
      # 12-byte IV, 16-byte tag, 32-byte key: the key itself is never stored in the clear.
      assert byte_size(key.sealed_key) == 60
      assert key.destroyed_at == nil
    end

    test "C01-T18 a key is destroyed 30 days after its day ends" do
      at(@noon)
      key_id = Audit.ip_hash_key_id()
      {:ok, entry} = Audit.record(%{action: "test.retention", ip: @ip})

      at(~U[2031-04-09 23:59:59.999999Z])
      Audit.destroy_expired_ip_keys()
      assert Repo.get!(IpKey, key_id).sealed_key
      assert %{ip_hash_key_id: key_id, ip_hash: entry.ip_hash} in Audit.hashes_for_ip(@ip)

      at(~U[2031-04-10 00:00:00.000000Z])
      assert Audit.destroy_expired_ip_keys() >= 1
      key = Repo.get!(IpKey, key_id)
      assert key.sealed_key == nil
      assert key.destroyed_at == ~U[2031-04-10 00:00:00.000000Z]
      refute Enum.any?(Audit.hashes_for_ip(@ip), &(&1.ip_hash_key_id == key_id))
    end

    test "C01-T18 the hourly sweeper destroys expired keys" do
      at(@noon)
      key_id = Audit.ip_hash_key_id()

      at(~U[2031-05-01 00:00:00.000000Z])
      assert :ok = perform_job(IpKeySweeper, %{})
      assert Repo.get!(IpKey, key_id).sealed_key == nil
    end

    test "C01-T18 an address is found across days by its hash under each live key" do
      at(@noon)
      {:ok, first} = Audit.record(%{action: "test.lookup", ip: @ip})

      at(hours(24))
      {:ok, second} = Audit.record(%{action: "test.lookup", ip: "203.0.113.7"})
      {:ok, _other} = Audit.record(%{action: "test.lookup", ip: {203, 0, 113, 8}})

      lookup = Audit.hashes_for_ip(@ip)
      assert [%{ip_hash_key_id: newest}, %{ip_hash_key_id: older}] = lookup
      assert {newest, older} == {second.ip_hash_key_id, first.ip_hash_key_id}

      found =
        Repo.all(
          from e in "audit_log",
            where: e.action == "test.lookup",
            select: {e.ip_hash_key_id, e.ip_hash}
        )
        |> Enum.filter(fn {key_id, hash} ->
          %{ip_hash_key_id: key_id, ip_hash: hash} in lookup
        end)

      assert length(found) == 2
    end

    test "C01-T18 a sealed key moved to another day does not unseal" do
      at(@noon)
      key_id = Audit.ip_hash_key_id()

      Repo.update_all(from(k in IpKey, where: k.id == ^key_id), set: [day: ~D[2031-03-11]])

      at(hours(24))
      assert_raise RuntimeError, ~r/does not unseal/, fn -> Audit.hash_ip(@ip) end
    end

    test "C01-T18 the database requires a key to be either sealed or destroyed, not both" do
      for {sealed, destroyed_at} <- [{nil, nil}, {<<0>>, DateTime.utc_now()}] do
        assert_raise Ecto.ConstraintError, ~r/destroyed/, fn ->
          Repo.transaction(fn ->
            Repo.insert!(%IpKey{
              day: ~D[2031-03-10],
              wrapping_key_id: "00000000",
              sealed_key: sealed,
              destroyed_at: destroyed_at
            })
          end)
        end
      end
    end
  end

  test "C01-T18 a hash without its key id (or the reverse) is rejected by the database" do
    for {hash, key_id} <- [{"abc", nil}, {nil, "0000abcd"}] do
      assert_raise Postgrex.Error, ~r/ip_hash_key_id/, fn ->
        Repo.transaction(fn ->
          Repo.insert_all("audit_log", [
            %{
              id: Ecto.UUID.dump!(Ecto.UUID.generate()),
              action: "test.constraint",
              ip_hash: hash,
              ip_hash_key_id: key_id,
              metadata: %{},
              occurred_at: DateTime.utc_now(),
              inserted_at: DateTime.utc_now()
            }
          ])
        end)
      end
    end
  end
end
