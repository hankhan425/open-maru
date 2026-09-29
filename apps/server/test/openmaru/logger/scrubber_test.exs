defmodule Openmaru.Logger.ScrubberTest do
  # capture_log mutes the global handler; keep this file synchronous.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Openmaru.Logger.JSONFormatter
  alias Openmaru.Logger.Scrubber

  @secrets %{
    "authorization" => "Bearer om_pat_supersecret1",
    "x-api-key" => "sk-ant-supersecret2",
    "cookie" => "_openmaru_key=supersecret3",
    "api_token" => "supersecret4",
    "client_secret" => "supersecret5",
    "private_key" => "supersecret6"
  }

  defp refute_leaks(output) do
    for {_key, value} <- @secrets, do: refute(output =~ value, "leaked #{value}")
    assert output =~ "[REDACTED]"
  end

  test "T02-T11 scrub/1 redacts sensitive keys in maps, keywords, header lists and nesting" do
    input = %{
      "authorization" => "Bearer om_pat_supersecret1",
      :"x-api-key" => "sk-ant-supersecret2",
      "request" => %{
        "headers" => [{"cookie", "_openmaru_key=supersecret3"}, {"accept", "json"}],
        "params" => [api_token: "supersecret4", page: 2]
      },
      "oauth" => %{"client_secret" => "supersecret5", "Private_Key" => "supersecret6"},
      "safe" => "visible"
    }

    scrubbed = Scrubber.scrub(input)

    assert scrubbed["authorization"] == "[REDACTED]"
    assert scrubbed[:"x-api-key"] == "[REDACTED]"
    assert scrubbed["request"]["headers"] == [{"cookie", "[REDACTED]"}, {"accept", "json"}]
    assert scrubbed["request"]["params"] == [api_token: "[REDACTED]", page: 2]
    assert scrubbed["oauth"] == %{"client_secret" => "[REDACTED]", "Private_Key" => "[REDACTED]"}
    assert scrubbed["safe"] == "visible"
  end

  test "T02-T11 SPEC-09 §3 patterns: *token*, *secret*, *key*, value" do
    scrubbed =
      Scrubber.scrub(%{
        refresh_token: "a",
        webhook_secret: "b",
        idempotency_key: "c",
        value: "d",
        values: "kept",
        name: "kept"
      })

    assert scrubbed == %{
             refresh_token: "[REDACTED]",
             webhook_secret: "[REDACTED]",
             idempotency_key: "[REDACTED]",
             value: "[REDACTED]",
             values: "kept",
             name: "kept"
           }
  end

  test "T02-T11 logged metadata is redacted through the Logger pipeline" do
    metadata = for {key, value} <- @secrets, do: {String.to_atom(key), value}

    output =
      capture_log([metadata: :all], fn ->
        Logger.warning("provider call", metadata)
      end)

    refute_leaks(output)
    assert output =~ "provider call"
  end

  test "T02-T11 logged report maps are redacted through the Logger pipeline" do
    output =
      capture_log(fn ->
        Logger.warning(%{"event" => "upstream_request", "headers" => @secrets})
      end)

    refute_leaks(output)
    assert output =~ "upstream_request"
  end

  test "T02-T11 the JSON formatter emits [REDACTED] for sensitive metadata and report fields" do
    metadata = for {key, value} <- @secrets, do: {String.to_atom(key), value}

    output =
      capture_log([formatter: {JSONFormatter, %{}}], fn ->
        Logger.warning("with metadata", metadata)
        Logger.warning(%{"event" => "report", "nested" => @secrets})
      end)

    refute_leaks(output)

    [first, second] =
      output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert first["message"] == "with metadata"
    assert first["level"] == "warning"
    assert first["metadata"]["authorization"] == "[REDACTED]"
    assert first["metadata"]["private_key"] == "[REDACTED]"
    assert second["message"]["event"] == "report"
    assert second["message"]["nested"]["client_secret"] == "[REDACTED]"
  end

  test "T02-T11 the JSON formatter scrubs even without the primary filter" do
    event = %{
      level: :error,
      msg: {:report, %{"x-api-key" => "sk-ant-supersecret2"}},
      meta: %{time: System.os_time(:microsecond), api_token: "supersecret4"}
    }

    line = event |> JSONFormatter.format(%{}) |> IO.iodata_to_binary()
    decoded = Jason.decode!(line)

    assert decoded["message"] == %{"x-api-key" => "[REDACTED]"}
    assert decoded["metadata"]["api_token"] == "[REDACTED]"
    assert String.ends_with?(line, "\n")
  end
end
