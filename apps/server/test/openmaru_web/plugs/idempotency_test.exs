defmodule OpenmaruWeb.Plugs.IdempotencyTest do
  use OpenmaruWeb.ConnCase, async: true

  alias Openmaru.ClockMock
  alias OpenmaruWeb.Plugs.Idempotency

  @t0 ~U[2026-03-01 12:00:00.000000Z]

  setup do
    stub(ClockMock, :now, fn -> @t0 end)
    :ok
  end

  # Runs the plug and, unless it halted, a stand-in controller action that reports each
  # execution to the test process and answers with a body unique to that execution.
  defp request(body, opts \\ []) do
    conn =
      build_conn(Keyword.get(opts, :method, :post), "/api/v1/widgets", body)
      |> maybe_put_key(Keyword.get(opts, :key, "key-1"))
      |> maybe_assign_actor(Keyword.get(opts, :actor))
      |> Idempotency.call(Idempotency.init([]))

    if conn.halted do
      conn
    else
      send(self(), :executed)
      status = Keyword.get(opts, :status, 201)

      conn
      |> put_status(status)
      |> Phoenix.Controller.json(%{"execution" => System.unique_integer([:positive])})
    end
  end

  defp maybe_put_key(conn, nil), do: conn
  defp maybe_put_key(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp maybe_assign_actor(conn, nil), do: conn
  defp maybe_assign_actor(conn, actor), do: assign(conn, :current_actor, actor)

  defp count_executions(acc \\ 0) do
    receive do
      :executed -> count_executions(acc + 1)
    after
      0 -> acc
    end
  end

  test "T02-T08 same key and body twice replays the original response; action runs once" do
    first = request(%{"name" => "a", "n" => 1})
    second = request(%{"n" => 1, "name" => "a"})

    assert count_executions() == 1
    assert second.status == first.status
    assert second.status == 201
    assert second.resp_body == first.resp_body
    assert second.halted
    assert get_resp_header(second, "idempotent-replayed") == ["true"]
    assert ["application/json" <> _] = get_resp_header(second, "content-type")
  end

  test "T02-T09 same key with a different body is 409 idempotency_conflict" do
    request(%{"name" => "a"})
    conflict = request(%{"name" => "b"})

    assert count_executions() == 1

    assert %{"error" => %{"code" => "idempotency_conflict", "details" => %{}}} =
             json_response(conflict, 409)
  end

  test "T02-T10 a key expires after 24 h; a replay after expiry executes again" do
    first = request(%{"name" => "a"})

    stub(ClockMock, :now, fn -> DateTime.add(@t0, 24 * 3600, :second) end)
    second = request(%{"name" => "a"})

    assert count_executions() == 2
    assert second.status == 201
    refute second.resp_body == first.resp_body

    # The re-executed response is what later replays return.
    stub(ClockMock, :now, fn -> DateTime.add(@t0, 25 * 3600, :second) end)
    third = request(%{"name" => "a"})
    assert count_executions() == 0
    assert third.resp_body == second.resp_body
  end

  test "T02-T10 a key is still replayed one second before it expires" do
    first = request(%{"name" => "a"})

    stub(ClockMock, :now, fn -> DateTime.add(@t0, 24 * 3600 - 1, :second) end)
    second = request(%{"name" => "a"})

    assert count_executions() == 1
    assert second.resp_body == first.resp_body
  end

  test "T02-T08 requests without an Idempotency-Key are not deduplicated" do
    request(%{"name" => "a"}, key: nil)
    request(%{"name" => "a"}, key: nil)

    assert count_executions() == 2
  end

  test "T02-T08 safe methods are never deduplicated" do
    request(%{}, method: :get)
    request(%{}, method: :get)

    assert count_executions() == 2
  end

  test "T02-T08 keys are scoped per principal" do
    alice = {:person, %{id: "0190c1f4-0000-7000-8000-000000000001"}}
    bob = {:person, %{id: "0190c1f4-0000-7000-8000-000000000002"}}

    a = request(%{"name" => "a"}, actor: alice)
    b = request(%{"name" => "a"}, actor: bob)
    a2 = request(%{"name" => "a"}, actor: alice)

    assert count_executions() == 2
    refute a.resp_body == b.resp_body
    assert a2.resp_body == a.resp_body
  end

  test "T02-T08 the method and path are part of the request fingerprint" do
    request(%{"name" => "a"})
    conflict = request(%{"name" => "a"}, method: :put)

    assert count_executions() == 1
    assert %{"error" => %{"code" => "idempotency_conflict"}} = json_response(conflict, 409)
  end

  test "T02-T08 server errors are not stored, so a retry executes again" do
    request(%{"name" => "a"}, status: 500)
    retry = request(%{"name" => "a"})

    assert count_executions() == 2
    assert retry.status == 201
  end

  test "T02-T08 a request still in progress under the same key is a conflict" do
    insert!(:idempotency_key,
      key: "key-1",
      principal: "anonymous:127.0.0.1",
      request_hash: "in-flight",
      status: nil,
      body: nil,
      expires_at: DateTime.add(@t0, 3600, :second)
    )

    conflict = request(%{"name" => "a"})

    assert count_executions() == 0
    assert %{"error" => %{"code" => "idempotency_conflict"}} = json_response(conflict, 409)
  end

  test "T02-T08 an over-long key is rejected as invalid_request" do
    conn = request(%{"name" => "a"}, key: String.duplicate("k", 256))

    assert count_executions() == 0
    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
  end

  test "T02-T08 stored rows use UUIDv7 primary keys and the Clock for expiry" do
    request(%{"name" => "a"})

    [row] = Openmaru.Repo.all(Openmaru.Idempotency.Key)
    assert <<_::48, 7::4, _::bitstring>> = Ecto.UUID.dump!(row.id)
    assert row.expires_at == DateTime.add(@t0, 24 * 3600, :second)
    assert row.status == 201
  end

  test "T02-T08 an in-progress key abandoned for 5 minutes can be retried" do
    request(%{"name" => "a"}, status: 201)
    Openmaru.Repo.update_all(Openmaru.Idempotency.Key, set: [status: nil, body: nil])

    stub(ClockMock, :now, fn -> DateTime.add(@t0, 5 * 60, :second) end)
    retry = request(%{"name" => "a"})

    assert count_executions() == 2
    assert retry.status == 201
  end

  test "T02-T08 agent and mandate actors are scoped by kind and id" do
    agent = {:agent, %{id: "0190c1f4-0000-7000-8000-000000000003"}, %{}}
    person = {:person, %{id: "0190c1f4-0000-7000-8000-000000000003"}}

    request(%{"name" => "a"}, actor: agent)
    request(%{"name" => "a"}, actor: person)
    request(%{"name" => "a"}, actor: agent)

    assert count_executions() == 2

    assert Openmaru.Idempotency.Key
           |> Openmaru.Repo.all()
           |> Enum.map(& &1.principal)
           |> Enum.sort() ==
             [
               "agent:0190c1f4-0000-7000-8000-000000000003",
               "person:0190c1f4-0000-7000-8000-000000000003"
             ]
  end
end
