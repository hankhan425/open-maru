defmodule Openmaru.Ledger.BenchTest do
  # Excluded by default (test_helper.exs). Run with `mix test --only bench`; CI reports the
  # LEDGER_BENCH lines (ARCHITECTURE §7 target: ≥ 1,000 linked pairs/s).
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  alias Openmaru.{Ledger, UUIDv7}

  @moduletag :bench
  @moduletag timeout: :infinity

  @pairs 10_000
  @batch_pairs 100
  @single_pairs 1_000

  # A spend hold (SPEC-03 §5.1): budget → allowance sink and goal funds → spend sink,
  # both pending and linked, committed through the advisory lock like production writes.
  defp hold_pair(accounts) do
    [
      transfer(
        id: UUIDv7.generate(),
        debit_account_id: accounts.budget,
        credit_account_id: accounts.sink,
        amount: 1,
        flags: [:pending, :linked],
        timeout_secs: 900,
        code: 31,
        user_data_64: 1_202_610
      ),
      transfer(
        id: UUIDv7.generate(),
        debit_account_id: accounts.funds,
        credit_account_id: accounts.spend,
        amount: 1,
        flags: [:pending],
        timeout_secs: 900,
        code: 20,
        user_data_128: UUIDv7.generate()
      )
    ]
  end

  defp create_all!(batch) do
    results = Ledger.create_transfers(batch)
    true = Enum.all?(results, &(&1 == {:ok, :created}))
  end

  defp measure(label, accounts, pairs, pairs_per_call) do
    calls = div(pairs, pairs_per_call)

    batches =
      for _ <- 1..calls, do: Enum.flat_map(1..pairs_per_call, fn _ -> hold_pair(accounts) end)

    # One connection outside the sandbox for the run; each call is its own transaction.
    {micros, _} = :timer.tc(fn -> unboxed(fn -> Enum.each(batches, &create_all!/1) end) end)

    rate = pairs * 1_000_000 / micros

    IO.puts(
      "LEDGER_BENCH #{label}: #{pairs} linked pairs in #{calls} calls, " <>
        "#{Float.round(micros / 1_000_000, 2)} s, #{round(rate)} pairs/s"
    )

    rate
  end

  test "G01-T22 bench: 10k linked pairs" do
    accounts =
      unboxed(fn ->
        %{
          budget: dmnec!(code: 500),
          sink: account!(code: 610),
          funds: dmnec!(code: 300),
          spend: account!(code: 400),
          source: account!(code: 100)
        }
      end)

    on_exit(fn -> delete_committed!(Map.values(accounts)) end)

    unboxed(fn ->
      total = @pairs + @single_pairs

      create!([
        transfer(
          debit_account_id: accounts.source,
          credit_account_id: accounts.budget,
          amount: total
        ),
        transfer(
          debit_account_id: accounts.source,
          credit_account_id: accounts.funds,
          amount: total
        )
      ])
    end)

    batched = measure("batched (#{@batch_pairs} pairs per call)", accounts, @pairs, @batch_pairs)
    single = measure("single (1 pair per call)", accounts, @single_pairs, 1)

    unboxed(fn ->
      assert balances(accounts.budget).debits_pending == @pairs + @single_pairs
      assert Ledger.verify_chain(1, head_seq()) == :ok
    end)

    assert batched > 0 and single > 0
  end
end
