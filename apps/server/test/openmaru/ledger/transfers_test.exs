defmodule Openmaru.Ledger.TransfersTest do
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  alias Openmaru.{Ledger, UUIDv7}

  @t0 ~U[2026-10-01 12:00:00.000000Z]

  setup do
    set_clock(@t0)
  end

  defp lookup!(id) do
    [transfer] = Ledger.lookup_transfers([id])
    transfer
  end

  describe "simple transfers" do
    test "G01-T02 a transfer updates debits_posted and credits_posted on both accounts" do
      a = account!()
      b = account!()

      assert Ledger.create_transfers([
               transfer(debit_account_id: a, credit_account_id: b, amount: 125)
             ]) ==
               [{:ok, :created}]

      assert balances(a) == bal(debits_posted: 125)
      assert balances(b) == bal(credits_posted: 125)

      create!(transfer(debit_account_id: b, credit_account_id: a, amount: 25))
      assert balances(a) == bal(debits_posted: 125, credits_posted: 25)
      assert balances(b) == bal(debits_posted: 25, credits_posted: 125)
    end

    test "G01-T02 the stored row carries the fields, requested_amount = amount, ledger from the accounts" do
      a = account!(ledger: 7)
      b = account!(ledger: 7)
      ref = UUIDv7.generate()

      [t] =
        create!(
          transfer(
            debit_account_id: a,
            credit_account_id: b,
            amount: 9,
            code: 20,
            user_data_128: ref,
            user_data_64: 1_202_610
          )
        )

      assert %{
               amount: 9,
               requested_amount: 9,
               ledger: 7,
               code: 20,
               flags: [],
               timeout_secs: 0,
               pending_id: nil,
               user_data_128: ^ref,
               user_data_64: 1_202_610,
               seq: 1
             } = lookup!(t.id)
    end
  end

  # Builds the accounts every validation-order case draws from. `a` (DMNEC) has 89
  # available after `e` (a → b, 1) and the pending `p` (a → b, 10); `c` (CMNED) has
  # debits 50; `hi_c`/`hi_d` sit 10 below the i64 maximum on the credit/debit side.
  defp world do
    a = dmnec!() |> fund!(100)
    b = account!()
    d = account!()
    c = cmned!() |> drain!(50)
    l2 = account!(ledger: 2)
    hi_c = account!() |> fund!(i64_max() - 10)
    hi_d = account!() |> drain!(i64_max() - 10)
    src = account!(code: 100)
    [e] = create!(transfer(debit_account_id: a, credit_account_id: b, amount: 1))

    [p] =
      create!(transfer(debit_account_id: a, credit_account_id: b, amount: 10, flags: [:pending]))

    %{
      a: a,
      b: b,
      c: c,
      d: d,
      l2: l2,
      hi_c: hi_c,
      hi_d: hi_d,
      src: src,
      e: e,
      p: p.id,
      m: UUIDv7.generate(),
      m2: UUIDv7.generate()
    }
  end

  defp t(debit, credit, attrs \\ []),
    do: transfer([debit_account_id: debit, credit_account_id: credit, amount: 1] ++ attrs)

  # Posts and voids omit the code by default: it comes from the pending transfer.
  defp post(attrs), do: transfer([flags: [:post_pending], code: nil] ++ attrs)
  defp void(attrs), do: transfer([flags: [:void_pending], code: nil] ++ attrs)

  # {earlier code (wins), later code, fn world -> {setup transfers, transfer under test}}.
  # Pairs that cannot occur together are omitted: an identical replay (`exists`) of a
  # stored transfer cannot break a static rule; a ledger comparison needs both accounts;
  # a zero amount cannot overflow or exceed a limit; a post or void never re-checks limits.
  defp pairs do
    [
      {:exists, :pending_transfer_already_posted,
       fn w ->
         x = post(pending_id: w.p)
         {[x], x}
       end},
      {:exists, :overflows,
       fn w ->
         x = t(w.src, w.hi_c, amount: 10)
         {[x], x}
       end},
      {:exists, :exceeds_credits,
       fn w ->
         x = t(w.a, w.b, amount: 89)
         {[x], x}
       end},
      {:exists, :exceeds_debits,
       fn w ->
         x = t(w.b, w.c, amount: 50)
         {[x], x}
       end},
      {:exists_with_different_fields, :accounts_must_be_different,
       &{[], %{&1.e | debit_account_id: &1.b, credit_account_id: &1.b}}},
      {:exists_with_different_fields, :debit_account_not_found,
       &{[], %{&1.e | debit_account_id: &1.m}}},
      {:exists_with_different_fields, :credit_account_not_found,
       &{[], %{&1.e | credit_account_id: &1.m}}},
      {:exists_with_different_fields, :accounts_must_have_the_same_ledger,
       &{[], %{&1.e | credit_account_id: &1.l2}}},
      {:exists_with_different_fields, :amount_must_not_be_zero, &{[], %{&1.e | amount: 0}}},
      {:exists_with_different_fields, :timeout_reserved_for_pending_transfer,
       &{[], %{&1.e | timeout_secs: 5}}},
      {:exists_with_different_fields, :pending_transfer_not_found,
       &{[],
        Map.merge(&1.e, %{
          flags: [:post_pending],
          pending_id: &1.m,
          debit_account_id: nil,
          credit_account_id: nil
        })}},
      {:exists_with_different_fields, :overflows,
       &{[], %{&1.e | credit_account_id: &1.hi_c, amount: 11}}},
      {:exists_with_different_fields, :exceeds_credits, &{[], %{&1.e | amount: 1000}}},
      {:exists_with_different_fields, :exceeds_debits,
       &{[], %{&1.e | debit_account_id: &1.b, credit_account_id: &1.c, amount: 1000}}},
      {:accounts_must_be_different, :debit_account_not_found, &{[], t(&1.m, &1.m)}},
      {:accounts_must_be_different, :credit_account_not_found, &{[], t(&1.m, &1.m)}},
      {:accounts_must_be_different, :amount_must_not_be_zero, &{[], t(&1.b, &1.b, amount: 0)}},
      {:accounts_must_be_different, :timeout_reserved_for_pending_transfer,
       &{[], t(&1.b, &1.b, timeout_secs: 5)}},
      {:accounts_must_be_different, :pending_transfer_not_found,
       &{[], post(pending_id: &1.m, debit_account_id: &1.b, credit_account_id: &1.b)}},
      {:accounts_must_be_different, :overflows, &{[], t(&1.hi_c, &1.hi_c, amount: 11)}},
      {:accounts_must_be_different, :exceeds_credits, &{[], t(&1.a, &1.a, amount: 1000)}},
      {:accounts_must_be_different, :exceeds_debits, &{[], t(&1.c, &1.c, amount: 1000)}},
      {:debit_account_not_found, :credit_account_not_found, &{[], t(&1.m, &1.m2)}},
      {:debit_account_not_found, :amount_must_not_be_zero, &{[], t(&1.m, &1.b, amount: 0)}},
      {:debit_account_not_found, :timeout_reserved_for_pending_transfer,
       &{[], t(&1.m, &1.b, timeout_secs: 5)}},
      {:debit_account_not_found, :pending_transfer_not_found,
       &{[], post(pending_id: &1.m2, debit_account_id: &1.m)}},
      {:debit_account_not_found, :overflows, &{[], t(&1.m, &1.hi_c, amount: 11)}},
      {:debit_account_not_found, :exceeds_debits, &{[], t(&1.m, &1.c, amount: 1000)}},
      {:credit_account_not_found, :amount_must_not_be_zero, &{[], t(&1.b, &1.m, amount: 0)}},
      {:credit_account_not_found, :timeout_reserved_for_pending_transfer,
       &{[], t(&1.b, &1.m, timeout_secs: 5)}},
      {:credit_account_not_found, :pending_transfer_not_found,
       &{[], post(pending_id: &1.m2, credit_account_id: &1.m)}},
      {:credit_account_not_found, :overflows, &{[], t(&1.hi_d, &1.m, amount: 11)}},
      {:credit_account_not_found, :exceeds_credits, &{[], t(&1.a, &1.m, amount: 1000)}},
      {:accounts_must_have_the_same_ledger, :amount_must_not_be_zero,
       &{[], t(&1.b, &1.l2, amount: 0)}},
      {:accounts_must_have_the_same_ledger, :timeout_reserved_for_pending_transfer,
       &{[], t(&1.b, &1.l2, timeout_secs: 5)}},
      {:accounts_must_have_the_same_ledger, :pending_transfer_not_found,
       &{[], post(pending_id: &1.m, debit_account_id: &1.b, credit_account_id: &1.l2)}},
      {:accounts_must_have_the_same_ledger, :overflows, &{[], t(&1.hi_d, &1.l2, amount: 11)}},
      {:accounts_must_have_the_same_ledger, :exceeds_credits,
       &{[], t(&1.a, &1.l2, amount: 1000)}},
      {:accounts_must_have_the_same_ledger, :exceeds_debits, &{[], t(&1.l2, &1.c, amount: 1000)}},
      {:amount_must_not_be_zero, :timeout_reserved_for_pending_transfer,
       &{[], t(&1.b, &1.d, amount: 0, timeout_secs: 5)}},
      {:amount_must_not_be_zero, :pending_transfer_not_found,
       &{[], void(pending_id: &1.m, amount: 0)}},
      {:timeout_reserved_for_pending_transfer, :pending_transfer_not_found,
       &{[], post(pending_id: &1.m, timeout_secs: 5)}},
      {:timeout_reserved_for_pending_transfer, :overflows,
       &{[], t(&1.b, &1.hi_c, amount: 11, timeout_secs: 5)}},
      {:timeout_reserved_for_pending_transfer, :exceeds_credits,
       &{[], t(&1.a, &1.b, amount: 1000, timeout_secs: 5)}},
      {:timeout_reserved_for_pending_transfer, :exceeds_debits,
       &{[], t(&1.b, &1.c, amount: 1000, timeout_secs: 5)}},
      {:exceeds_pending_transfer_amount, :overflows,
       &{[], post(pending_id: &1.p, amount: i64_max())}},
      {:overflows, :exceeds_credits, &{[], t(&1.a, &1.hi_c, amount: 200)}},
      {:overflows, :exceeds_debits, &{[], t(&1.hi_d, &1.c, amount: 1000)}},
      {:exceeds_credits, :exceeds_debits, &{[], t(&1.a, &1.c, amount: 1000)}}
    ]
  end

  # One violation at a time: every code in the table above is reachable on its own.
  defp singles do
    [
      {:exists_with_different_fields, &%{&1.e | amount: 2}},
      {:accounts_must_be_different, &t(&1.b, &1.b)},
      {:debit_account_not_found, &t(&1.m, &1.b)},
      {:credit_account_not_found, &t(&1.b, &1.m)},
      {:accounts_must_have_the_same_ledger, &t(&1.b, &1.l2)},
      {:amount_must_not_be_zero, &t(&1.b, &1.d, amount: 0)},
      {:timeout_reserved_for_pending_transfer, &t(&1.b, &1.d, timeout_secs: 5)},
      {:pending_transfer_not_found, &post(pending_id: &1.m)},
      {:exceeds_pending_transfer_amount, &post(pending_id: &1.p, amount: 11)},
      {:overflows, &t(&1.b, &1.hi_c, amount: 11)},
      {:overflows, &t(&1.hi_d, &1.b, amount: 11)},
      {:exceeds_credits, &t(&1.a, &1.b, amount: 90)},
      {:exceeds_debits, &t(&1.b, &1.c, amount: 51)}
    ]
  end

  describe "validation order" do
    test "G01-T03 for each pair of simultaneous violations the earlier SPEC-03 §4.2 code wins" do
      for {earlier, later, build} <- pairs() do
        w = world()
        {setup, x} = build.(w)
        if setup != [], do: create!(setup)
        before = {head_seq(), snapshot([w.a, w.b, w.c, w.hi_c, w.hi_d])}

        expected = if earlier == :exists, do: {:ok, :exists}, else: {:error, earlier}

        assert Ledger.create_transfers([x]) == [expected],
               "#{earlier} should win over #{later} for #{inspect(x)}"

        assert {head_seq(), snapshot([w.a, w.b, w.c, w.hi_c, w.hi_d])} == before
      end
    end

    test "G01-T03 each code is reachable on its own" do
      for {code, build} <- singles() do
        w = world()
        assert Ledger.create_transfers([build.(w)]) == [{:error, code}], inspect(code)
      end
    end

    test "G01-T03 malformed transfers get their own codes before any account check" do
      w = world()
      id = UUIDv7.generate()

      cases = [
        {t(w.m, w.b, id: nil), :id_must_not_be_zero},
        {t(w.m, w.b, id: "00000000-0000-0000-0000-000000000000"), :id_must_not_be_zero},
        {t(w.m, w.b, flags: [:pending, :post_pending]), :flags_are_mutually_exclusive},
        {t(w.m, w.b, flags: [:post_pending, :void_pending]), :flags_are_mutually_exclusive},
        {t(w.m, w.b, flags: [:balancing_debit, :void_pending]), :flags_are_mutually_exclusive},
        {post(pending_id: nil, debit_account_id: w.m), :pending_id_must_not_be_zero},
        {post(id: id, pending_id: id, debit_account_id: w.m), :pending_id_must_be_different},
        {t(w.m, w.b, pending_id: w.p), :pending_id_must_be_zero},
        {t(w.m, w.b, code: nil), :code_must_not_be_zero},
        {t(w.m, w.b, code: 0), :code_must_not_be_zero}
      ]

      for {x, code} <- cases do
        assert Ledger.create_transfers([x]) == [{:error, code}], inspect(x)
      end
    end
  end

  describe "balance limits" do
    test "G01-T04 a DMNEC violation → exceeds_credits; no balance change, no row, no seq consumed" do
      a = dmnec!() |> fund!(100)
      b = account!()
      seq = head_seq()
      before = snapshot([a, b])

      x = transfer(debit_account_id: a, credit_account_id: b, amount: 101)
      assert Ledger.create_transfers([x]) == [{:error, :exceeds_credits}]

      assert snapshot([a, b]) == before
      assert Ledger.lookup_transfers([x.id]) == []
      assert head_seq() == seq

      [ok] = create!(transfer(debit_account_id: a, credit_account_id: b, amount: 100))
      assert lookup!(ok.id).seq == seq + 1
      assert balances(a) == bal(debits_posted: 100, credits_posted: 100)
    end

    test "G01-T04 a CMNED violation → exceeds_debits" do
      c = cmned!() |> drain!(30)
      b = account!()

      assert Ledger.create_transfers([
               transfer(debit_account_id: b, credit_account_id: c, amount: 31)
             ]) ==
               [{:error, :exceeds_debits}]

      create!(transfer(debit_account_id: b, credit_account_id: c, amount: 30))
      assert balances(c) == bal(debits_posted: 30, credits_posted: 30)
    end

    test "G01-T13 amounts that would overflow a balance near i64 max → overflows" do
      max = i64_max()
      b = account!()

      hi_credit = account!() |> fund!(max - 10)
      assert [{:error, :overflows}] = Ledger.create_transfers([t(b, hi_credit, amount: 11)])
      create!(t(b, hi_credit, amount: 10))
      assert balances(hi_credit).credits_posted == max

      hi_debit = account!() |> drain!(max - 10)
      assert [{:error, :overflows}] = Ledger.create_transfers([t(hi_debit, b, amount: 11)])

      # Pending and posted debits together may not pass the maximum either.
      assert [{:error, :overflows}] =
               Ledger.create_transfers([t(hi_debit, b, amount: 11, flags: [:pending])])

      hi_pending = account!()
      create!(t(hi_pending, b, amount: max - 5, flags: [:pending]))
      assert [{:error, :overflows}] = Ledger.create_transfers([t(hi_pending, b, amount: 6)])

      assert [{:error, :overflows}] =
               Ledger.create_transfers([t(hi_pending, b, amount: 6, flags: [:pending])])

      assert balances(hi_pending) == bal(debits_pending: max - 5)
    end
  end

  describe "idempotency" do
    test "G01-T05 the same batch twice → the second returns exists for all; balances unchanged" do
      a = dmnec!() |> fund!(1000)
      b = account!()
      c = account!()
      p = UUIDv7.generate()

      batch = [
        t(a, b, amount: 100),
        t(a, c, amount: 50, flags: [:pending], timeout_secs: 60, id: p),
        post(pending_id: p, amount: 40),
        t(a, b, amount: 5, flags: [:linked]),
        t(b, c, amount: 5),
        t(a, c, amount: 10_000, flags: [:balancing_debit]),
        t(c, a, amount: 1, user_data_128: UUIDv7.generate(), user_data_64: -7)
      ]

      results = Ledger.create_transfers(batch)
      assert results == List.duplicate({:ok, :created}, length(batch))
      seq = head_seq()
      before = snapshot([a, b, c])

      assert Ledger.create_transfers(batch) == List.duplicate({:ok, :exists}, length(batch))
      assert head_seq() == seq
      assert snapshot([a, b, c]) == before

      # Each unlinked transfer on its own is also an exact replay (a linked one alone would
      # be an open chain).
      for x <- batch,
          :linked not in x.flags,
          do: assert(Ledger.create_transfers([x]) == [{:ok, :exists}])

      [linked | _] = for x <- batch, :linked in x.flags, do: x
      assert Ledger.create_transfers([linked]) == [{:error, :linked_event_chain_open}]
    end

    test "G01-T05 a post replay matches whether accounts, code and amount were omitted or given" do
      a = account!()
      b = account!()
      ref = UUIDv7.generate()
      [p] = create!(t(a, b, amount: 50, code: 31, flags: [:pending], user_data_128: ref))
      x = post(pending_id: p.id, code: nil)
      create!(x)

      assert %{
               amount: 50,
               code: 31,
               debit_account_id: ^a,
               credit_account_id: ^b,
               user_data_128: ^ref
             } =
               lookup!(x.id)

      for same <- [
            x,
            %{x | code: 31},
            Map.merge(x, %{amount: 50, debit_account_id: a, credit_account_id: b}),
            Map.put(x, :user_data_128, ref)
          ] do
        assert Ledger.create_transfers([same]) == [{:ok, :exists}], inspect(same)
      end

      for different <- [
            Map.put(x, :amount, 49),
            Map.put(x, :user_data_128, UUIDv7.generate()),
            Map.put(x, :user_data_64, 1),
            %{x | flags: [:void_pending]}
          ] do
        assert Ledger.create_transfers([different]) == [{:error, :exists_with_different_fields}],
               inspect(different)
      end
    end

    test "G01-T05 a balancing replay compares the requested amount, not the amount moved" do
      a = dmnec!() |> fund!(60)
      b = account!()
      x = t(a, b, amount: 100, flags: [:balancing_debit])
      create!(x)

      assert Ledger.create_transfers([x]) == [{:ok, :exists}]

      assert Ledger.create_transfers([%{x | amount: 60}]) ==
               [{:error, :exists_with_different_fields}]
    end
  end

  describe "two-phase transfers" do
    test "G01-T06 a pending transfer increments pending balances and counts toward DMNEC" do
      a = dmnec!() |> fund!(100)
      b = account!()

      create!(t(a, b, amount: 70, flags: [:pending]))
      assert balances(a) == bal(debits_pending: 70, credits_posted: 100)
      assert balances(b) == bal(credits_pending: 70)

      assert Ledger.create_transfers([t(a, b, amount: 31)]) == [{:error, :exceeds_credits}]

      assert Ledger.create_transfers([t(a, b, amount: 31, flags: [:pending])]) ==
               [{:error, :exceeds_credits}]

      create!(t(a, b, amount: 30))
      assert balances(a) == bal(debits_pending: 70, debits_posted: 30, credits_posted: 100)
    end

    test "G01-T06 pending credits count toward CMNED" do
      c = cmned!() |> drain!(50)
      b = account!()
      create!(t(b, c, amount: 40, flags: [:pending]))
      assert Ledger.create_transfers([t(b, c, amount: 11)]) == [{:error, :exceeds_debits}]
      create!(t(b, c, amount: 10))
    end

    test "G01-T07 post in full (amount nil) and in part; above the pending amount → exceeds_pending_transfer_amount" do
      a = dmnec!() |> fund!(200)
      b = account!()

      [p1] = create!(t(a, b, amount: 50, flags: [:pending], code: 31))
      [full] = create!(post(pending_id: p1.id))
      assert balances(a) == bal(debits_posted: 50, credits_posted: 200)
      assert balances(b) == bal(credits_posted: 50)

      assert %{amount: 50, requested_amount: 50, pending_id: pending_id, flags: [:post_pending]} =
               lookup!(full.id)

      assert pending_id == p1.id

      [p2] = create!(t(a, b, amount: 50, flags: [:pending]))
      [part] = create!(post(pending_id: p2.id, amount: 20))
      assert lookup!(part.id).amount == 20
      assert balances(a) == bal(debits_posted: 70, credits_posted: 200)
      assert balances(b) == bal(credits_posted: 70)

      [p3] = create!(t(a, b, amount: 50, flags: [:pending]))

      assert Ledger.create_transfers([post(pending_id: p3.id, amount: 51)]) ==
               [{:error, :exceeds_pending_transfer_amount}]

      assert balances(a) == bal(debits_pending: 50, debits_posted: 70, credits_posted: 200)

      # Posting zero is allowed: it releases the hold and moves nothing.
      create!(post(pending_id: p3.id, amount: 0))
      assert balances(a) == bal(debits_posted: 70, credits_posted: 200)
    end

    test "G01-T07 post takes accounts, code and user data from the pending transfer; given ones must match" do
      a = account!()
      b = account!()
      other = account!()
      ref = UUIDv7.generate()

      [p] =
        create!(
          t(a, b,
            amount: 5,
            code: 31,
            flags: [:pending],
            user_data_128: ref,
            user_data_64: 1_202_610
          )
        )

      assert Ledger.create_transfers([post(pending_id: p.id, debit_account_id: other)]) ==
               [{:error, :pending_transfer_has_different_debit_account_id}]

      assert Ledger.create_transfers([post(pending_id: p.id, credit_account_id: other)]) ==
               [{:error, :pending_transfer_has_different_credit_account_id}]

      assert Ledger.create_transfers([post(pending_id: p.id, code: 32)]) ==
               [{:error, :pending_transfer_has_different_code}]

      [x] = create!(post(pending_id: p.id, debit_account_id: a, credit_account_id: b, code: nil))

      assert %{
               debit_account_id: ^a,
               credit_account_id: ^b,
               code: 31,
               ledger: 1,
               user_data_128: ^ref,
               user_data_64: 1_202_610
             } = lookup!(x.id)
    end

    test "G01-T08 void releases the full amount; a different amount → pending_transfer_has_different_amount" do
      a = dmnec!() |> fund!(100)
      b = account!()

      [p] = create!(t(a, b, amount: 60, flags: [:pending]))

      assert Ledger.create_transfers([void(pending_id: p.id, amount: 59)]) ==
               [{:error, :pending_transfer_has_different_amount}]

      assert balances(a) == bal(debits_pending: 60, credits_posted: 100)

      [v] = create!(void(pending_id: p.id))
      assert %{amount: 60, flags: [:void_pending]} = lookup!(v.id)
      assert balances(a) == bal(credits_posted: 100)
      assert balances(b) == bal()

      # Voiding with the exact amount is also accepted.
      [p2] = create!(t(a, b, amount: 25, flags: [:pending]))
      create!(void(pending_id: p2.id, amount: 25))
      assert balances(a) == bal(credits_posted: 100)
    end

    test "G01-T09 a pending transfer resolves at most once" do
      a = dmnec!() |> fund!(100)
      b = account!()

      [p1] = create!(t(a, b, amount: 10, flags: [:pending]))
      create!(post(pending_id: p1.id))

      assert Ledger.create_transfers([post(pending_id: p1.id)]) ==
               [{:error, :pending_transfer_already_posted}]

      assert Ledger.create_transfers([void(pending_id: p1.id)]) ==
               [{:error, :pending_transfer_already_posted}]

      [p2] = create!(t(a, b, amount: 10, flags: [:pending]))
      create!(void(pending_id: p2.id))

      assert Ledger.create_transfers([post(pending_id: p2.id)]) ==
               [{:error, :pending_transfer_already_voided}]

      assert Ledger.create_transfers([void(pending_id: p2.id)]) ==
               [{:error, :pending_transfer_already_voided}]

      [plain] = create!(t(a, b, amount: 10))

      assert Ledger.create_transfers([post(pending_id: plain.id)]) ==
               [{:error, :pending_transfer_not_pending}]

      assert Ledger.create_transfers([post(pending_id: UUIDv7.generate())]) ==
               [{:error, :pending_transfer_not_found}]

      assert balances(a) == bal(debits_posted: 20, credits_posted: 100)
    end

    test "G01-T09 two resolutions of one pending in the same batch: the second fails" do
      a = account!()
      b = account!()
      [p] = create!(t(a, b, amount: 10, flags: [:pending]))

      assert Ledger.create_transfers([
               post(pending_id: p.id, amount: 4),
               void(pending_id: p.id)
             ]) == [{:ok, :created}, {:error, :pending_transfer_already_posted}]

      assert balances(a) == bal(debits_posted: 4)
    end

    test "G01-T09 a pending created earlier in the same batch can be posted" do
      a = account!()
      b = account!()
      p = UUIDv7.generate()

      assert Ledger.create_transfers([
               t(a, b, id: p, amount: 10, flags: [:pending]),
               post(pending_id: p, amount: 3)
             ]) == [{:ok, :created}, {:ok, :created}]

      assert balances(b) == bal(credits_posted: 3)
    end
  end

  describe "linked chains" do
    test "G01-T11 a chain is all-or-nothing; the failing member gets its code, the others linked_event_failed" do
      a = dmnec!() |> fund!(100)
      b = account!()
      seq = head_seq()

      chain = [
        t(a, b, amount: 60, flags: [:linked]),
        t(a, b, amount: 50, flags: [:linked]),
        t(b, a, amount: 1)
      ]

      assert Ledger.create_transfers(chain) == [
               {:error, :linked_event_failed},
               {:error, :exceeds_credits},
               {:error, :linked_event_failed}
             ]

      assert balances(a) == bal(credits_posted: 100)
      assert balances(b) == bal()
      assert head_seq() == seq
      assert Ledger.lookup_transfers(Enum.map(chain, & &1.id)) == []

      ok_chain = [
        t(a, b, amount: 60, flags: [:linked]),
        t(a, b, amount: 40, flags: [:linked]),
        t(b, a, amount: 1)
      ]

      assert Ledger.create_transfers(ok_chain) == List.duplicate({:ok, :created}, 3)
      assert balances(a) == bal(debits_posted: 100, credits_posted: 101)
    end

    test "G01-T11 a later member sees the effects of earlier members of its chain" do
      a = dmnec!()
      b = account!()

      assert Ledger.create_transfers([t(b, a, amount: 30, flags: [:linked]), t(a, b, amount: 30)]) ==
               [{:ok, :created}, {:ok, :created}]

      assert Ledger.create_transfers([t(b, a, amount: 30, flags: [:linked]), t(a, b, amount: 31)]) ==
               [{:error, :linked_event_failed}, {:error, :exceeds_credits}]

      assert balances(a) == bal(debits_posted: 30, credits_posted: 30)
    end

    test "G01-T11 independent transfers in the batch still apply; an open chain at batch end → linked_event_chain_open" do
      a = dmnec!() |> fund!(100)
      b = account!()

      batch = [
        t(a, b, amount: 10),
        t(a, b, amount: 10, flags: [:linked]),
        t(a, b, amount: 500),
        t(a, b, amount: 20),
        t(a, b, amount: 1, flags: [:linked]),
        t(a, b, amount: 1, flags: [:linked])
      ]

      assert Ledger.create_transfers(batch) == [
               {:ok, :created},
               {:error, :linked_event_failed},
               {:error, :exceeds_credits},
               {:ok, :created},
               {:error, :linked_event_chain_open},
               {:error, :linked_event_chain_open}
             ]

      assert balances(a) == bal(debits_posted: 30, credits_posted: 100)

      assert Ledger.create_transfers([t(a, b, amount: 1, flags: [:linked])]) ==
               [{:error, :linked_event_chain_open}]
    end

    test "G01-T11 a first-member failure fails the rest of the chain without evaluating it" do
      a = dmnec!()
      b = account!()

      assert Ledger.create_transfers([
               t(a, b, amount: 1, flags: [:linked]),
               t(b, UUIDv7.generate(), amount: 1, flags: [:linked]),
               t(b, a, amount: 1)
             ]) == [
               {:error, :exceeds_credits},
               {:error, :linked_event_failed},
               {:error, :linked_event_failed}
             ]
    end

    test "G01-T11 a replayed member counts as success inside a chain" do
      a = dmnec!() |> fund!(10)
      b = account!()
      [x] = create!(t(a, b, amount: 5))

      assert Ledger.create_transfers([t(a, b, amount: 5, flags: [:linked]), x]) ==
               [{:ok, :created}, {:ok, :exists}]

      # When the chain fails, the replayed member is reported as failed with it.
      assert Ledger.create_transfers([t(a, b, amount: 1, flags: [:linked]), x]) ==
               [{:error, :exceeds_credits}, {:error, :linked_event_failed}]
    end
  end

  describe "balancing transfers" do
    test "G01-T12 balancing_debit moves min(requested, available) and records the request" do
      a = dmnec!() |> fund!(60)
      b = account!()

      [x] = create!(t(a, b, amount: 100, flags: [:balancing_debit]))
      assert %{amount: 60, requested_amount: 100, flags: [:balancing_debit]} = lookup!(x.id)
      assert balances(a) == bal(debits_posted: 60, credits_posted: 60)

      # Nothing available: amount 0 is accepted for balancing transfers.
      [y] = create!(t(a, b, amount: 100, flags: [:balancing_debit]))
      assert %{amount: 0, requested_amount: 100} = lookup!(y.id)
      assert balances(a) == bal(debits_posted: 60, credits_posted: 60)
    end

    test "G01-T12 pending debits reduce what a balancing debit can take" do
      a = dmnec!() |> fund!(100)
      b = account!()
      create!(t(a, b, amount: 30, flags: [:pending]))

      [x] = create!(t(a, b, amount: 100, flags: [:balancing_debit]))
      assert lookup!(x.id).amount == 70
      assert balances(a) == bal(debits_pending: 30, debits_posted: 70, credits_posted: 100)
    end

    test "G01-T12 balancing_credit is symmetric and a request below availability moves the request" do
      c = cmned!() |> drain!(40)
      b = account!()

      [x] = create!(t(b, c, amount: 100, flags: [:balancing_credit]))
      assert %{amount: 40, requested_amount: 100} = lookup!(x.id)

      a = dmnec!() |> fund!(100)
      [y] = create!(t(a, b, amount: 25, flags: [:balancing_debit]))
      assert %{amount: 25, requested_amount: 25} = lookup!(y.id)

      # Unconstrained accounts with no credit balance give 0, never a negative amount.
      d = account!() |> drain!(5)
      [z] = create!(t(d, b, amount: 10, flags: [:balancing_debit]))
      assert lookup!(z.id).amount == 0

      # The period reset pattern: request the i64 maximum to empty the account.
      [r] = create!(t(a, b, amount: i64_max(), flags: [:balancing_debit]))
      assert %{amount: 75, requested_amount: requested} = lookup!(r.id)
      assert requested == i64_max()
    end

    test "G01-T12 a balancing pending transfer holds the actual amount" do
      a = dmnec!() |> fund!(40)
      b = account!()
      [x] = create!(t(a, b, amount: 100, flags: [:pending, :balancing_debit]))
      assert %{amount: 40, requested_amount: 100} = lookup!(x.id)
      assert balances(a) == bal(debits_pending: 40, credits_posted: 40)
      create!(post(pending_id: x.id))
      assert balances(a) == bal(debits_posted: 40, credits_posted: 40)
    end
  end

  describe "timestamps" do
    test "G01-T20 timestamps strictly increase even when the Clock repeats or goes back" do
      a = account!()
      b = account!()

      ids =
        Enum.flat_map(1..3, fn i ->
          if i == 3, do: set_clock(DateTime.add(@t0, -5, :second))
          [single] = create!(t(a, b))
          pair = create!([t(a, b, flags: [:linked]), t(b, a)])
          [single.id | Enum.map(pair, & &1.id)]
        end)

      timestamps = ids |> Ledger.lookup_transfers() |> Enum.map(& &1.timestamp)
      assert timestamps == Enum.sort(timestamps)
      assert timestamps == Enum.uniq(timestamps)
      assert hd(timestamps) == micros(@t0)
      assert List.last(timestamps) == micros(@t0) + length(ids) - 1
    end

    test "G01-T20 a later Clock reading is used as is" do
      a = account!()
      b = account!()
      [x] = create!(t(a, b))
      set_clock(DateTime.add(@t0, 90, :second))
      [y, z] = create!([t(a, b), t(a, b)])

      assert [micros(@t0), micros(@t0) + 90_000_000, micros(@t0) + 90_000_001] ==
               [x.id, y.id, z.id] |> Ledger.lookup_transfers() |> Enum.map(& &1.timestamp)
    end
  end
end
