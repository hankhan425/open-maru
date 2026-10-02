defmodule Openmaru.Audit.IpKeyRotationTest do
  # Changes the application's wrapping key, so it must not run beside other tests.
  use Openmaru.DataCase, async: false

  alias Openmaru.{Audit, ClockMock, Repo}
  alias Openmaru.Audit.IpKey

  @ip {203, 0, 113, 7}

  setup do
    config = Application.fetch_env!(:openmaru, Audit)
    on_exit(fn -> Application.put_env(:openmaru, Audit, config) end)
    stub(ClockMock, :now, fn -> ~U[2031-03-10 12:00:00.000000Z] end)
    %{config: config}
  end

  test "C01-T18 rotating the wrapping key leaves earlier keys unusable until the sweeper destroys them",
       %{config: config} do
    old_key_id = Audit.ip_hash_key_id()
    old_hash = Audit.hash_ip(@ip)

    Application.put_env(:openmaru, Audit, Keyword.put(config, :ip_key_wrapping_key, "rotated"))

    new_key_id = Audit.ip_hash_key_id()
    refute new_key_id == old_key_id
    refute Audit.hash_ip(@ip) == old_hash
    assert [%{ip_hash_key_id: ^new_key_id}] = Audit.hashes_for_ip(@ip)

    assert Audit.destroy_expired_ip_keys() >= 1
    assert Repo.get!(IpKey, old_key_id).sealed_key == nil
    assert Repo.get!(IpKey, new_key_id).sealed_key
  end
end
