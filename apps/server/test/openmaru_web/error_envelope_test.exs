defmodule OpenmaruWeb.ErrorEnvelopeTest do
  use OpenmaruWeb.ConnCase, async: true

  test "T02-T03 unknown route renders the not_found envelope", %{conn: conn} do
    conn = get(conn, "/api/v1/nope")

    assert %{"error" => %{"code" => "not_found", "message" => message, "details" => %{}}} =
             json_response(conn, 404)

    assert is_binary(message)
  end

  test "T02-T03 unknown route outside /api also renders the envelope", %{conn: conn} do
    conn = post(conn, "/nope", %{})
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "T02-T04 malformed JSON body renders the invalid_request envelope", %{conn: conn} do
    conn = put_req_header(conn, "content-type", "application/json")

    {400, _headers, body} =
      assert_error_sent(400, fn -> post(conn, "/api/v1/anything", ~s({"a": 1,)) end)

    assert %{"error" => %{"code" => "invalid_request", "message" => message, "details" => %{}}} =
             Jason.decode!(body)

    assert is_binary(message)
    refute body =~ ~s({"a": 1,)
  end
end
