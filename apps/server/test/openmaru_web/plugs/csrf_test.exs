defmodule OpenmaruWeb.Plugs.CSRFTest do
  use OpenmaruWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert!(:user)
    %{conn: sign_in(conn, user), user: user}
  end

  test "C01-T16 a cookie-authenticated POST without x-csrf-token is 403", %{conn: conn} do
    assert %{"error" => %{"code" => "forbidden"}} =
             conn |> post(~p"/api/v1/auth/logout") |> json_response(403)

    # The session survived the rejected request.
    assert conn |> get(~p"/api/v1/me") |> json_response(200)
  end

  test "C01-T16 a cookie-authenticated POST with a wrong x-csrf-token is 403", %{conn: conn} do
    other = conn |> fresh_conn() |> sign_in(insert!(:user)) |> csrf_token()

    for token <- ["wrong", "", other, csrf_token(conn) <> "x"] do
      assert %{"error" => %{"code" => "forbidden"}} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(~p"/api/v1/auth/logout")
               |> json_response(403)
    end
  end

  test "C01-T16 a cookie-authenticated POST with the correct x-csrf-token is OK", %{conn: conn} do
    assert conn |> with_csrf() |> post(~p"/api/v1/auth/logout") |> response(204)
  end

  test "C01-T16 PATCH is protected too", %{conn: conn} do
    assert %{"error" => %{"code" => "forbidden"}} =
             conn |> patch(~p"/api/v1/me", %{"display_name" => "x"}) |> json_response(403)

    assert conn
           |> with_csrf()
           |> patch(~p"/api/v1/me", %{"display_name" => "x"})
           |> json_response(200)
  end

  test "C01-T16 GET is unaffected", %{conn: conn} do
    assert conn |> get(~p"/api/v1/me") |> json_response(200)

    assert conn
           |> put_req_header("x-csrf-token", "wrong")
           |> get(~p"/api/v1/me")
           |> json_response(200)
  end

  test "C01-T16 requests without a session cookie need no token", %{conn: conn} do
    assert conn
           |> fresh_conn()
           |> post(~p"/api/v1/auth/passkey/login/options", %{})
           |> json_response(200)

    # A stale cookie is not a session either.
    assert conn
           |> fresh_conn()
           |> put_req_cookie(session_cookie(), "stale")
           |> post(~p"/api/v1/auth/passkey/login/options", %{})
           |> json_response(200)
  end

  test "C01-T16 the CSRF token is stable per session and differs between sessions", %{
    conn: conn,
    user: user
  } do
    token = csrf_token(conn)
    assert csrf_token(conn) == token
    assert byte_size(token) >= 43

    refute conn |> fresh_conn() |> sign_in(user) |> csrf_token() == token
  end

  test "C01-T16 GET /auth/csrf without a session is 401", %{conn: conn} do
    assert %{"error" => %{"code" => "unauthenticated"}} =
             conn |> fresh_conn() |> get(~p"/api/v1/auth/csrf") |> json_response(401)
  end
end
