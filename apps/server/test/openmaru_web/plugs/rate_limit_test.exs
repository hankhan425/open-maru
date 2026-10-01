defmodule OpenmaruWeb.Plugs.RateLimitTest do
  use OpenmaruWeb.ConnCase, async: true

  alias OpenmaruWeb.Plugs.RateLimit

  # The limiter uses fixed one-minute windows aligned to the clock; start well inside one
  # so eleven quick requests cannot straddle a boundary.
  defp inside_a_window do
    remainder = rem(System.system_time(:millisecond), 60_000)
    if remainder > 55_000, do: Process.sleep(60_000 - remainder + 50)
  end

  defp login_options(conn),
    do: conn |> fresh_conn() |> post(~p"/api/v1/auth/passkey/login/options", %{})

  test "C01-T17 the 11th auth request in a minute from one IP is 429 rate_limited", %{conn: conn} do
    inside_a_window()

    for _ <- 1..10, do: assert(conn |> login_options() |> json_response(200))

    limited = login_options(conn)
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(limited, 429)
    assert [retry_after] = get_resp_header(limited, "retry-after")
    assert String.to_integer(retry_after) in 1..60

    # Another IP is unaffected.
    other = fresh_conn(unique_ip())
    assert other |> login_options() |> json_response(200)
  end

  test "C01-T17 all auth endpoints share the per-IP budget", %{conn: conn} do
    inside_a_window()

    for _ <- 1..5 do
      assert conn |> login_options() |> json_response(200)

      assert conn
             |> fresh_conn()
             |> post(~p"/api/v1/auth/passkey/register/options", %{})
             |> json_response(200)
    end

    assert %{"error" => %{"code" => "rate_limited"}} =
             conn |> fresh_conn() |> get(~p"/api/v1/auth/oauth/github") |> json_response(429)
  end

  # An IPv6 /64 no other test uses (2001:db8:<n>::/64).
  defp unique_ipv6_net do
    n = System.unique_integer([:positive, :monotonic])
    {0x2001, 0xDB8, rem(div(n, 65_535), 65_536), rem(n, 65_535)}
  end

  defp ipv6({a, b, c, d}, host), do: {a, b, c, d, 0, 0, 0, host}

  test "C01-T17 IPv6 clients share a budget per /64", %{conn: _conn} do
    inside_a_window()
    net = unique_ipv6_net()

    # Ten addresses in one /64 spend its whole budget.
    for host <- 1..10,
        do: assert(net |> ipv6(host) |> fresh_conn() |> login_options() |> json_response(200))

    assert %{"error" => %{"code" => "rate_limited"}} =
             net |> ipv6(0xBEEF) |> fresh_conn() |> login_options() |> json_response(429)

    # The next /64 has its own.
    {a, b, c, d} = net
    assert {a, b, c, d + 1} |> ipv6(1) |> fresh_conn() |> login_options() |> json_response(200)
  end

  test "C01-T17 the client key is the IPv4 address or the IPv6 /64" do
    assert RateLimit.client_key({203, 0, 113, 7}) == {203, 0, 113, 7}

    assert RateLimit.client_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) ==
             RateLimit.client_key({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1})

    refute RateLimit.client_key({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
             RateLimit.client_key({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})
  end

  test "C01-T17 the auth limit comes from config; plug options override it" do
    assert [limit: 10, scale_ms: 60_000] =
             Application.fetch_env!(:openmaru, RateLimit)[:limits][:auth]

    inside_a_window()
    opts = RateLimit.init(bucket: :override_test, limit: 2, scale_ms: 60_000)
    conn = fresh_conn(unique_ip())

    refute RateLimit.call(conn, opts).halted
    refute RateLimit.call(conn, opts).halted
    assert %{status: 429, halted: true} = RateLimit.call(conn, opts)
  end

  test "C01-T17 a bucket without a configured limit raises" do
    opts = RateLimit.init(bucket: :unconfigured)

    assert_raise ArgumentError, ~r/no limit configured/, fn ->
      RateLimit.call(fresh_conn(unique_ip()), opts)
    end
  end

  test "C01-T17 non-auth endpoints are not limited by the auth budget", %{conn: conn} do
    inside_a_window()

    for _ <- 1..11, do: login_options(conn)

    user = insert!(:user)
    assert conn |> fresh_conn() |> sign_in(user) |> get(~p"/api/v1/me") |> json_response(200)
  end
end
