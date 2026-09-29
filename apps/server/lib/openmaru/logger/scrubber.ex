defmodule Openmaru.Logger.Scrubber do
  @moduledoc """
  Redacts secrets from log events (SPEC-09 §3).

  A key is sensitive when, case-insensitively, it is `authorization`,
  `proxy-authorization`, `x-api-key`, `cookie`, `set-cookie` or `value`, or contains
  `token`, `secret`, `key` or `password`. Its value is replaced with `"[REDACTED]"`
  wherever it appears: maps, structs, keyword lists, `{name, value}` header tuples, and
  nested combinations of these.

  `filter/2` is installed as a primary `:logger` filter by `Openmaru.Application`, so
  every handler sees scrubbed metadata and report messages. Free-text messages are not
  parsed; never interpolate secrets into them.
  """

  @redacted "[REDACTED]"
  @exact ~w(authorization proxy-authorization x-api-key cookie set-cookie value)
  @fragments ~w(token secret key password)

  @doc "The replacement for sensitive values."
  @spec redacted() :: String.t()
  def redacted, do: @redacted

  @doc "Whether a key names a sensitive value."
  @spec sensitive?(term()) :: boolean()
  def sensitive?(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: key |> Atom.to_string() |> sensitive?()

  def sensitive?(key) when is_binary(key) do
    key = String.downcase(key)
    key in @exact or String.contains?(key, @fragments)
  end

  def sensitive?(_key), do: false

  @doc "Recursively redacts the values of sensitive keys in `term`."
  @spec scrub(term()) :: term()
  def scrub(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> scrub()
    |> then(&Map.merge(struct, &1))
  end

  def scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub_pair(k, v)} end)
  def scrub(list) when is_list(list), do: scrub_list(list)
  def scrub({key, value}) when is_atom(key) or is_binary(key), do: {key, scrub_pair(key, value)}

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()

  def scrub(other), do: other

  defp scrub_pair(key, value) do
    if sensitive?(key), do: @redacted, else: scrub(value)
  end

  # Handles improper lists (valid in iodata) without crashing.
  defp scrub_list([head | tail]), do: [scrub(head) | scrub_list(tail)]
  defp scrub_list([]), do: []
  defp scrub_list(tail), do: scrub(tail)

  @doc """
  Primary `:logger` filter: scrubs the event's metadata and report messages. If
  scrubbing fails the event is dropped rather than logged unscrubbed.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(%{meta: meta, msg: msg} = event, _extra) do
    %{event | meta: scrub_meta(meta), msg: scrub_msg(msg)}
  rescue
    _error -> :stop
  end

  @doc "Scrubs a `:logger` metadata map."
  @spec scrub_meta(map()) :: map()
  def scrub_meta(meta) when is_map(meta), do: scrub(meta)

  @doc "Scrubs a `:logger` message; only `{:report, _}` messages carry structure."
  @spec scrub_msg(term()) :: term()
  def scrub_msg({:report, report}), do: {:report, scrub(report)}
  def scrub_msg(msg), do: msg
end
