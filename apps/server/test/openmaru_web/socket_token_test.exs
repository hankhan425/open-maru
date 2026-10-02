defmodule OpenmaruWeb.SocketTokenTest do
  use OpenmaruWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias Openmaru.Accounts.PAT
  alias Openmaru.ClockMock
  alias OpenmaruWeb.SocketToken

  @t0 ~U[2026-03-01 12:00:00.000000Z]

  setup %{conn: conn} do
    stub(ClockMock, :now, fn -> @t0 end)
    user = insert!(:user)
    %{conn: sign_in(conn, user), user: user}
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp socket_token(conn), do: conn |> get(~p"/api/v1/socket-token") |> json_response(200)

  test "C02-T12 GET /socket-token returns a token valid for 5 minutes", %{conn: conn, user: user} do
    assert %{"token" => token, "expires_in" => 300} = socket_token(conn)

    assert SocketToken.verify_socket_token(token) == {:ok, user.id}

    at(299)
    assert SocketToken.verify_socket_token(token) == {:ok, user.id}
  end

  test "C02-T12 an expired socket token is {:error, :invalid}", %{conn: conn} do
    %{"token" => token} = socket_token(conn)

    at(300)
    assert SocketToken.verify_socket_token(token) == {:error, :invalid}

    at(3600)
    assert SocketToken.verify_socket_token(token) == {:error, :invalid}
  end

  test "C02-T12 a tampered socket token is {:error, :invalid}", %{conn: conn} do
    %{"token" => token} = socket_token(conn)

    for position <- [0, div(byte_size(token), 2), byte_size(token) - 1] do
      <<head::binary-size(^position), char, tail::binary>> = token
      # The last character of an unpadded base64url segment has unused low bits (A and B
      # can decode alike), so change its top two bits, which always carry data: A–P are
      # 0b00xxxx, `w` is 0b110000.
      replacement = if char in ?A..?P, do: ?w, else: ?A
      tampered = head <> <<replacement>> <> tail

      assert SocketToken.verify_socket_token(tampered) == {:error, :invalid}
    end

    assert SocketToken.verify_socket_token(token <> "x") == {:error, :invalid}
    assert SocketToken.verify_socket_token(String.slice(token, 0..-2//1)) == {:error, :invalid}
  end

  test "C02-T12 tokens signed for another purpose or garbage are {:error, :invalid}", %{
    user: user
  } do
    other = Phoenix.Token.sign(OpenmaruWeb.Endpoint, "user auth", user.id)

    for token <- [other, "", "nope", nil, 42, csrf_like()] do
      assert SocketToken.verify_socket_token(token) == {:error, :invalid}
    end
  end

  test "C02-T12 needs a signed-in user; a PAT also works", %{conn: conn, user: user} do
    assert %{"error" => %{"code" => "unauthenticated"}} =
             conn |> fresh_conn() |> get(~p"/api/v1/socket-token") |> json_response(401)

    {:ok, pat, _record} = PAT.create(user, %{"name" => "cli"})
    %{"token" => token} = conn |> fresh_conn() |> put_bearer(pat) |> socket_token()
    assert SocketToken.verify_socket_token(token) == {:ok, user.id}
  end

  test "C02-T12 the route is documented and matches the schema", %{conn: conn} do
    spec = OpenmaruWeb.ApiSpec.spec()
    assert Map.has_key?(spec.paths, "/api/v1/socket-token")
    assert_schema(socket_token(conn), "SocketToken", spec)
  end

  defp csrf_like, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
