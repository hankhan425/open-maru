defmodule Openmaru.Ledger.Chain do
  @moduledoc """
  The transfer hash chain (SPEC-03 §7).

  Every stored transfer has `hash = SHA-256(prev_hash ‖ encode(transfer))`, where
  `prev_hash` is the previous row's hash (32 zero bytes before seq 1). `encode/1` is a
  fixed 136-byte big-endian layout: `id`(16) `debit_account_id`(16) `credit_account_id`(16)
  `amount`(i64) `requested_amount`(i64) `pending_id`(16, zeros if null) `flags`(u32)
  `timeout_secs`(u32) `ledger`(u32) `code`(u32) `user_data_128`(16, zeros if null)
  `user_data_64`(i64, 0 if null) `timestamp`(i64) `seq`(i64).

  `scripts/ledger_vector.py` and the Rust CLI implement the same encoding independently;
  `test/fixtures/ledger_vectors.json` pins it.
  """

  alias Openmaru.Ledger.Flags

  @genesis <<0::256>>

  @typedoc """
  The hashed fields of a transfer. UUIDs may be strings or 16-byte binaries, flags a list
  of atoms or a bit set.
  """
  @type hashed :: %{
          :id => binary(),
          :debit_account_id => binary(),
          :credit_account_id => binary(),
          :amount => integer(),
          :requested_amount => integer(),
          :pending_id => binary() | nil,
          :flags => [atom()] | non_neg_integer(),
          :timeout_secs => non_neg_integer(),
          :ledger => pos_integer(),
          :code => pos_integer(),
          :user_data_128 => binary() | nil,
          :user_data_64 => integer() | nil,
          :timestamp => integer(),
          :seq => pos_integer(),
          optional(atom()) => term()
        }

  @doc "The `prev_hash` of seq 1: 32 zero bytes."
  @spec genesis() :: <<_::256>>
  def genesis, do: @genesis

  @doc "The 136-byte encoding of a transfer."
  @spec encode(hashed()) :: <<_::1088>>
  def encode(t) do
    <<uuid(t.id)::binary-16, uuid(t.debit_account_id)::binary-16,
      uuid(t.credit_account_id)::binary-16, t.amount::signed-big-64,
      t.requested_amount::signed-big-64, uuid(t.pending_id)::binary-16,
      flag_bits(t.flags)::unsigned-big-32, t.timeout_secs::unsigned-big-32,
      t.ledger::unsigned-big-32, t.code::unsigned-big-32, uuid(t.user_data_128)::binary-16,
      t.user_data_64 || 0::signed-big-64, t.timestamp::signed-big-64, t.seq::signed-big-64>>
  end

  @doc "The hash of a transfer that follows `prev_hash`."
  @spec hash(<<_::256>>, hashed()) :: <<_::256>>
  def hash(<<_::256>> = prev_hash, transfer),
    do: :crypto.hash(:sha256, [prev_hash, encode(transfer)])

  @doc "Transfer flags as the u32 bit set that is hashed."
  @spec flag_bits([atom()] | non_neg_integer()) :: non_neg_integer()
  def flag_bits(bits) when is_integer(bits), do: bits
  def flag_bits(flags) when is_list(flags), do: Flags.to_bits(:transfer, flags)

  defp uuid(nil), do: <<0::128>>
  defp uuid(<<_::128>> = raw), do: raw
  defp uuid(<<_::288>> = string), do: Ecto.UUID.dump!(string)
end
