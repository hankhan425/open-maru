defmodule OpenmaruWeb.ApiSpecTest do
  use OpenmaruWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  test "T02-T12 /api/v1/openapi.json is served and passes OpenApiSpex validation", %{conn: conn} do
    json = conn |> get("/api/v1/openapi.json") |> json_response(200)

    assert json["openapi"] =~ ~r/\A3\.\d+\.\d+\z/
    assert %{"title" => _, "version" => _} = json["info"]

    spec = OpenApiSpex.OpenApi.Decode.decode(json)
    assert %OpenApiSpex.OpenApi{} = spec

    for {path, item} <- spec.paths,
        {method, %OpenApiSpex.Operation{} = op} <- Map.from_struct(item) do
      assert is_binary(op.operationId), "#{method} #{path} has no operationId"
      assert map_size(op.responses) > 0, "#{method} #{path} has no responses"
    end

    health = build_conn() |> get("/healthz") |> json_response(200)
    assert_schema(health, "HealthResponse", spec)

    envelope = %{"error" => %{"code" => "not_found", "message" => "Not found", "details" => %{}}}
    assert_schema(envelope, "ErrorResponse", spec)
  end

  test "T02-T12 the served document matches the compiled ApiSpec" do
    served = build_conn() |> get("/api/v1/openapi.json") |> json_response(200)
    compiled = OpenmaruWeb.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()

    assert served == compiled
    assert Map.has_key?(served["paths"], "/healthz")
  end
end
