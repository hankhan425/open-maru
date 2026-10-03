defmodule OpenmaruWeb.ErrorEnvelopeTest do
  use OpenmaruWeb.ConnCase, async: true

  alias Openmaru.Error
  alias OpenmaruWeb.ErrorJSON

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

  test "T02-T02 an unacceptable Accept header renders not_acceptable with 406 (OQ-1)", %{
    conn: conn
  } do
    conn = put_req_header(conn, "accept", "text/html")

    {406, _headers, body} = assert_error_sent(406, fn -> get(conn, "/api/v1/me") end)

    assert %{"error" => %{"code" => "not_acceptable", "details" => %{}}} = Jason.decode!(body)
  end

  test "T02-T02 a body over the parser limit renders payload_too_large with 413 (OQ-1)", %{
    conn: conn
  } do
    conn = put_req_header(conn, "content-type", "application/json")
    body = ~s({"a": ") <> String.duplicate("x", 8_000_000) <> ~s("})

    {413, _headers, sent} = assert_error_sent(413, fn -> post(conn, "/api/v1/anything", body) end)

    assert %{"error" => %{"code" => "payload_too_large"}} = Jason.decode!(sent)
  end

  # Bandit chooses its status when it raises (408 for a body read timeout) and Plug raises
  # 414 for an overlong query string, so the exception structs' defaults don't show them.
  @statuses_set_at_raise [408, 414]

  test "T02-T02 every status an exception from the stack carries has a code with that status (OQ-1)" do
    statuses =
      for app <- [:plug, :phoenix, :phoenix_ecto, :bandit, :ecto, :ecto_sql, :postgrex],
          module <- Application.spec(app, :modules) || [],
          status = exception_status(module),
          into: MapSet.new(@statuses_set_at_raise),
          do: status

    assert MapSet.size(statuses) > 5

    for status <- statuses do
      %{error: %{code: code}} = ErrorJSON.render("#{status}.json", %{})

      assert Error.status(String.to_existing_atom(code)) == status,
             "HTTP #{status} renders `#{code}`, whose status is not #{status}"
    end
  end

  test "T02-T02 an unhandled error renders internal_error with 500 (OQ-1)" do
    assert %{error: %{code: "internal_error"}} = ErrorJSON.render("500.json", %{})
    assert Error.status(:internal_error) == 500
  end

  defp exception_status(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :exception, 1) do
      Plug.Exception.status(module.__struct__())
    end
  rescue
    _error -> nil
  end
end
