defmodule OpenmaruWeb.Plugs.RateLimit do
  @moduledoc """
  Per-client-IP rate limit (SPEC-09 §6), counted in `Openmaru.RateLimit`.

      plug OpenmaruWeb.Plugs.RateLimit, bucket: :auth, limit: 10, scale_ms: 60_000

  Routes sharing a `bucket` share one budget per IP. Over the limit the request halts
  with 429 `rate_limited` and a `retry-after` header (seconds).
  """

  @behaviour Plug

  import Plug.Conn

  alias Openmaru.Error
  alias OpenmaruWeb.FallbackController

  @impl Plug
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.fetch!(opts, :limit),
      scale_ms: Keyword.fetch!(opts, :scale_ms)
    }
  end

  @impl Plug
  def call(conn, %{bucket: bucket, limit: limit, scale_ms: scale_ms}) do
    case Openmaru.RateLimit.hit({bucket, conn.remote_ip}, scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header(
          "retry-after",
          Integer.to_string(max(div(retry_after_ms + 999, 1000), 1))
        )
        |> FallbackController.call({:error, Error.new(:rate_limited, "Too many requests")})
        |> halt()
    end
  end
end
