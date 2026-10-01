defmodule OpenmaruWeb.Plugs.ClientIP do
  @moduledoc """
  Sets `conn.remote_ip` to the client's address. The per-IP rate limits (SPEC-09 §6) and
  the audit log's IP hashes (SPEC-09 §7) key on it.

  Behind a load balancer the TCP peer is the balancer, so every client would share one
  address. When the peer is one of the configured `:trusted_proxies` (CIDRs such as
  `10.0.0.0/8`, or single addresses), the client is the right-most `x-forwarded-for`
  entry that is not itself a trusted proxy; entries further left are client-supplied and
  ignored. With no trusted proxies (the default) the header is ignored entirely, so a
  client cannot pick its own address.

      config :openmaru, OpenmaruWeb.Plugs.ClientIP, trusted_proxies: ["10.0.0.0/8"]

  `config/runtime.exs` reads the list from `TRUSTED_PROXIES` (comma-separated). An
  IPv4-mapped IPv6 address (`::ffff:a.b.c.d`, from a dual-stack listener) becomes the
  IPv4 address, so one client has one address.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn, only: [get_req_header: 2]

  @typedoc "A parsed CIDR: network as an integer, address width in bits, prefix length."
  @type cidr :: {non_neg_integer(), 32 | 128, non_neg_integer()}

  @impl Plug
  def init(opts), do: opts

  @doc """
  Rewrites `conn.remote_ip`. `opts` may give `:trusted_proxies` (CIDR strings) in place
  of the configured list.
  """
  @impl Plug
  def call(conn, opts) do
    proxies =
      case Keyword.fetch(opts, :trusted_proxies) do
        {:ok, list} -> Enum.map(list, &parse_cidr!/1)
        :error -> trusted_proxies!()
      end

    peer = normalize(conn.remote_ip)
    %{conn | remote_ip: client(conn, peer, proxies)}
  end

  @doc """
  The configured trusted proxies, parsed. Raises `ArgumentError` on an invalid entry;
  `Openmaru.Application` calls it at boot so a bad `TRUSTED_PROXIES` fails fast.
  """
  @spec trusted_proxies!() :: [cidr()]
  def trusted_proxies! do
    :openmaru
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:trusted_proxies, [])
    |> Enum.map(&parse_cidr!/1)
  end

  defp client(_conn, peer, []), do: peer

  defp client(conn, peer, proxies) do
    if trusted?(peer, proxies) do
      conn |> forwarded_for() |> Enum.reverse() |> walk(peer, proxies)
    else
      peer
    end
  end

  # Right to left: skip trusted proxies; the first other address is the client. An
  # unparseable entry ends the walk at the last address we could trust.
  defp walk([], last, _proxies), do: last

  defp walk([hop | rest], last, proxies) do
    case parse_ip(hop) do
      {:ok, ip} -> if trusted?(ip, proxies), do: walk(rest, ip, proxies), else: ip
      :error -> last
    end
  end

  defp forwarded_for(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
  end

  # Accepts `1.2.3.4`, `1.2.3.4:80`, `2001:db8::1` and `[2001:db8::1]:443`.
  defp parse_ip(string) do
    host =
      case Regex.run(~r/\A\[([^\]]+)\](?::\d+)?\z/, string) do
        [_, inner] -> inner
        nil -> strip_ipv4_port(string)
      end

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, normalize(ip)}
      {:error, _} -> :error
    end
  end

  defp strip_ipv4_port(string) do
    case String.split(string, ":") do
      [ip, _port] -> ip
      _ -> string
    end
  end

  defp parse_cidr!(cidr) when is_binary(cidr) do
    {address, prefix} =
      case String.split(String.trim(cidr), "/") do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
        _ -> invalid_cidr!(cidr)
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         {int, bits} = to_integer(ip),
         {:ok, prefix} <- parse_prefix(prefix, bits) do
      {int, bits, prefix}
    else
      _ -> invalid_cidr!(cidr)
    end
  end

  defp parse_cidr!(other), do: invalid_cidr!(other)

  defp parse_prefix(nil, bits), do: {:ok, bits}

  defp parse_prefix(string, bits) do
    case Integer.parse(string) do
      {prefix, ""} when prefix >= 0 and prefix <= bits -> {:ok, prefix}
      _ -> :error
    end
  end

  @spec invalid_cidr!(term()) :: no_return()
  defp invalid_cidr!(value) do
    raise ArgumentError, "invalid trusted proxy #{inspect(value)}: expected an IP or a CIDR"
  end

  defp trusted?(ip, proxies) do
    {int, bits} = to_integer(ip)

    Enum.any?(proxies, fn {network, width, prefix} ->
      width == bits and int >>> (bits - prefix) == network >>> (bits - prefix)
    end)
  end

  defp to_integer({_, _, _, _} = ip), do: {fold(ip, 8), 32}
  defp to_integer({_, _, _, _, _, _, _, _} = ip), do: {fold(ip, 16), 128}

  defp fold(tuple, width) do
    tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc <<< width ||| part end)
  end

  defp normalize({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp normalize(ip), do: ip
end
