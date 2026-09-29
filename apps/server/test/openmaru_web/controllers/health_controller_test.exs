defmodule OpenmaruWeb.HealthControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  test "T02-T01 GET /healthz is 200 with db ok when the database answers", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert json_response(conn, 200) == %{"status" => "ok", "db" => "ok"}
  end

  test "T02-T01 GET /healthz is 503 degraded when the database check fails", %{conn: conn} do
    stub(Openmaru.HealthMock, :check_db, fn -> {:error, :unreachable} end)

    conn = get(conn, "/healthz")
    assert json_response(conn, 503) == %{"status" => "degraded", "db" => "error"}
  end
end
