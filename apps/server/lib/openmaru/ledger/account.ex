defmodule Openmaru.Ledger.Account do
  @moduledoc """
  A ledger account (SPEC-03 §2), as returned by `Openmaru.Ledger.lookup_accounts/1`.
  Written only through `Openmaru.Ledger.create_accounts/1` and `create_transfers/1`.
  """

  use Ecto.Schema

  alias Openmaru.Ledger.Flags

  @primary_key {:id, Ecto.UUID, autogenerate: false}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          ledger: pos_integer(),
          code: pos_integer(),
          flags: [Flags.account_flag()],
          debits_pending: non_neg_integer(),
          debits_posted: non_neg_integer(),
          credits_pending: non_neg_integer(),
          credits_posted: non_neg_integer(),
          inserted_at: DateTime.t()
        }

  schema "ledger_accounts" do
    field :key, :string
    field :ledger, :integer
    field :code, :integer
    field :flags, Flags, kind: :account
    field :debits_pending, :integer
    field :debits_posted, :integer
    field :credits_pending, :integer
    field :credits_posted, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
