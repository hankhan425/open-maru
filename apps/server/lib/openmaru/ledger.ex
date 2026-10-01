defmodule Openmaru.Ledger do
  @moduledoc """
  The double-entry ledger (SPEC-03, ADR-1): a TigerBeetle-shaped model in Postgres. Only
  this module touches the ledger tables.

  - **Accounts** (`create_accounts/1`) hold four balances: `debits_pending`,
    `debits_posted`, `credits_pending`, `credits_posted`. Flags constrain them:
    `:debits_must_not_exceed_credits` (DMNEC) and `:credits_must_not_exceed_debits`.
  - **Transfers** (`create_transfers/1`) are immutable, client-identified (the id is the
    idempotency key) and move integer micro-USD between two accounts of one ledger. They
    can be two-phase (`:pending`, then `:post_pending` or `:void_pending`, or expiry),
    `:linked` into all-or-nothing chains, and `:balancing_debit`/`:balancing_credit`.
  - Every write takes one transaction-level advisory lock, so writes are serialized: each
    stored transfer gets the next gapless `seq`, a strictly increasing microsecond
    `timestamp`, and a SHA-256 hash chained to the previous row (`Openmaru.Ledger.Chain`).
    Callers must use READ COMMITTED (the default) so a transaction sees the rows committed
    before it took the lock.

  ## Results

  `create_accounts/1` and `create_transfers/1` return one result per input, in order:
  `{:ok, :created}`, `{:ok, :exists}` (same id, identical fields: no effect) or
  `{:error, code}`. Expected failures are codes, never exceptions; malformed input (a
  non-UUID id, an unknown flag, a negative or out-of-range integer, an unknown key)
  raises `ArgumentError`.

  Transfer codes, in the order they are checked (the first failure wins; SPEC-03 §4.2):

  1. `id_must_not_be_zero`
  2. `exists` (ok) · `exists_with_different_fields`
  3. `flags_are_mutually_exclusive` (post with void; post or void with pending or
     balancing) · `pending_id_must_not_be_zero` · `pending_id_must_be_different` (post or
     void) · `pending_id_must_be_zero` (others) · `code_must_not_be_zero`
  4. `accounts_must_be_different` · `debit_account_not_found` ·
     `credit_account_not_found` · `accounts_must_have_the_same_ledger`
  5. `amount_must_not_be_zero` (not for posts and balancing transfers) ·
     `timeout_reserved_for_pending_transfer`
  6. Post and void: `pending_transfer_not_found` · `pending_transfer_not_pending` ·
     `pending_transfer_has_different_debit_account_id` ·
     `pending_transfer_has_different_credit_account_id` ·
     `pending_transfer_has_different_code` · `exceeds_pending_transfer_amount` (post) ·
     `pending_transfer_has_different_amount` (void) · `pending_transfer_already_posted` ·
     `pending_transfer_already_voided` · `pending_transfer_expired`
  7. `overflows` (a balance, or pending + posted on one side, above the i64 maximum) ·
     `exceeds_credits` (DMNEC) · `exceeds_debits` (CMNED)

  In a linked chain that fails, the failing transfer gets its code and the others
  `linked_event_failed`; a chain still open at the end of the batch gets
  `linked_event_chain_open` for every member.

  ## Posts and voids

  A post or void may omit `debit_account_id`, `credit_account_id`, `code`, `amount`,
  `user_data_128` and `user_data_64`: they come from the pending transfer. Given accounts
  and code must match it; given user data replaces it. A post's `amount` defaults to the
  full pending amount and may be lower (even 0); a void always releases the full amount.
  A pending transfer with `timeout_secs > 0` expires `timeout_secs` after its timestamp:
  from then on only the sweeper (`expire_pending/0`, every 30 s) resolves it, with a void
  whose id is `uuidv5("expire:<pending_id>")` and `user_data_64 = -1`.
  """

  alias Ecto.Multi
  alias Openmaru.Error

  alias Openmaru.Ledger.{
    Account,
    CreateAccounts,
    CreateTransfers,
    Expiry,
    Queries,
    Transfer,
    Verify
  }

  # UUIDv5(URL namespace, "https://openmaru.org/") (SPEC-03 §5).
  @namespace "7075e138-6378-557c-ad88-8dd8ed95be90"
  @namespace_raw Ecto.UUID.dump!(@namespace)

  # pg_advisory_xact_lock key for every ledger write: "omLEDGER" as a big-endian int64.
  @lock_key 0x6F6D_4C45_4447_4552

  @system_accounts %{
    allowance_source: "13a8b848-795e-5365-8aab-dcb51235c51d",
    allowance_sink: "3dd63a3b-7c4c-520f-ae03-92e4f528ac2a"
  }

  @typedoc "A transfer to create (SPEC-03 §4). Amounts are micro-USD."
  @type transfer :: %{
          required(:id) => Ecto.UUID.t(),
          optional(:debit_account_id) => Ecto.UUID.t() | nil,
          optional(:credit_account_id) => Ecto.UUID.t() | nil,
          optional(:amount) => non_neg_integer() | nil,
          optional(:pending_id) => Ecto.UUID.t() | nil,
          optional(:flags) => [
            :linked
            | :pending
            | :post_pending
            | :void_pending
            | :balancing_debit
            | :balancing_credit
          ],
          optional(:timeout_secs) => non_neg_integer(),
          optional(:code) => pos_integer() | nil,
          optional(:user_data_128) => Ecto.UUID.t() | nil,
          optional(:user_data_64) => integer() | nil
        }

  @typedoc "An account to create (SPEC-03 §2–§3). `ledger` defaults to 1."
  @type account_attrs :: %{
          required(:id) => Ecto.UUID.t(),
          required(:key) => String.t(),
          required(:code) => pos_integer(),
          optional(:ledger) => pos_integer(),
          optional(:flags) => [:debits_must_not_exceed_credits | :credits_must_not_exceed_debits]
        }

  @type result :: {:ok, :created | :exists} | {:error, atom()}

  @type balance :: %{
          debits_pending: non_neg_integer(),
          debits_posted: non_neg_integer(),
          credits_pending: non_neg_integer(),
          credits_posted: non_neg_integer(),
          available: integer()
        }

  @typedoc """
  Filters for `account_transfers/2`: `code` (one or a list), `period_key`
  (`user_data_64`), `from` (inclusive) and `to` (exclusive) as `DateTime`s or
  microseconds, `order` (`:asc` by seq, default, or `:desc`), `limit` (1–1000, default
  100) and `cursor` (a previous page's `next_cursor`).
  """
  @type account_filter :: keyword() | map()

  @doc "Creates accounts; one result per account, in order. See the module doc for codes."
  @spec create_accounts([account_attrs()]) :: [result()]
  defdelegate create_accounts(accounts), to: CreateAccounts, as: :run

  @doc "Creates transfers in one transaction; one result per transfer, in input order."
  @spec create_transfers([transfer()]) :: [result()]
  def create_transfers(transfers), do: CreateTransfers.run(transfers)

  @doc """
  Adds a step to `multi` that creates `transfers` inside the multi's transaction, so other
  contexts can write ledger transfers atomically with their own rows (ARCHITECTURE §4).

  `transfers` is a list or a function of the changes so far. The step's value is the list
  of results; if any is an error, the step fails with that list and the multi rolls back.
  """
  @spec multi_create_transfers(Multi.t(), Multi.name(), [transfer()] | (map() -> [transfer()])) ::
          Multi.t()
  def multi_create_transfers(multi, name, transfers) do
    Multi.run(multi, name, fn _repo, changes ->
      transfers = if is_function(transfers, 1), do: transfers.(changes), else: transfers
      results = create_transfers(transfers)
      if Enum.all?(results, &match?({:ok, _}, &1)), do: {:ok, results}, else: {:error, results}
    end)
  end

  @doc "Accounts by id, in input order; unknown ids are skipped."
  @spec lookup_accounts([Ecto.UUID.t()]) :: [Account.t()]
  defdelegate lookup_accounts(ids), to: Queries

  @doc "Transfers by id, in input order; unknown ids are skipped."
  @spec lookup_transfers([Ecto.UUID.t()]) :: [Transfer.t()]
  defdelegate lookup_transfers(ids), to: Queries

  @doc """
  An account's transfers (either side) in `seq` order, a page at a time. See
  `t:account_filter/0`.
  """
  @spec account_transfers(Ecto.UUID.t(), account_filter()) ::
          {:ok, %{data: [Transfer.t()], next_cursor: String.t() | nil}} | {:error, Error.t()}
  defdelegate account_transfers(account_id, filter \\ []), to: Queries

  @doc """
  The four balances and `available`: what a `:balancing_debit` could take
  (`credits_posted − debits_posted − debits_pending`), or for a
  `:credits_must_not_exceed_debits` account what can still be credited
  (`debits_posted − credits_posted − credits_pending`). Unconstrained accounts can show a
  negative `available`.
  """
  @spec balance(Ecto.UUID.t()) :: {:ok, balance()} | {:error, Error.t()}
  defdelegate balance(account_id), to: Queries

  @doc """
  Recomputes the hash chain for `from_seq..to_seq` (rows that exist; a range starting
  after seq 1 trusts the stored hash of the row before it). Returns the first broken
  row: a changed field or link (`:hash_mismatch`) or a missing row (`:seq_gap`).
  """
  @spec verify_chain(integer(), integer()) ::
          :ok | {:error, {:hash_mismatch | :seq_gap, pos_integer()}}
  defdelegate verify_chain(from_seq, to_seq), to: Verify

  @doc """
  Recomputes every account's balances from its transfers and returns the accounts whose
  stored balances differ, as `{account_id, expected, actual}`.
  """
  @spec verify_balances() :: :ok | {:error, [{Ecto.UUID.t(), map(), map()}]}
  defdelegate verify_balances(), to: Verify

  @doc """
  Voids every pending transfer whose timeout has passed (by `Openmaru.Clock`) and returns
  how many were voided. Run by `Openmaru.Ledger.ExpiryWorker`; rerunning is a no-op.
  """
  @spec expire_pending() :: {:ok, non_neg_integer()}
  defdelegate expire_pending(), to: Expiry, as: :run

  @doc """
  UUIDv5 of `name` in the openmaru namespace (`namespace/0`). Deterministic ids make
  scheduled and webhook-driven transfers idempotent (SPEC-03 §5).
  """
  @spec uuidv5(String.t()) :: Ecto.UUID.t()
  def uuidv5(name) when is_binary(name) do
    <<a::48, _version::4, b::12, _variant::2, c::62, _::binary>> =
      :crypto.hash(:sha, [@namespace_raw, name])

    Ecto.UUID.load!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  @doc "The openmaru UUIDv5 namespace: UUIDv5 of `https://openmaru.org/` in the URL namespace."
  @spec namespace() :: Ecto.UUID.t()
  def namespace, do: @namespace

  @doc """
  Ids of the system accounts created by migration (SPEC-03 §3): `uuidv5(key)` of
  `system:allowance_source` (code 600) and `system:allowance_sink` (code 610).
  """
  @spec system_account_id(:allowance_source | :allowance_sink) :: Ecto.UUID.t()
  def system_account_id(name), do: Map.fetch!(@system_accounts, name)

  @doc false
  @spec lock!() :: :ok
  def lock! do
    Openmaru.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key],
      cache_statement: "ledger_lock"
    )

    :ok
  end
end
