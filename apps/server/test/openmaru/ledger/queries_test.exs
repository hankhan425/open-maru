defmodule Openmaru.Ledger.QueriesTest do
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  alias Ecto.Multi
  alias Openmaru.{Error, Ledger, UUIDv7}

  @t0 ~U[2026-10-01 12:00:00.000000Z]

  setup do
    set_clock(@t0)
  end

  defp t(debit, credit, attrs),
    do: transfer([debit_account_id: debit, credit_account_id: credit, amount: 1] ++ attrs)

  describe "balance/1" do
    test "G01-T21 returns the four balances and available" do
      a = dmnec!() |> fund!(100)
      b = account!()
      create!(t(a, b, amount: 30, flags: [:pending]))
      create!(t(a, b, amount: 20))

      assert Ledger.balance(a) ==
               {:ok,
                %{
                  debits_pending: 30,
                  debits_posted: 20,
                  credits_pending: 0,
                  credits_posted: 100,
                  available: 50
                }}

      # Unconstrained accounts use the debit-side formula and may go negative.
      assert {:ok, %{available: 20, credits_pending: 30}} = Ledger.balance(b)
      drained = account!() |> drain!(5)
      assert {:ok, %{available: -5}} = Ledger.balance(drained)

      # CMNED accounts report what can still be credited.
      c = cmned!() |> drain!(40)
      create!(t(b, c, amount: 10, flags: [:pending]))
      assert {:ok, %{available: 30}} = Ledger.balance(c)
    end

    test "G01-T21 an unknown account → not_found" do
      assert {:error, %Error{code: :not_found}} = Ledger.balance(UUIDv7.generate())
    end
  end

  describe "lookups" do
    test "G01-T21 lookup_accounts and lookup_transfers keep input order and skip unknown ids" do
      a = account!()
      b = account!()
      [x, y] = create!([t(a, b, amount: 1), t(b, a, amount: 2)])
      missing = UUIDv7.generate()

      assert [%{id: ^b}, %{id: ^a}] = Ledger.lookup_accounts([b, missing, a])
      assert [%{amount: 2}, %{amount: 1}] = Ledger.lookup_transfers([y.id, missing, x.id])
      assert Ledger.lookup_transfers([]) == []
    end
  end

  describe "account_transfers/2" do
    setup do
      a = account!()
      b = account!()
      c = account!()

      at = fn seconds -> set_clock(DateTime.add(@t0, seconds, :second)) end

      ids =
        for {seconds, x} <-
              Enum.with_index(
                [
                  t(a, b, code: 31, user_data_64: 1_202_610),
                  t(c, a, code: 30, user_data_64: 1_202_610),
                  t(a, b, code: 31, user_data_64: 1_202_610),
                  t(b, c, code: 31, user_data_64: 1_202_610),
                  t(a, b, code: 31, user_data_64: 1_202_610),
                  t(c, a, code: 30, user_data_64: 1_202_611),
                  t(a, b, code: 31, user_data_64: 1_202_611),
                  t(a, b, code: 31, user_data_64: 1_202_610)
                ],
                fn x, i -> {i * 60, x} end
              ) do
          at.(seconds)
          create!(x)
          x.id
        end

      %{a: a, ids: ids}
    end

    defp page_ids({:ok, %{data: data, next_cursor: cursor}}),
      do: {Enum.map(data, & &1.id), cursor}

    defp all_pages(account, filter) do
      Stream.unfold(:start, fn
        nil ->
          nil

        cursor ->
          filter = if cursor == :start, do: filter, else: Keyword.put(filter, :cursor, cursor)
          {ids, next} = page_ids(Ledger.account_transfers(account, filter))
          {ids, next}
      end)
      |> Enum.to_list()
    end

    test "G01-T21 lists an account's transfers in seq order, either side", %{a: a, ids: ids} do
      expected = List.delete_at(ids, 3)
      assert {^expected, nil} = page_ids(Ledger.account_transfers(a, []))
      assert {desc, nil} = page_ids(Ledger.account_transfers(a, order: :desc))
      assert desc == Enum.reverse(expected)
    end

    test "G01-T21 filters by code, period key and time range", %{a: a, ids: ids} do
      [s0, r1, s2, _other, s4, r5, s6, s7] = ids

      assert page_ids(Ledger.account_transfers(a, code: 31)) == {[s0, s2, s4, s6, s7], nil}
      assert page_ids(Ledger.account_transfers(a, code: [30])) == {[r1, r5], nil}
      assert page_ids(Ledger.account_transfers(a, period_key: 1_202_611)) == {[r5, s6], nil}

      assert page_ids(Ledger.account_transfers(a, code: 31, period_key: 1_202_610)) ==
               {[s0, s2, s4, s7], nil}

      # `from` is inclusive, `to` exclusive.
      from = DateTime.add(@t0, 120, :second)
      to = DateTime.add(@t0, 360, :second)
      assert page_ids(Ledger.account_transfers(a, from: from, to: to)) == {[s2, s4, r5], nil}

      assert page_ids(Ledger.account_transfers(a, from: from, to: to, code: 31)) ==
               {[s2, s4], nil}
    end

    test "G01-T21 paginates with an opaque cursor", %{a: a, ids: ids} do
      [s0, _r1, s2, _other, s4, _r5, s6, s7] = ids

      assert all_pages(a, code: 31, limit: 2) == [[s0, s2], [s4, s6], [s7]]
      assert all_pages(a, code: 31, limit: 5) == [[s0, s2, s4, s6, s7]]
      assert all_pages(a, code: 31, limit: 2, order: :desc) == [[s7, s6], [s4, s2], [s0]]

      assert {[^s0, ^s2], cursor} = page_ids(Ledger.account_transfers(a, code: 31, limit: 2))
      assert is_binary(cursor)
    end

    test "G01-T21 a bad cursor or limit → invalid_request", %{a: a} do
      for filter <- [
            [cursor: "not a cursor"],
            [cursor: "!!"],
            [limit: 0],
            [limit: 1001],
            [order: :sideways]
          ] do
        assert {:error, %Error{code: :invalid_request}} = Ledger.account_transfers(a, filter),
               inspect(filter)
      end
    end
  end

  describe "multi_create_transfers/3" do
    test "G01-T11 commits with the caller's other writes and rolls back with them" do
      a = dmnec!() |> fund!(100)
      b = account!()
      seq = head_seq()

      multi =
        Multi.new()
        |> Multi.put(:amount, 40)
        |> Ledger.multi_create_transfers(:hold, fn %{amount: amount} ->
          [t(a, b, amount: amount, flags: [:pending])]
        end)

      assert {:ok, %{hold: [{:ok, :created}]}} = Repo.transaction(multi)
      assert balances(a) == bal(debits_pending: 40, credits_posted: 100)

      failing =
        Multi.new()
        |> Ledger.multi_create_transfers(:ok_step, [t(a, b, amount: 10)])
        |> Ledger.multi_create_transfers(:ledger, [
          t(a, b, amount: 1, flags: [:linked]),
          t(a, b, amount: 100)
        ])
        |> Multi.run(:after, fn _repo, _changes -> flunk("must not run") end)

      assert {:error, :ledger, [{:error, :linked_event_failed}, {:error, :exceeds_credits}], _} =
               Repo.transaction(failing)

      later_failure =
        Multi.new()
        |> Ledger.multi_create_transfers(:ledger, [t(a, b, amount: 10)])
        |> Multi.run(:boom, fn _repo, _changes -> {:error, :boom} end)

      assert {:error, :boom, :boom, %{ledger: [{:ok, :created}]}} =
               Repo.transaction(later_failure)

      assert balances(a) == bal(debits_pending: 40, credits_posted: 100)
      assert head_seq() == seq + 1
    end
  end
end
