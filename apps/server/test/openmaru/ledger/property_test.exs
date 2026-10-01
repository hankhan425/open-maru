defmodule Openmaru.Ledger.PropertyTest do
  use Openmaru.DataCase, async: false
  use ExUnitProperties

  import Openmaru.LedgerHelpers

  alias Openmaru.{Ledger, UUIDv7}

  # Failures print the shrunk operation list; rerun with the printed `--seed` to reproduce.

  @t0 ~U[2026-10-01 00:00:00.000000Z]

  # Accounts 0–1 are DMNEC, 2 is CMNED, 3–5 are unconstrained (5 acts as a source).
  @account_count 6

  defp account_ref, do: integer(0..(@account_count - 1))

  defp amount do
    frequency([
      {12, integer(0..120)},
      {1, constant(i64_max())},
      {1, map(integer(0..200), &(i64_max() - &1))}
    ])
  end

  defp transfer_flags do
    frequency([
      {5, constant([])},
      {4, constant([:pending])},
      {1, constant([:balancing_debit])},
      {1, constant([:balancing_credit])},
      {1, constant([:pending, :balancing_debit])}
    ])
  end

  defp transfer_spec do
    gen all(
          debit <- account_ref(),
          credit <- account_ref(),
          amount <- amount(),
          flags <- transfer_flags(),
          timeout <- member_of([0, 0, 30, 90])
        ) do
      {:transfer, debit, credit, amount, flags, if(:pending in flags, do: timeout, else: 0)}
    end
  end

  defp resolve_spec do
    gen all(
          kind <- member_of([:post_pending, :void_pending]),
          ref <- integer(0..64),
          amount <- one_of([constant(nil), integer(0..120)])
        ) do
      {:resolve, kind, ref, amount}
    end
  end

  defp member, do: frequency([{3, transfer_spec()}, {2, resolve_spec()}])

  defp operation do
    frequency([
      {6, map(member(), &{:batch, [&1], :independent})},
      {3, map(list_of(member(), min_length: 2, max_length: 4), &{:batch, &1, :independent})},
      {3,
       gen all(
             members <- list_of(member(), min_length: 2, max_length: 4),
             open? <- frequency([{5, constant(false)}, {1, constant(true)}])
           ) do
         {:batch, members, if(open?, do: :open_chain, else: :chain)}
       end},
      {1, map(integer(1..120), &{:advance, &1})},
      {1, map(integer(0..64), &{:replay, &1})}
    ])
  end

  property "G01-T19 random ledger histories uphold SPEC-03 §8 invariants 1–5" do
    check all(operations <- list_of(operation(), min_length: 1, max_length: 30), max_runs: 60) do
      {:error, :reset} =
        Repo.transaction(fn ->
          run(operations)
          Repo.rollback(:reset)
        end)
    end
  end

  defp run(operations) do
    set_clock(@t0)
    accounts = setup_accounts()
    state = %{accounts: accounts, clock: 0, pendings: [], batches: []}

    state =
      Enum.reduce(operations, state, fn operation, state ->
        state = step(operation, state)
        assert_invariants!(state)
        state
      end)

    # Invariant 5: replaying any batch (what it created) returns exists and changes nothing.
    for created <- state.batches, do: assert_replay!(created, state)
  end

  defp setup_accounts do
    flags = [
      [:debits_must_not_exceed_credits],
      [:debits_must_not_exceed_credits],
      [:credits_must_not_exceed_debits],
      [],
      [],
      []
    ]

    for f <- flags, do: account!(flags: f)
  end

  defp step({:advance, seconds}, state) do
    clock = state.clock + seconds
    set_clock(DateTime.add(@t0, clock, :second))
    {:ok, _count} = Ledger.expire_pending()
    %{state | clock: clock}
  end

  defp step({:replay, ref}, %{batches: [_ | _] = batches} = state) do
    assert_replay!(Enum.at(batches, rem(ref, length(batches))), state)
    state
  end

  defp step({:replay, _ref}, state), do: state

  defp step({:batch, members, mode}, state) do
    {transfers, _pendings} =
      Enum.map_reduce(members, state.pendings, fn member, pendings ->
        transfer = build(member, state.accounts, pendings)
        pendings = if :pending in transfer.flags, do: [transfer.id | pendings], else: pendings
        {transfer, pendings}
      end)

    transfers = link(transfers, mode)
    results = Ledger.create_transfers(transfers)
    assert length(results) == length(transfers)

    assert Enum.all?(results, fn
             {:ok, :created} -> true
             {:error, code} -> is_atom(code)
             _ -> false
           end)

    if mode == :open_chain,
      do: assert(Enum.all?(results, &(&1 == {:error, :linked_event_chain_open})))

    if mode == :chain and not Enum.all?(results, &(&1 == {:ok, :created})) do
      assert Enum.count(results, &(&1 != {:error, :linked_event_failed})) == 1
    end

    created =
      for {transfer, {:ok, :created}} <- Enum.zip(transfers, results), do: transfer

    new_pendings = for t <- created, :pending in t.flags, do: t.id

    %{state | pendings: new_pendings ++ state.pendings, batches: [created | state.batches]}
  end

  defp build({:transfer, debit, credit, amount, flags, timeout}, accounts, _pendings) do
    transfer(
      debit_account_id: Enum.at(accounts, debit),
      credit_account_id: Enum.at(accounts, credit),
      amount: amount,
      flags: flags,
      timeout_secs: timeout
    )
  end

  defp build({:resolve, kind, ref, amount}, _accounts, pendings) do
    pending_id =
      case pendings do
        [] -> UUIDv7.generate()
        _ -> Enum.at(pendings, rem(ref, length(pendings)))
      end

    transfer(flags: [kind], pending_id: pending_id, amount: amount, code: nil)
  end

  defp link(transfers, :independent), do: transfers
  defp link(transfers, :open_chain), do: Enum.map(transfers, &add_linked/1)

  defp link(transfers, :chain) do
    {init, [last]} = Enum.split(transfers, -1)
    Enum.map(init, &add_linked/1) ++ [last]
  end

  defp add_linked(transfer), do: %{transfer | flags: [:linked | transfer.flags]}

  defp assert_replay!([], _state), do: :ok

  defp assert_replay!(created, state) do
    before = {head_seq(), snapshot(state.accounts)}
    assert Ledger.create_transfers(created) == List.duplicate({:ok, :exists}, length(created))
    assert {head_seq(), snapshot(state.accounts)} == before
  end

  defp assert_invariants!(state) do
    accounts = Ledger.lookup_accounts(state.accounts)

    %{rows: rows} =
      Repo.query!(
        "SELECT id, debit_account_id, credit_account_id, amount, pending_id, flags FROM ledger_transfers"
      )

    transfers =
      Enum.map(rows, fn [id, debit, credit, amount, pending_id, flags] ->
        %{
          id: id,
          debit: Ecto.UUID.load!(debit),
          credit: Ecto.UUID.load!(credit),
          amount: amount,
          pending_id: pending_id,
          flags: flags
        }
      end)

    resolved = MapSet.new(for %{pending_id: p} when not is_nil(p) <- transfers, do: p)

    # 1. Every account's balances equal the sums of its transfers.
    for account <- accounts do
      expected =
        Enum.reduce(transfers, bal(), fn t, acc ->
          pending? = Bitwise.band(t.flags, 2) != 0
          void? = Bitwise.band(t.flags, 8) != 0

          column =
            cond do
              pending? and not MapSet.member?(resolved, t.id) -> :pending
              pending? or void? -> nil
              true -> :posted
            end

          acc
          |> add(column, :debits, t.debit == account.id, t.amount)
          |> add(column, :credits, t.credit == account.id, t.amount)
        end)

      assert Map.take(account, Map.keys(expected)) == expected, "balances of #{account.id}"
    end

    assert Ledger.verify_balances() == :ok

    # 2. Posted and pending balances each sum to zero across all accounts.
    %{rows: [[posted, pending]]} =
      Repo.query!("""
      SELECT coalesce(sum(credits_posted - debits_posted), 0)::bigint,
             coalesce(sum(credits_pending - debits_pending), 0)::bigint
      FROM ledger_accounts
      """)

    assert {posted, pending} == {0, 0}

    # 3. Balance-constrained accounts never exceed their limits.
    for account <- accounts do
      if :debits_must_not_exceed_credits in account.flags,
        do: assert(account.debits_pending + account.debits_posted <= account.credits_posted)

      if :credits_must_not_exceed_debits in account.flags,
        do: assert(account.credits_pending + account.credits_posted <= account.debits_posted)
    end

    # 4. A pending transfer resolves (post, void or expiry) at most once.
    %{rows: twice} =
      Repo.query!(
        "SELECT pending_id FROM ledger_transfers WHERE pending_id IS NOT NULL GROUP BY pending_id HAVING count(*) > 1"
      )

    assert twice == []

    # 6 (bonus): the chain verifies from seq 1.
    assert Ledger.verify_chain(1, head_seq()) == :ok
  end

  defp add(acc, nil, _side, _match?, _amount), do: acc
  defp add(acc, _column, _side, false, _amount), do: acc

  defp add(acc, column, side, true, amount) do
    key = String.to_existing_atom("#{side}_#{column}")
    Map.update!(acc, key, &(&1 + amount))
  end
end
