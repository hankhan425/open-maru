defmodule Openmaru.Ledger.Transfer do
  @moduledoc """
  A stored ledger transfer (SPEC-03 §2), as returned by `Openmaru.Ledger.lookup_transfers/1`
  and `account_transfers/2`. Rows are immutable.

  `amount` is what moved; `requested_amount` is the request (they differ only for
  balancing transfers). `timestamp` is microseconds since the Unix epoch; `seq`,
  `prev_hash` and `hash` place the row in the hash chain (SPEC-03 §7).
  """

  use Ecto.Schema

  alias Openmaru.Ledger.Flags

  @primary_key {:id, Ecto.UUID, autogenerate: false}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          debit_account_id: Ecto.UUID.t(),
          credit_account_id: Ecto.UUID.t(),
          amount: non_neg_integer(),
          requested_amount: non_neg_integer(),
          pending_id: Ecto.UUID.t() | nil,
          flags: [Flags.transfer_flag()],
          timeout_secs: non_neg_integer(),
          ledger: pos_integer(),
          code: pos_integer(),
          user_data_128: Ecto.UUID.t() | nil,
          user_data_64: integer() | nil,
          timestamp: integer(),
          seq: pos_integer(),
          prev_hash: <<_::256>>,
          hash: <<_::256>>
        }

  schema "ledger_transfers" do
    field :debit_account_id, Ecto.UUID
    field :credit_account_id, Ecto.UUID
    field :amount, :integer
    field :requested_amount, :integer
    field :pending_id, Ecto.UUID
    field :flags, Flags, kind: :transfer
    field :timeout_secs, :integer
    field :ledger, :integer
    field :code, :integer
    field :user_data_128, Ecto.UUID
    field :user_data_64, :integer
    field :timestamp, :integer
    field :seq, :integer
    field :prev_hash, :binary
    field :hash, :binary
  end
end
