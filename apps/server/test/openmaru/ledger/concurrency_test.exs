defmodule Openmaru.Ledger.ConcurrencyTest do
  # Commits outside the sandbox: real concurrent transactions contend for the ledger lock.
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  alias Openmaru.{Ledger, UUIDv7}

  defp committed_seqs(account_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT seq FROM ledger_transfers
        WHERE debit_account_id = ANY($1) OR credit_account_id = ANY($1)
        ORDER BY seq
        """,
        [Enum.map(account_ids, &Ecto.UUID.dump!/1)]
      )

    List.flatten(rows)
  end

  test "G01-T18 50 concurrent 1-unit transfers from a DMNEC account holding 25 → exactly 25 created" do
    {a, b, source} = unboxed(fn -> {dmnec!(), account!(), account!(code: 100)} end)
    on_exit(fn -> delete_committed!([a, b, source]) end)

    unboxed(fn ->
      create!(transfer(debit_account_id: source, credit_account_id: a, amount: 25))
    end)

    results =
      1..50
      |> Task.async_stream(
        fn _ ->
          unboxed(fn ->
            Ledger.create_transfers([
              transfer(
                debit_account_id: a,
                credit_account_id: b,
                amount: 1,
                id: UUIDv7.generate()
              )
            ])
          end)
        end,
        max_concurrency: 50,
        timeout: 60_000,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, result} -> result end)

    assert Enum.frequencies(results) == %{{:ok, :created} => 25, {:error, :exceeds_credits} => 25}

    unboxed(fn ->
      seqs = committed_seqs([a, b, source])
      assert length(seqs) == 26
      assert seqs == Enum.to_list(hd(seqs)..(hd(seqs) + 25))

      # The whole committed chain is gapless from 1 and verifies.
      head = head_seq()
      assert Repo.aggregate("ledger_transfers", :count) == head
      assert Ledger.verify_chain(1, head) == :ok

      assert balances(a) == bal(debits_posted: 25, credits_posted: 25)
      assert balances(b) == bal(credits_posted: 25)
      assert Ledger.verify_balances() == :ok

      {:ok, %{data: rows}} = Ledger.account_transfers(a, limit: 100)
      timestamps = Enum.map(rows, & &1.timestamp)

      assert timestamps == Enum.sort(timestamps) and timestamps == Enum.uniq(timestamps)
    end)
  end

  test "G01-T18 concurrent identical batches create once; the rest see exists" do
    {a, b} = unboxed(fn -> {account!(), account!()} end)
    on_exit(fn -> delete_committed!([a, b]) end)

    batch = [
      transfer(debit_account_id: a, credit_account_id: b, amount: 3, flags: [:linked]),
      transfer(debit_account_id: b, credit_account_id: a, amount: 1)
    ]

    results =
      1..20
      |> Task.async_stream(fn _ -> unboxed(fn -> Ledger.create_transfers(batch) end) end,
        max_concurrency: 20,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.frequencies(results) == %{
             [{:ok, :created}, {:ok, :created}] => 1,
             [{:ok, :exists}, {:ok, :exists}] => 19
           }

    unboxed(fn ->
      assert balances(a) == bal(debits_posted: 3, credits_posted: 1)
      assert length(committed_seqs([a, b])) == 2
    end)
  end
end
