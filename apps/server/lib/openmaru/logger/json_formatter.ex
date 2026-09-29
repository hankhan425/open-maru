defmodule Openmaru.Logger.JSONFormatter do
  @moduledoc """
  `:logger` formatter emitting one JSON object per line:

      {"time":"2026-09-28T12:00:00.000000Z","level":"info","message":"…","metadata":{…}}

  Report messages (`Logger.info(%{…})`) are emitted as JSON objects under `message`.
  Metadata and reports are scrubbed with `Openmaru.Logger.Scrubber` here as well, so
  output is safe even if the primary filter is absent.

  Configure with `config :logger, :default_handler, formatter: {#{inspect(__MODULE__)}, %{}}`.
  """

  alias Openmaru.Logger.Scrubber

  @internal_meta [:time, :gl, :report_cb, :domain, :erl_level, :mfa]

  @doc false
  @spec check_config(term()) :: :ok
  def check_config(_config), do: :ok

  @doc "Formats a `:logger` event as a JSON line."
  @spec format(:logger.log_event(), term()) :: iolist()
  def format(%{level: level, msg: msg, meta: meta}, _config) do
    meta = Scrubber.scrub_meta(meta)

    entry = %{
      time: format_time(meta[:time]),
      level: Atom.to_string(level),
      message: message(Scrubber.scrub_msg(msg), meta),
      metadata: metadata(meta)
    }

    [Jason.encode_to_iodata!(entry), ?\n]
  end

  defp format_time(time) when is_integer(time),
    do: time |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp format_time(_time), do: nil

  defp message({:string, chardata}, _meta), do: to_text(chardata)
  defp message({:report, report}, _meta) when is_map(report), do: jsonable(report)

  defp message({:report, report}, _meta) when is_list(report),
    do: report |> Map.new() |> jsonable()

  defp message({format, args}, _meta) when is_list(args),
    do: format |> :io_lib.format(args) |> to_text()

  defp message(other, _meta), do: inspect(other)

  defp metadata(meta) do
    base = meta |> Map.drop(@internal_meta) |> jsonable()

    case meta do
      %{mfa: {m, f, a}} -> Map.put(base, "mfa", Exception.format_mfa(m, f, a))
      _ -> base
    end
  end

  defp to_text(chardata) do
    case :unicode.characters_to_binary(chardata) do
      binary when is_binary(binary) -> binary
      _ -> inspect(chardata)
    end
  end

  defp jsonable(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp jsonable(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp jsonable(%Date{} = value), do: Date.to_iso8601(value)
  defp jsonable(%_{} = value), do: inspect(value)

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {key(k), jsonable(v)} end)

  defp jsonable(value) when is_list(value) do
    cond do
      value != [] and Keyword.keyword?(value) -> value |> Map.new() |> jsonable()
      value != [] and List.ascii_printable?(value) -> List.to_string(value)
      true -> jsonable_list(value)
    end
  end

  defp jsonable(value), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  # An improper tail becomes its inspected form as the last element.
  defp jsonable_list([head | tail]), do: [jsonable(head) | jsonable_list(tail)]
  defp jsonable_list([]), do: []
  defp jsonable_list(tail), do: [inspect(tail)]
end
