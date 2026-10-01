defmodule OpenmaruWeb.Plugs.RateLimit do
  @moduledoc """
  Per-client rate limit (SPEC-09 §6), counted in `Openmaru.RateLimit`.

      plug OpenmaruWeb.Plugs.RateLimit, bucket: :auth

  A bucket's limit comes from config, read on every request so `config/runtime.exs` can
  set it per environment (`AUTH_RATE_LIMIT_PER_MINUTE`). H02 adds the other SPEC-09 §6
  limits to the same table:

      config :openmaru, OpenmaruWeb.Plugs.RateLimit,
        limits: [auth: [limit: 10, scale_ms: 60_000]]

  `:limit` and `:scale_ms` passed to the plug override the config.

  Routes sharing a `bucket` share one budget per client. A client is its IPv4 address or
  the /64 prefix of its IPv6 address: one subscriber usually holds a whole /64, so a
  budget per IPv6 address would not limit anything. The address is `conn.remote_ip`, as
  resolved by `OpenmaruWeb.Plugs.ClientIP`. Over the limit the request halts with 429
  `rate_limited` and a `retry-after` header (seconds).
  """

  @behaviour Plug

  import Plug.Conn

  alias Openmaru.Error
  alias OpenmaruWeb.FallbackController

  @impl Plug
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.get(opts, :limit),
      scale_ms: Keyword.get(opts, :scale_ms)
    }
  end

  @impl Plug
  def call(conn, %{bucket: bucket} = opts) do
    {limit, scale_ms} = limits(opts)

    case Openmaru.RateLimit.hit({bucket, client_key(conn.remote_ip)}, scale_ms, limit) do
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

  @doc "The key a client's requests are counted under: its IPv4 address or IPv6 /64."
  @spec client_key(:inet.ip_address()) :: tuple()
  def client_key({_, _, _, _} = ip), do: ip
  def client_key({a, b, c, d, _, _, _, _}), do: {:ipv6_64, a, b, c, d}

  defp limits(%{bucket: bucket, limit: limit, scale_ms: scale_ms}) do
    configured =
      :openmaru
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:limits, [])
      |> Keyword.get(bucket, [])

    {limit || Keyword.get(configured, :limit) || missing!(bucket, :limit),
     scale_ms || Keyword.get(configured, :scale_ms) || missing!(bucket, :scale_ms)}
  end

  @spec missing!(term(), atom()) :: no_return()
  defp missing!(bucket, key) do
    raise ArgumentError, "no #{key} configured for rate-limit bucket #{inspect(bucket)}"
  end
end
