defmodule OpenmaruWeb.Plugs.ClientIPTest do
  # The last test changes the application env for the endpoint.
  use OpenmaruWeb.ConnCase, async: false

  import Ecto.Query

  alias Openmaru.{Audit, Repo}
  alias Openmaru.Test.FakeAuthenticator
  alias OpenmaruWeb.Plugs.ClientIP

  @lb {10, 0, 0, 5}

  defp resolve(peer, forwarded, proxies) do
    conn = %{build_conn() | remote_ip: peer}

    headers = for value <- List.wrap(forwarded), do: {"x-forwarded-for", value}
    conn = %{conn | req_headers: conn.req_headers ++ headers}

    ClientIP.call(conn, ClientIP.init(trusted_proxies: proxies)).remote_ip
  end

  test "C01-T17 without trusted proxies x-forwarded-for is ignored" do
    assert resolve(@lb, "203.0.113.7", []) == @lb
  end

  test "C01-T17 an untrusted peer cannot set its address with x-forwarded-for" do
    assert resolve({198, 51, 100, 1}, "203.0.113.7", ["10.0.0.0/8"]) == {198, 51, 100, 1}
  end

  test "C01-T17 behind a trusted proxy the client is the right-most untrusted hop" do
    proxies = ["10.0.0.0/8", "192.0.2.10"]

    assert resolve(@lb, "203.0.113.7", proxies) == {203, 0, 113, 7}
    # Left of the client is whatever the client sent: ignored.
    assert resolve(@lb, "1.1.1.1, 203.0.113.7", proxies) == {203, 0, 113, 7}
    # Trusted hops between the client and the load balancer are skipped.
    assert resolve(@lb, "1.1.1.1, 203.0.113.7, 192.0.2.10, 10.1.2.3", proxies) ==
             {203, 0, 113, 7}

    # Several headers read as one comma-separated list, in order.
    assert resolve(@lb, ["1.1.1.1", "203.0.113.7"], proxies) == {203, 0, 113, 7}
  end

  test "C01-T17 ports, brackets and IPv6 are understood" do
    proxies = ["10.0.0.0/8", "2001:db8:ffff::/48"]

    assert resolve(@lb, "203.0.113.7:51234", proxies) == {203, 0, 113, 7}
    assert resolve(@lb, "[2001:db8::1]:443", proxies) == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

    assert resolve({0x2001, 0xDB8, 0xFFFF, 0, 0, 0, 0, 1}, "2001:db8:1::9", proxies) ==
             {0x2001, 0xDB8, 1, 0, 0, 0, 0, 9}
  end

  test "C01-T17 a garbled hop stops the walk at the last trusted address" do
    proxies = ["10.0.0.0/8"]

    assert resolve(@lb, "203.0.113.7, not-an-ip, 10.1.2.3", proxies) == {10, 1, 2, 3}
    assert resolve(@lb, "", proxies) == @lb
  end

  test "C01-T17 IPv4-mapped IPv6 peers become IPv4" do
    mapped = {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}

    assert resolve(mapped, nil, []) == {203, 0, 113, 7}
  end

  test "C01-T17 invalid trusted proxies raise" do
    for bad <- ["10.0.0.0/33", "not-an-ip", "10.0.0.0/8/8", "2001:db8::/129", "10.0.0/8"] do
      assert_raise ArgumentError, ~r/invalid trusted proxy/, fn ->
        resolve(@lb, nil, [bad])
      end
    end
  end

  test "C01-T18 behind a configured proxy the audit log hashes the forwarded client IP", %{
    conn: conn
  } do
    original = Application.get_env(:openmaru, ClientIP)
    Application.put_env(:openmaru, ClientIP, trusted_proxies: ["10.0.0.0/8"])
    on_exit(fn -> Application.put_env(:openmaru, ClientIP, original) end)

    client = {203, 0, 113, 99}

    {conn, _auth} =
      conn
      |> fresh_conn()
      |> passkey_login(FakeAuthenticator.new(),
        headers: [{"x-forwarded-for", "203.0.113.99"}]
      )

    assert json_response(conn, 401)

    assert [ip_hash] =
             Repo.all(
               from e in "audit_log", where: e.action == "auth.sign_in_failed", select: e.ip_hash
             )

    assert ip_hash == Audit.hash_ip(client)
  end
end
