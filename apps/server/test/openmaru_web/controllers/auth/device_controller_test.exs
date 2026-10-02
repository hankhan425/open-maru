defmodule OpenmaruWeb.Auth.DeviceControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  import Ecto.Query
  import OpenApiSpex.TestAssertions

  alias Openmaru.Accounts.{Device, PAT}
  alias Openmaru.{ClockMock, Repo, TypeID}

  @t0 ~U[2026-03-01 12:00:00.000000Z]
  @alphabet ~c"BCDFGHJKLMNPQRSTVWXZ23456789"
  @user_code ~r/\A[BCDFGHJKLMNPQRSTVWXZ23456789]{4}-[BCDFGHJKLMNPQRSTVWXZ23456789]{4}\z/
  @cli_agent "maru/0.1.0 (darwin; arm64)"

  setup %{conn: conn} do
    stub(ClockMock, :now, fn -> @t0 end)
    %{conn: put_req_header(conn, "user-agent", @cli_agent)}
  end

  defp at(seconds), do: stub(ClockMock, :now, fn -> DateTime.add(@t0, seconds, :second) end)

  defp start(conn), do: conn |> post(~p"/api/v1/auth/device/code", %{}) |> json_response(200)

  defp poll(conn, device_code) do
    conn
    |> fresh_conn()
    |> put_req_header("user-agent", @cli_agent)
    |> post(~p"/api/v1/auth/device/token", %{"device_code" => device_code})
  end

  defp poll_error(conn, device_code) do
    %{"error" => %{"code" => code}} = conn |> poll(device_code) |> json_response(400)
    code
  end

  defp browser(user), do: unique_ip() |> fresh_conn() |> sign_in(user)

  defp approve(browser, user_code, params \\ %{}) do
    browser
    |> with_csrf()
    |> post(~p"/api/v1/auth/device/approve", Map.put(params, "user_code", user_code))
  end

  describe "POST /auth/device/code" do
    test "C02-T05 returns a device code, a user code, the verification URI, interval and expiry",
         %{conn: conn} do
      body = start(conn)

      assert byte_size(body["device_code"]) >= 43
      assert body["user_code"] =~ @user_code
      assert body["verification_uri"] == "http://localhost:5173/device"

      assert body["verification_uri_complete"] ==
               "http://localhost:5173/device?user_code=" <> body["user_code"]

      assert body["interval"] == 5
      assert body["expires_in"] == 600
    end

    test "C02-T05 only a hash of the device code is stored", %{conn: conn} do
      %{"device_code" => device_code} = start(conn)

      [{hash, expires_at}] =
        Repo.all(from d in "device_codes", select: {d.device_code_hash, d.expires_at})

      assert hash == :crypto.hash(:sha256, device_code)
      assert DateTime.from_naive!(expires_at, "Etc/UTC") == DateTime.add(@t0, 600, :second)

      for text <- Repo.query!("SELECT d::text FROM device_codes d").rows |> List.flatten() do
        refute text =~ device_code
      end
    end

    test "C02-T05 user codes use only the unambiguous alphabet, eight characters" do
      codes =
        for _ <- 1..200 do
          {:ok, %{user_code: user_code}} = Device.start()
          assert user_code =~ @user_code
          user_code
        end

      assert codes |> Enum.uniq() |> length() == 200

      used =
        codes |> Enum.join() |> String.replace("-", "") |> String.to_charlist() |> MapSet.new()

      assert MapSet.subset?(used, MapSet.new(@alphabet))
      # 1,600 draws from 28 symbols: every symbol shows up.
      assert MapSet.size(used) == length(@alphabet)
    end

    test "C02-T05 the routes are documented and responses match the schemas", %{conn: conn} do
      spec = OpenmaruWeb.ApiSpec.spec()

      for path <-
            ~w(/api/v1/auth/device/code /api/v1/auth/device/token /api/v1/auth/device/approve) do
        assert Map.has_key?(spec.paths, path), "#{path} missing from the OpenAPI document"
      end

      body = start(conn)
      assert_schema(body, "DeviceAuthorization", spec)

      approve(browser(insert!(:user)), body["user_code"])

      assert_schema(
        conn |> poll(body["device_code"]) |> json_response(200),
        "NewPersonalAccessToken",
        spec
      )
    end
  end

  describe "POST /auth/device/token" do
    test "C02-T06 polling before approval is authorization_pending; polls under 5 s apart are slow_down",
         %{conn: conn} do
      %{"device_code" => device_code} = start(conn)

      assert poll_error(conn, device_code) == "authorization_pending"

      at(4)
      assert poll_error(conn, device_code) == "slow_down"

      at(10)
      assert poll_error(conn, device_code) == "authorization_pending"
    end

    test "C02-T06 a poll exactly 5 s after the previous one is in time", %{conn: conn} do
      %{"device_code" => device_code} = start(conn)

      assert poll_error(conn, device_code) == "authorization_pending"

      at(5)
      assert poll_error(conn, device_code) == "authorization_pending"
    end

    test "C02-T06 a too-fast poll restarts the interval", %{conn: conn} do
      %{"device_code" => device_code} = start(conn)

      assert poll_error(conn, device_code) == "authorization_pending"
      at(3)
      assert poll_error(conn, device_code) == "slow_down"
      at(6)
      assert poll_error(conn, device_code) == "slow_down"
      at(11)
      assert poll_error(conn, device_code) == "authorization_pending"
    end

    test "C02-T07 after approval the next poll returns a PAT named CLI (<user agent>); a further poll is invalid_grant",
         %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)
      user = insert!(:user)

      assert poll_error(conn, device_code) == "authorization_pending"

      at(5)

      assert %{"status" => "approved"} =
               user |> browser() |> approve(user_code) |> json_response(200)

      at(10)
      body = conn |> poll(device_code) |> json_response(200)

      assert "om_pat_" <> _ = token = body["token"]
      assert body["name"] == "CLI (#{@cli_agent})"
      assert body["last4"] == String.slice(token, -4, 4)
      assert body["expires_at"] == nil

      assert {:ok, verified, _pat} = PAT.verify(token)
      assert verified.id == user.id

      assert conn
             |> fresh_conn()
             |> put_bearer(token)
             |> get(~p"/api/v1/me")
             |> json_response(200)
             |> Map.fetch!("id") == TypeID.encode("usr", user.id)

      assert poll_error(conn, device_code) == "invalid_grant"

      at(20)
      assert poll_error(conn, device_code) == "invalid_grant"
    end

    test "C02-T07 the PAT is stored hashed and not kept for idempotent replays", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)
      approve(browser(insert!(:user)), user_code)

      body =
        conn
        |> fresh_conn()
        |> put_req_header("idempotency-key", "poll-1")
        |> post(~p"/api/v1/auth/device/token", %{"device_code" => device_code})
        |> json_response(200)

      "om_pat_" <> secret = body["token"]

      for text <- Repo.query!("SELECT k::text FROM idempotency_keys k").rows |> List.flatten() do
        refute text =~ secret
      end
    end

    test "C02-T07 a client without a user agent gets a plain CLI name", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} =
        conn |> fresh_conn() |> start()

      approve(browser(insert!(:user)), user_code)

      body =
        conn
        |> fresh_conn()
        |> post(~p"/api/v1/auth/device/token", %{"device_code" => device_code})
        |> json_response(200)

      assert body["name"] == "CLI"
    end

    test "C02-T07 a long user agent is shortened to fit the name", %{conn: conn} do
      agent = "maru/" <> String.duplicate("x", 300)

      %{"device_code" => device_code, "user_code" => user_code} =
        conn |> put_req_header("user-agent", agent) |> start()

      approve(browser(insert!(:user)), user_code)
      body = conn |> poll(device_code) |> json_response(200)

      assert String.length(body["name"]) <= 100
      assert String.starts_with?(body["name"], "CLI (maru/xxx")
      assert String.ends_with?(body["name"], ")")
    end

    test "C02-T08 an expired code is expired_token", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)

      at(599)
      assert poll_error(conn, device_code) == "authorization_pending"

      at(600)
      assert poll_error(conn, device_code) == "expired_token"

      # Approving it now is refused too.
      assert %{"error" => %{"code" => "expired_token"}} =
               insert!(:user) |> browser() |> approve(user_code) |> json_response(400)

      at(700)
      assert poll_error(conn, device_code) == "expired_token"
    end

    test "C02-T08 an approved code that expires before the poll is expired_token", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)
      approve(browser(insert!(:user)), user_code)

      at(600)
      assert poll_error(conn, device_code) == "expired_token"
      assert Repo.all(from p in "personal_access_tokens", select: p.id) == []
    end

    test "C02-T08 a denied code is access_denied", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)

      assert %{"status" => "denied"} =
               insert!(:user)
               |> browser()
               |> approve(user_code, %{"decision" => "deny"})
               |> json_response(200)

      assert poll_error(conn, device_code) == "access_denied"
      at(5)
      assert poll_error(conn, device_code) == "access_denied"
      assert Repo.all(from p in "personal_access_tokens", select: p.id) == []
    end

    test "C02-T08 an unknown device code is invalid_grant; a missing one is invalid_request", %{
      conn: conn
    } do
      assert poll_error(conn, "not-a-device-code") == "invalid_grant"

      for params <- [%{}, %{"device_code" => ""}, %{"device_code" => 42}] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn
                 |> fresh_conn()
                 |> post(~p"/api/v1/auth/device/token", params)
                 |> json_response(400)
      end
    end

    test "C02-T08 a suspended approver's code is access_denied", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)
      user = insert!(:user)
      approve(browser(user), user_code)

      Repo.update_all(from(u in Openmaru.Accounts.User, where: u.id == ^user.id),
        set: [suspended_at: @t0]
      )

      assert poll_error(conn, device_code) == "access_denied"
      assert Repo.all(from p in "personal_access_tokens", select: p.id) == []
    end
  end

  describe "POST /auth/device/approve" do
    test "C02-T08 an unknown user code is 404", %{conn: conn} do
      start(conn)
      browser = browser(insert!(:user))

      for user_code <- ["BCDF-GHJK", "AAAA-AAAA", "short", "", "BCDF-GHJK-LMNP"] do
        assert %{"error" => %{"code" => "not_found"}} =
                 browser |> approve(user_code) |> json_response(404),
               "expected #{inspect(user_code)} to be unknown"
      end
    end

    test "C02-T08 user codes are matched ignoring case, spaces and the hyphen", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)
      typed = user_code |> String.downcase() |> String.replace("-", " ")

      assert %{"status" => "approved"} =
               insert!(:user) |> browser() |> approve(" " <> typed <> " ") |> json_response(200)

      assert conn |> poll(device_code) |> json_response(200)
    end

    test "C02-T08 a code can be decided once", %{conn: conn} do
      %{"user_code" => user_code} = start(conn)
      browser = browser(insert!(:user))

      assert browser |> approve(user_code) |> json_response(200)

      for params <- [%{}, %{"decision" => "deny"}] do
        assert %{"error" => %{"code" => "invalid_grant"}} =
                 browser |> approve(user_code, params) |> json_response(400)
      end

      assert %{"error" => %{"code" => "invalid_grant"}} =
               insert!(:user) |> browser() |> approve(user_code) |> json_response(400)
    end

    test "C02-T08 the approving user owns the PAT and the decision is audited", %{conn: conn} do
      %{"device_code" => device_code, "user_code" => user_code} = start(conn)
      user = insert!(:user)
      approve(browser(user), user_code)
      %{"id" => pat_id} = conn |> poll(device_code) |> json_response(200)

      actions =
        Repo.all(
          from a in "audit_log",
            where: a.actor_id == type(^user.id, Ecto.UUID),
            select: {a.action, a.target_type}
        )

      assert {"auth.device_approved", "device_code"} in actions
      assert {"pat.created", "personal_access_token"} in actions

      [owner] =
        Repo.all(
          from p in "personal_access_tokens",
            where: p.id == type(^uuid!(pat_id, "pat"), Ecto.UUID),
            select: p.user_id
        )

      assert Ecto.UUID.cast!(owner) == user.id
    end

    test "C02-T08 approving needs a signed-in session and x-csrf-token", %{conn: conn} do
      %{"user_code" => user_code} = start(conn)

      assert %{"error" => %{"code" => "unauthenticated"}} =
               conn
               |> fresh_conn()
               |> post(~p"/api/v1/auth/device/approve", %{"user_code" => user_code})
               |> json_response(401)

      assert %{"error" => %{"code" => "forbidden"}} =
               insert!(:user)
               |> browser()
               |> post(~p"/api/v1/auth/device/approve", %{"user_code" => user_code})
               |> json_response(403)
    end

    test "C02-T08 an unknown decision or a missing user code is rejected", %{conn: conn} do
      %{"user_code" => user_code} = start(conn)
      browser = browser(insert!(:user))

      assert %{"error" => %{"code" => "validation_failed"}} =
               browser |> approve(user_code, %{"decision" => "maybe"}) |> json_response(422)

      assert %{"error" => %{"code" => "invalid_request"}} =
               browser
               |> with_csrf()
               |> post(~p"/api/v1/auth/device/approve", %{})
               |> json_response(400)
    end
  end

  describe "pruning" do
    test "C02-T08 the hourly job deletes device codes a day after they expire", %{conn: conn} do
      %{"device_code" => old} = start(conn)

      at(600 + 24 * 3600)

      %{"device_code" => recent} =
        start(conn |> fresh_conn() |> put_req_header("user-agent", "x"))

      Openmaru.Accounts.prune()

      hashes = Repo.all(from d in "device_codes", select: d.device_code_hash)
      assert hashes == [:crypto.hash(:sha256, recent)]
      refute :crypto.hash(:sha256, old) in hashes
    end
  end
end
