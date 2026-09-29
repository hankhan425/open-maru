defmodule OpenmaruWeb.Plugs.RateLimitTest do
  use OpenmaruWeb.ConnCase, async: true

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

  test "C01-T17 non-auth endpoints are not limited by the auth budget", %{conn: conn} do
    inside_a_window()

    for _ <- 1..11, do: login_options(conn)

    user = insert!(:user)
    assert conn |> fresh_conn() |> sign_in(user) |> get(~p"/api/v1/me") |> json_response(200)
  end
end
