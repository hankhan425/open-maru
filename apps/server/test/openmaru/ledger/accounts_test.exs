defmodule Openmaru.Ledger.AccountsTest do
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  alias Openmaru.{Ledger, UUIDv7}

  defp account_attrs(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Enum.into(attrs, %{
      id: UUIDv7.generate(),
      key: "goal:#{n}:funds",
      code: 300,
      flags: [:debits_must_not_exceed_credits]
    })
  end

  describe "create_accounts/1" do
    test "G01-T01 stores flags and codes; same id and fields → exists; different fields → exists_with_different_fields" do
      goal = account_attrs()

      donations =
        account_attrs(
          code: 100,
          key: "org:1:ext_donations",
          flags: [:credits_must_not_exceed_debits]
        )

      sink = account_attrs(code: 400, key: "goal:1:spend:llm", flags: [])

      assert Ledger.create_accounts([goal, donations, sink]) ==
               [{:ok, :created}, {:ok, :created}, {:ok, :created}]

      assert [g, d, s] = Ledger.lookup_accounts([goal.id, donations.id, sink.id])
      assert %{id: id, key: key, ledger: 1, code: 300} = g
      assert {id, key} == {goal.id, goal.key}
      assert g.flags == [:debits_must_not_exceed_credits]
      assert d.flags == [:credits_must_not_exceed_debits] and d.code == 100
      assert s.flags == [] and s.code == 400
      assert balances(goal.id) == bal()

      # Flags are bits in the row (SPEC-03 §2): bit 0 DMNEC, bit 1 CMNED.
      %{rows: rows} =
        Repo.query!(
          "SELECT code, flags FROM ledger_accounts WHERE id = ANY($1) ORDER BY code",
          [Enum.map([goal, donations, sink], &Ecto.UUID.dump!(&1.id))]
        )

      assert rows == [[100, 2], [300, 1], [400, 0]]

      assert Ledger.create_accounts([goal]) == [{:ok, :exists}]
      assert Ledger.create_accounts([Map.put(goal, :ledger, 1)]) == [{:ok, :exists}]

      for changed <- [
            %{goal | code: 310},
            %{goal | key: goal.key <> ":other"},
            %{goal | flags: []},
            %{goal | flags: [:credits_must_not_exceed_debits]},
            Map.put(goal, :ledger, 2)
          ] do
        assert Ledger.create_accounts([changed]) == [{:error, :exists_with_different_fields}],
               "expected exists_with_different_fields for #{inspect(changed)}"
      end

      assert [%{code: 300, flags: [:debits_must_not_exceed_credits]}] =
               Ledger.lookup_accounts([goal.id])
    end

    test "G01-T01 duplicates within one batch are compared with the first" do
      account = account_attrs()

      assert Ledger.create_accounts([account, account, %{account | code: 301}]) ==
               [{:ok, :created}, {:ok, :exists}, {:error, :exists_with_different_fields}]
    end

    test "G01-T01 a key held by another id → key_exists" do
      account = account_attrs()
      assert Ledger.create_accounts([account]) == [{:ok, :created}]
      other = %{account | id: UUIDv7.generate()}
      assert Ledger.create_accounts([other]) == [{:error, :key_exists}]
      assert Ledger.lookup_accounts([other.id]) == []
    end

    test "G01-T01 invalid accounts are rejected with a code and not stored" do
      cases = [
        {account_attrs(flags: [:debits_must_not_exceed_credits, :credits_must_not_exceed_debits]),
         :flags_are_mutually_exclusive},
        {account_attrs(id: nil), :id_must_not_be_zero},
        {account_attrs(id: "00000000-0000-0000-0000-000000000000"), :id_must_not_be_zero},
        {account_attrs(code: 0), :code_must_not_be_zero},
        {account_attrs(ledger: 0), :ledger_must_not_be_zero},
        {account_attrs(key: ""), :key_must_not_be_empty}
      ]

      for {account, code} <- cases do
        assert Ledger.create_accounts([account]) == [{:error, code}], inspect(account)
      end

      assert Ledger.lookup_accounts(for {%{id: id}, _} <- cases, is_binary(id), do: id) == []
    end

    test "G01-T01 the system allowance accounts exist with deterministic ids" do
      source = Ledger.system_account_id(:allowance_source)
      sink = Ledger.system_account_id(:allowance_sink)

      assert source == Ledger.uuidv5("system:allowance_source")
      assert sink == Ledger.uuidv5("system:allowance_sink")

      assert [
               %{key: "system:allowance_source", code: 600, flags: [], ledger: 1},
               %{key: "system:allowance_sink", code: 610, flags: [], ledger: 1}
             ] = Ledger.lookup_accounts([source, sink])
    end
  end

  describe "uuidv5/1" do
    test "G01-T15 matches the vectors from scripts/ledger_vector.py" do
      vectors = "test/fixtures/ledger_vectors.json" |> File.read!() |> Jason.decode!()

      assert Ledger.namespace() == vectors["namespace"]

      for %{"name" => name, "uuid" => uuid} <- vectors["uuidv5"] do
        assert Ledger.uuidv5(name) == uuid, "uuidv5(#{inspect(name)})"
      end
    end
  end
end
