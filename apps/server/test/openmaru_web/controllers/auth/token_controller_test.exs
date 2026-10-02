defmodule OpenmaruWeb.Auth.TokenControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  import Ecto.Query
  import OpenApiSpex.TestAssertions

  alias Openmaru.Accounts.PAT
  alias Openmaru.{ClockMock, Repo}

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @day 24 * 3600

  setup %{conn: conn} do
    stub(ClockMock, :now, fn -> @t0 end)
    user = insert!(:user)
    %{conn: sign_in(conn, user), user: user}
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp create_token(conn, params) do
    conn |> with_csrf() |> post(~p"/api/v1/me/tokens", params)
  end

  defp list_tokens(conn, query \\ %{}) do
    conn |> recycle() |> get(~p"/api/v1/me/tokens", query)
  end

  defp me_with(conn, token), do: conn |> fresh_conn() |> put_bearer(token) |> get(~p"/api/v1/me")

  defp pat_rows do
    Repo.query!("SELECT t::text FROM personal_access_tokens t").rows |> List.flatten()
  end

  # Counts UPDATEs of personal_access_tokens issued by this test's process.
  def handle_query(_event, _measurements, %{source: source, query: query}, %{pid: pid}) do
    if self() == pid and source == "personal_access_tokens" and
         String.starts_with?(query, "UPDATE"),
       do: send(pid, :pat_updated)
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  describe "POST /me/tokens" do
    test "C02-T01 returns om_pat_… once; the database stores only its SHA-256 and last4", %{
      conn: conn,
      user: user
    } do
      body = conn |> create_token(%{"name" => "laptop"}) |> json_response(201)

      assert "om_pat_" <> secret = token = body["token"]
      assert {:ok, bytes} = Base.url_decode64(secret, padding: false)
      assert byte_size(bytes) == 32
      assert body["name"] == "laptop"
      assert body["last4"] == String.slice(token, -4, 4)
      assert "pat_" <> _ = body["id"]
      assert body["expires_at"] == nil
      assert body["last_used_at"] == nil
      assert {:ok, _, 0} = DateTime.from_iso8601(body["created_at"])

      [row] =
        Repo.all(
          from p in "personal_access_tokens",
            select: %{user_id: p.user_id, token_hash: p.token_hash, last4: p.last4}
        )

      assert Ecto.UUID.cast!(row.user_id) == user.id
      assert row.token_hash == :crypto.hash(:sha256, token)
      assert row.last4 == String.slice(token, -4, 4)

      for text <- pat_rows() do
        refute text =~ secret
      end

      # Shown once: later reads never include it.
      listed = conn |> list_tokens() |> response(200)
      refute listed =~ secret
    end

    test "C02-T01 every token is new", %{conn: conn} do
      first = conn |> create_token(%{"name" => "a"}) |> json_response(201)
      second = conn |> create_token(%{"name" => "a"}) |> json_response(201)

      refute first["token"] == second["token"]
      refute first["id"] == second["id"]
    end

    test "C02-T01 ttl_days sets the expiry", %{conn: conn} do
      body = conn |> create_token(%{"name" => "ci", "ttl_days" => 30}) |> json_response(201)

      assert {:ok, expires_at, 0} = DateTime.from_iso8601(body["expires_at"])
      assert expires_at == DateTime.add(@t0, 30 * @day, :second)
    end

    test "C02-T01 a missing or too long name, or a bad ttl_days, is 422", %{conn: conn} do
      for params <- [
            %{},
            %{"name" => ""},
            %{"name" => "   "},
            %{"name" => String.duplicate("x", 101)},
            %{"name" => "x", "ttl_days" => 0},
            %{"name" => "x", "ttl_days" => 366},
            %{"name" => "x", "ttl_days" => "soon"}
          ] do
        assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => _}}} =
                 conn |> create_token(params) |> json_response(422),
               "expected #{inspect(params)} to be rejected"
      end

      assert pat_rows() == []
    end

    test "C02-T01 needs a session: anonymous is 401, a PAT is 403", %{conn: conn, user: user} do
      {:ok, token, _pat} = PAT.create(user, %{"name" => "cli"})

      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn
               |> fresh_conn()
               |> post(~p"/api/v1/me/tokens", %{"name" => "x"})
               |> json_response(401)

      assert %{"error" => %{"code" => "forbidden"}} =
               conn
               |> fresh_conn()
               |> put_bearer(token)
               |> post(~p"/api/v1/me/tokens", %{"name" => "x"})
               |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> fresh_conn() |> put_bearer(token) |> list_tokens() |> json_response(403)
    end

    test "C02-T01 needs x-csrf-token with the session cookie", %{conn: conn} do
      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> post(~p"/api/v1/me/tokens", %{"name" => "x"}) |> json_response(403)

      assert pat_rows() == []
    end

    test "C02-T01 with an Idempotency-Key the token is not kept for replays", %{conn: conn} do
      first =
        conn
        |> with_csrf()
        |> put_req_header("idempotency-key", "mint-1")
        |> post(~p"/api/v1/me/tokens", %{"name" => "x"})
        |> json_response(201)

      "om_pat_" <> secret = first["token"]
      bodies = Repo.all(from k in "idempotency_keys", select: k.body)
      refute Enum.any?(bodies, &(&1 && &1 =~ secret))

      # The key was released, so a retry mints a new token rather than replaying one.
      second =
        conn
        |> with_csrf()
        |> put_req_header("idempotency-key", "mint-1")
        |> post(~p"/api/v1/me/tokens", %{"name" => "x"})

      assert get_resp_header(second, "idempotent-replayed") == []
      refute json_response(second, 201)["token"] == first["token"]
    end
  end

  describe "last use" do
    setup do
      pid = self()
      id = {__MODULE__, pid}

      :ok =
        :telemetry.attach(id, [:openmaru, :repo, :query], &__MODULE__.handle_query/4, %{pid: pid})

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "C02-T03 last_used_at is written at most once per minute", %{conn: conn, user: user} do
      {:ok, token, pat} = PAT.create(user, %{"name" => "cli"})
      last_used = fn -> Repo.reload!(pat).last_used_at end

      assert conn |> me_with(token) |> json_response(200)
      assert_received :pat_updated
      assert last_used.() == @t0

      at(30)
      assert conn |> me_with(token) |> json_response(200)
      refute_received :pat_updated
      assert last_used.() == @t0

      at(59)
      assert conn |> me_with(token) |> json_response(200)
      refute_received :pat_updated
      assert last_used.() == @t0

      at(60)
      assert conn |> me_with(token) |> json_response(200)
      assert_received :pat_updated
      refute_received :pat_updated
      assert last_used.() == DateTime.add(@t0, 60, :second)
    end
  end

  describe "GET /me/tokens" do
    test "C02-T04 lists name, last4, created, last used and expiry — never the token", %{
      conn: conn,
      user: user
    } do
      {:ok, used, used_pat} = PAT.create(user, %{"name" => "used"})
      assert conn |> me_with(used) |> json_response(200)

      at(10)
      {:ok, expiring, expiring_pat} = PAT.create(user, %{"name" => "expiring", "ttl_days" => 7})

      at(20)
      {:ok, revoked, revoked_pat} = PAT.create(user, %{"name" => "revoked"})
      :ok = PAT.revoke(user, revoked_pat.id)

      {:ok, others, _pat} = PAT.create(insert!(:user), %{"name" => "someone else's"})

      response = conn |> list_tokens() |> response(200)
      body = Jason.decode!(response)

      for token <- [used, expiring, revoked, others] do
        "om_pat_" <> secret = token
        refute response =~ secret
      end

      assert body["next_cursor"] == nil

      assert [expiring_json, used_json] = body["data"]

      for item <- body["data"] do
        assert item |> Map.keys() |> Enum.sort() ==
                 ~w(created_at expires_at id last4 last_used_at name)
      end

      assert expiring_json == %{
               "id" => Openmaru.TypeID.encode("pat", expiring_pat.id),
               "name" => "expiring",
               "last4" => String.slice(expiring, -4, 4),
               "created_at" => DateTime.to_iso8601(DateTime.add(@t0, 10, :second)),
               "last_used_at" => nil,
               "expires_at" => DateTime.to_iso8601(DateTime.add(@t0, 10 + 7 * @day, :second))
             }

      assert used_json["id"] == Openmaru.TypeID.encode("pat", used_pat.id)
      assert used_json["last4"] == String.slice(used, -4, 4)
      assert used_json["last_used_at"] == DateTime.to_iso8601(@t0)
      assert used_json["expires_at"] == nil
    end

    test "C02-T04 pages with cursor and limit, newest first", %{conn: conn, user: user} do
      ids =
        for n <- 1..5 do
          at(n)
          {:ok, _token, pat} = PAT.create(user, %{"name" => "t#{n}"})
          Openmaru.TypeID.encode("pat", pat.id)
        end

      newest_first = Enum.reverse(ids)

      page1 = conn |> list_tokens(%{"limit" => "2"}) |> json_response(200)
      assert Enum.map(page1["data"], & &1["id"]) == Enum.take(newest_first, 2)
      assert is_binary(page1["next_cursor"])

      page2 =
        conn
        |> list_tokens(%{"limit" => "2", "cursor" => page1["next_cursor"]})
        |> json_response(200)

      assert Enum.map(page2["data"], & &1["id"]) == Enum.slice(newest_first, 2, 2)

      page3 =
        conn
        |> list_tokens(%{"limit" => "2", "cursor" => page2["next_cursor"]})
        |> json_response(200)

      assert Enum.map(page3["data"], & &1["id"]) == Enum.slice(newest_first, 4, 1)
      assert page3["next_cursor"] == nil

      for query <- [
            %{"limit" => "0"},
            %{"limit" => "101"},
            %{"limit" => "x"},
            %{"cursor" => "nope"}
          ] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn |> list_tokens(query) |> json_response(400)
      end
    end

    test "C02-T04 the responses match the OpenAPI schemas", %{conn: conn} do
      spec = OpenmaruWeb.ApiSpec.spec()

      for path <- ~w(/api/v1/me/tokens /api/v1/me/tokens/{id}) do
        assert Map.has_key?(spec.paths, path), "#{path} missing from the OpenAPI document"
      end

      created = conn |> create_token(%{"name" => "x", "ttl_days" => 1}) |> json_response(201)
      assert_schema(created, "NewPersonalAccessToken", spec)

      listed = conn |> list_tokens() |> json_response(200)
      assert_schema(listed, "PersonalAccessTokenList", spec)
    end
  end

  describe "DELETE /me/tokens/:id" do
    test "C02-T02 revoking a token makes it 401 invalid_token at once", %{conn: conn} do
      %{"id" => id, "token" => token} =
        conn |> create_token(%{"name" => "x"}) |> json_response(201)

      assert conn |> me_with(token) |> json_response(200)

      assert conn |> with_csrf() |> delete(~p"/api/v1/me/tokens/#{id}") |> response(204)

      assert %{"error" => %{"code" => "invalid_token"}} =
               conn |> me_with(token) |> json_response(401)

      assert conn |> list_tokens() |> json_response(200) |> Map.fetch!("data") == []

      # Revoking again is a no-op.
      assert conn |> with_csrf() |> delete(~p"/api/v1/me/tokens/#{id}") |> response(204)
    end

    test "C02-T02 another user's token, or an unknown id, is 404", %{conn: conn} do
      other = insert!(:user)
      {:ok, token, pat} = PAT.create(other, %{"name" => "theirs"})
      theirs = Openmaru.TypeID.encode("pat", pat.id)
      unknown = Openmaru.TypeID.encode("pat", Openmaru.UUIDv7.generate())

      for id <- [theirs, unknown, "pat_nope", "usr_" <> String.duplicate("0", 26)] do
        assert %{"error" => %{"code" => "not_found"}} =
                 conn |> with_csrf() |> delete(~p"/api/v1/me/tokens/#{id}") |> json_response(404)
      end

      assert conn |> me_with(token) |> json_response(200)
    end
  end
end
