defmodule Openmaru.LedgerHelpers do
  @moduledoc """
  Builders for ledger tests (G01): accounts with fresh ids and keys, funded accounts,
  transfer maps with defaults, balance snapshots, and Clock control.

  Ledger tests are `async: false`: the hash chain, `seq` and the advisory lock are
  global, and some tests commit outside the sandbox.
  """

  import ExUnit.Assertions
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Openmaru.{ClockMock, Ledger, Repo, UUIDv7}

  @i64_max 9_223_372_036_854_775_807

  @doc "The largest amount or balance (signed 64-bit)."
  @spec i64_max() :: pos_integer()
  def i64_max, do: @i64_max

  @doc """
  Creates an account and returns its id. Defaults: ledger 1, code 300, no flags, a
  unique `test:<n>` key.
  """
  @spec account!(Enumerable.t()) :: Ecto.UUID.t()
  def account!(attrs \\ %{}) do
    account =
      Enum.into(attrs, %{
        id: UUIDv7.generate(),
        key: "test:#{System.unique_integer([:positive])}",
        code: 300,
        flags: []
      })

    assert Ledger.create_accounts([account]) == [{:ok, :created}]
    account.id
  end

  @doc "Creates a `debits_must_not_exceed_credits` account."
  @spec dmnec!(Enumerable.t()) :: Ecto.UUID.t()
  def dmnec!(attrs \\ %{}),
    do:
      attrs |> Enum.into(%{}) |> Map.put(:flags, [:debits_must_not_exceed_credits]) |> account!()

  @doc "Creates a `credits_must_not_exceed_debits` account."
  @spec cmned!(Enumerable.t()) :: Ecto.UUID.t()
  def cmned!(attrs \\ %{}),
    do:
      attrs |> Enum.into(%{}) |> Map.put(:flags, [:credits_must_not_exceed_debits]) |> account!()

  @doc "Credits `amount` to `account_id` from a new unconstrained source account."
  @spec fund!(Ecto.UUID.t(), pos_integer()) :: Ecto.UUID.t()
  def fund!(account_id, amount) do
    source = account!(code: 100)
    create!(transfer(debit_account_id: source, credit_account_id: account_id, amount: amount))
    account_id
  end

  @doc "Debits `amount` from `account_id` to a new unconstrained sink account."
  @spec drain!(Ecto.UUID.t(), pos_integer()) :: Ecto.UUID.t()
  def drain!(account_id, amount) do
    sink = account!(code: 400)
    create!(transfer(debit_account_id: account_id, credit_account_id: sink, amount: amount))
    account_id
  end

  @doc "A transfer map with a fresh id, no flags, code 1 and no timeout."
  @spec transfer(Enumerable.t()) :: map()
  def transfer(attrs \\ %{}) do
    Enum.into(attrs, %{id: UUIDv7.generate(), flags: [], code: 1, timeout_secs: 0})
  end

  @doc "Creates transfers, asserting each one is created; returns them."
  @spec create!(map() | [map()]) :: [map()]
  def create!(transfers) do
    transfers = List.wrap(transfers)
    results = Ledger.create_transfers(transfers)
    assert results == List.duplicate({:ok, :created}, length(transfers))
    transfers
  end

  @doc "The four balance columns of an account."
  @spec balances(Ecto.UUID.t()) :: %{atom() => integer()}
  def balances(account_id) do
    [account] = Ledger.lookup_accounts([account_id])
    Map.take(account, [:debits_pending, :debits_posted, :credits_pending, :credits_posted])
  end

  @doc "Balances of several accounts, keyed by id."
  @spec snapshot([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def snapshot(ids), do: Map.new(ids, &{&1, balances(&1)})

  @doc "Balances with every column zero except the given ones."
  @spec bal(Enumerable.t()) :: %{atom() => integer()}
  def bal(attrs \\ []) do
    Enum.into(attrs, %{debits_pending: 0, debits_posted: 0, credits_pending: 0, credits_posted: 0})
  end

  @doc "Number of transfer rows visible to this connection."
  @spec transfer_count() :: non_neg_integer()
  def transfer_count, do: Repo.aggregate("ledger_transfers", :count)

  @doc "The highest `seq`, or 0 for an empty chain."
  @spec head_seq() :: non_neg_integer()
  def head_seq do
    %{rows: [[seq]]} = Repo.query!("SELECT coalesce(max(seq), 0) FROM ledger_transfers")
    seq
  end

  @doc "Makes `Openmaru.Clock.now/0` return `at` in the calling process."
  @spec set_clock(DateTime.t()) :: :ok
  def set_clock(%DateTime{} = at) do
    stub(ClockMock, :now, fn -> at end)
    :ok
  end

  @doc """
  Runs `fun` on a connection outside the SQL sandbox, so its writes commit. Pair it with
  `delete_committed!/1`.
  """
  @spec unboxed((-> result)) :: result when result: term()
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc """
  Deletes committed ledger rows that touch `account_ids`, and the accounts themselves.
  The immutability triggers are disabled for the deletion only.
  """
  @spec delete_committed!([Ecto.UUID.t()]) :: :ok
  def delete_committed!(account_ids) do
    ids = Enum.map(account_ids, &Ecto.UUID.dump!/1)
    {:ok, :ok} = unboxed(fn -> Repo.transaction(fn -> delete_rows!(ids) end) end)
    :ok
  end

  defp delete_rows!(ids) do
    for table <- ~w(ledger_transfers ledger_accounts),
        do: Repo.query!("ALTER TABLE #{table} DISABLE TRIGGER USER")

    Repo.query!(
      """
      DELETE FROM ledger_pending_expiries WHERE pending_id IN
        (SELECT id FROM ledger_transfers
         WHERE debit_account_id = ANY($1) OR credit_account_id = ANY($1))
      """,
      [ids]
    )

    # Resolutions reference their pending transfers, so delete them first.
    Repo.query!(
      "DELETE FROM ledger_transfers WHERE pending_id IS NOT NULL AND (debit_account_id = ANY($1) OR credit_account_id = ANY($1))",
      [ids]
    )

    Repo.query!(
      "DELETE FROM ledger_transfers WHERE debit_account_id = ANY($1) OR credit_account_id = ANY($1)",
      [ids]
    )

    Repo.query!("DELETE FROM ledger_accounts WHERE id = ANY($1)", [ids])

    for table <- ~w(ledger_transfers ledger_accounts),
        do: Repo.query!("ALTER TABLE #{table} ENABLE TRIGGER USER")

    :ok
  end

  @doc "Microseconds since the Unix epoch."
  @spec micros(DateTime.t()) :: integer()
  def micros(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
end
