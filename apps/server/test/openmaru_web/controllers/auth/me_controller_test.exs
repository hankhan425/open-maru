defmodule OpenmaruWeb.Auth.MeControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  alias Openmaru.Accounts.User
  alias Openmaru.Repo
  alias OpenmaruWeb.Auth.UserJSON

  defp patch_me(conn, params), do: conn |> with_csrf() |> patch(~p"/api/v1/me", params)

  describe "PATCH /me handle" do
    setup %{conn: conn} do
      user = insert!(:user, handle: nil)
      %{conn: sign_in(conn, user), user: user}
    end

    test "C01-T10 a valid handle is set", %{conn: conn, user: user} do
      body = conn |> patch_me(%{"handle" => "alice_1-x"}) |> json_response(200)

      assert body["handle"] == "alice_1-x"
      assert Repo.get!(User, user.id).handle == "alice_1-x"
    end

    test "C01-T10 handles are normalized to lower case", %{conn: conn, user: user} do
      body = conn |> patch_me(%{"handle" => "Alice"}) |> json_response(200)

      assert body["handle"] == "alice"
      assert Repo.get!(User, user.id).handle == "alice"
    end

    test "C01-T10 an invalid pattern is 422", %{conn: conn, user: user} do
      for handle <- [
            "a",
            "-alice",
            "_alice",
            "al ice",
            "alice!",
            "ålice",
            String.duplicate("a", 31),
            "",
            123
          ] do
        conn = conn |> patch_me(%{"handle" => handle})

        assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => fields}}} =
                 json_response(conn, 422),
               "expected #{inspect(handle)} to be rejected"

        assert Map.has_key?(fields, "handle")
      end

      assert Repo.get!(User, user.id).handle == nil
    end

    test "C01-T10 the longest and shortest valid handles are accepted", %{conn: conn} do
      assert conn |> patch_me(%{"handle" => "ab"}) |> json_response(200)

      other = insert!(:user, handle: nil)
      longest = String.duplicate("a", 30)

      assert conn
             |> fresh_conn()
             |> sign_in(other)
             |> patch_me(%{"handle" => longest})
             |> json_response(200)
    end

    test "C01-T10 a reserved handle is 422", %{conn: conn, user: user} do
      for handle <-
            ~w(admin api app auth help mcp openmaru root settings support system www gw Admin WWW) do
        assert %{"error" => %{"code" => "validation_failed"}} =
                 conn |> patch_me(%{"handle" => handle}) |> json_response(422)
      end

      assert Repo.get!(User, user.id).handle == nil
    end

    test "C01-T10 a handle taken case-insensitively is 409 handle_taken", %{
      conn: conn,
      user: user
    } do
      insert!(:user, handle: "bob")

      assert %{"error" => %{"code" => "handle_taken"}} =
               conn |> patch_me(%{"handle" => "BOB"}) |> json_response(409)

      assert Repo.get!(User, user.id).handle == nil
    end

    test "C01-T10 display_name can be updated with or without a handle", %{conn: conn} do
      body = conn |> patch_me(%{"display_name" => "  Alice Liddell "}) |> json_response(200)
      assert body["display_name"] == "Alice Liddell"
      assert body["handle"] == nil

      body =
        conn |> patch_me(%{"display_name" => "Alice", "handle" => "alice"}) |> json_response(200)

      assert body["display_name"] == "Alice"
      assert body["handle"] == "alice"

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn
               |> patch_me(%{"display_name" => String.duplicate("x", 81)})
               |> json_response(422)
    end

    test "C01-T10 fields other than handle and display_name are ignored", %{
      conn: conn,
      user: user
    } do
      conn
      |> patch_me(%{"platform_role" => "admin", "email" => "x@example.com"})
      |> json_response(200)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.platform_role == "user"
      assert reloaded.email == user.email
    end

    test "C01-T11 changing an already-set handle is invalid_request with handle_immutable", %{
      conn: conn,
      user: user
    } do
      assert conn |> patch_me(%{"handle" => "alice"}) |> json_response(200)

      # SPEC-07 §2 maps invalid_request to 400; the task's "422" is OQ-5.
      assert %{
               "error" => %{
                 "code" => "invalid_request",
                 "details" => %{"reason" => "handle_immutable"}
               }
             } = conn |> patch_me(%{"handle" => "alice2"}) |> json_response(400)

      assert Repo.get!(User, user.id).handle == "alice"
    end

    test "C01-T11 re-sending the same handle is a no-op", %{conn: conn} do
      assert conn |> patch_me(%{"handle" => "alice"}) |> json_response(200)

      assert %{"handle" => "alice"} =
               conn |> patch_me(%{"handle" => "ALICE"}) |> json_response(200)
    end

    test "C01-T11 a handle cannot be cleared", %{conn: conn} do
      assert conn |> patch_me(%{"handle" => "alice"}) |> json_response(200)

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn |> patch_me(%{"handle" => nil}) |> json_response(400)
    end
  end

  describe "GET /me" do
    test "C01-T12 without a session is 401 unauthenticated", %{conn: conn} do
      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn |> get(~p"/api/v1/me") |> json_response(401)
    end

    test "C01-T12 an unknown session cookie is 401 unauthenticated", %{conn: conn} do
      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn
               |> put_req_cookie(session_cookie(), "not-a-session")
               |> get(~p"/api/v1/me")
               |> json_response(401)
    end

    test "C01-T12 with a session returns the user including their own email", %{conn: conn} do
      user = insert!(:user, handle: "alice", display_name: "Alice", email: "alice@example.com")

      body = conn |> sign_in(user) |> get(~p"/api/v1/me") |> json_response(200)

      assert body["id"] == Openmaru.TypeID.encode("usr", user.id)
      assert body["handle"] == "alice"
      assert body["display_name"] == "Alice"
      assert body["email"] == "alice@example.com"
      assert body["platform_role"] == "user"
      assert {:ok, _, 0} = DateTime.from_iso8601(body["created_at"])
    end

    test "C01-T12 the auth routes are documented and /me matches the User schema", %{conn: conn} do
      spec = OpenmaruWeb.ApiSpec.spec()

      for path <- ~w(/api/v1/auth/passkey/register/options /api/v1/auth/passkey/register
                     /api/v1/auth/passkey/login/options /api/v1/auth/passkey/login
                     /api/v1/auth/oauth/{provider} /api/v1/auth/oauth/{provider}/callback
                     /api/v1/auth/csrf /api/v1/auth/logout /api/v1/me) do
        assert Map.has_key?(spec.paths, path), "#{path} missing from the OpenAPI document"
      end

      user = insert!(:user, handle: "alice", email: nil)
      body = conn |> sign_in(user) |> get(~p"/api/v1/me") |> json_response(200)
      assert_schema(body, "User", spec)

      anonymous = %{UserJSON.user(user, nil) | created_at: DateTime.to_iso8601(user.inserted_at)}
      assert_schema(Jason.decode!(Jason.encode!(anonymous)), "User", spec)
    end

    test "C01-T12 user JSON has no email for other viewers" do
      user = insert!(:user, email: "alice@example.com")
      other = insert!(:user)

      own = UserJSON.user(user, user)
      assert own.email == "alice@example.com"

      for viewer <- [other, nil] do
        public = UserJSON.user(user, viewer)
        refute Map.has_key?(public, :email)
        refute Map.has_key?(public, :platform_role)
        assert public.id == Openmaru.TypeID.encode("usr", user.id)
      end
    end
  end
end
