defmodule Openmaru.Accounts.Passkey do
  @moduledoc """
  A WebAuthn credential (SPEC-02 §2). `cose_key` is the CBOR-encoded COSE public key;
  `sign_count` is the last counter the authenticator reported (SPEC-09 §1).
  """

  use Openmaru.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          credential_id: binary() | nil,
          cose_key: binary() | nil,
          sign_count: non_neg_integer() | nil,
          transports: [String.t()] | nil,
          last_used_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "passkeys" do
    field :user_id, Ecto.UUID
    field :credential_id, :binary
    field :cose_key, :binary
    field :sign_count, :integer, default: 0
    field :transports, {:array, :string}, default: []
    field :last_used_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Encodes a COSE key map (`Wax.CoseKey.t()`) as CBOR, byte strings tagged as bytes."
  @spec encode_cose_key(map()) :: binary()
  def encode_cose_key(cose_key) do
    cose_key
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, %CBOR.Tag{tag: :bytes, value: v}}
      pair -> pair
    end)
    |> CBOR.encode()
  end

  @doc "Decodes a key stored by `encode_cose_key/1`."
  @spec decode_cose_key(binary()) :: {:ok, map()} | :error
  def decode_cose_key(binary) do
    case CBOR.decode(binary) do
      {:ok, %{} = map, ""} ->
        {:ok,
         Map.new(map, fn
           {k, %CBOR.Tag{tag: :bytes, value: v}} -> {k, v}
           pair -> pair
         end)}

      _ ->
        :error
    end
  end
end
