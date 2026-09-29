defmodule Openmaru.TypeID do
  @moduledoc """
  TypeIDs for API-facing ids (CONVENTIONS §4): `<prefix>_<26 base32 chars>` encoding a
  UUID (`org_01h455vb4pex5vsknk084sn02q`). The database stores plain UUIDs; encode on the
  way out, decode on the way in. Use `Openmaru.TypeID.Type` to cast TypeID params in
  changesets.
  """

  alias TypeID, as: Lib

  @prefixes ~w(usr org ver goal circ agent mand mtok dec task lease evid spend xfer acct don sess evt pat upl)
  @suffix_length 26

  @doc "The allowed prefixes."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @prefixes

  @doc "Whether `prefix` is one of `prefixes/0`."
  @spec known_prefix?(term()) :: boolean()
  def known_prefix?(prefix), do: prefix in @prefixes

  @doc """
  Encodes `uuid` with `prefix`. Raises `ArgumentError` for an unknown prefix or a value
  that is not a UUID (both are programming errors).
  """
  @spec encode(String.t(), Ecto.UUID.t()) :: String.t()
  def encode(prefix, uuid) when prefix in @prefixes and is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         {:ok, tid} <- Lib.from_uuid(prefix, uuid) do
      Lib.to_string(tid)
    else
      :error -> raise ArgumentError, "not a UUID: #{inspect(uuid)}"
    end
  end

  def encode(prefix, _uuid), do: raise(ArgumentError, "unknown TypeID prefix: #{inspect(prefix)}")

  @doc """
  Decodes `string`, requiring `expected_prefix`. Returns the lowercase UUID string, or
  `{:error, :invalid_id}` for a wrong prefix, an unknown prefix, or malformed input.
  """
  @spec decode(term(), String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :invalid_id}
  def decode(string, expected_prefix) when is_binary(string) and expected_prefix in @prefixes do
    size = byte_size(expected_prefix)

    with <<^expected_prefix::binary-size(^size), ?_, suffix::binary-size(@suffix_length)>> <-
           string,
         {:ok, tid} <- Lib.from(expected_prefix, suffix) do
      {:ok, Lib.uuid(tid)}
    else
      _ -> {:error, :invalid_id}
    end
  end

  def decode(_string, _expected_prefix), do: {:error, :invalid_id}
end
