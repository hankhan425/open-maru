defmodule Openmaru.Ledger.ChainTest do
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  alias Openmaru.Ledger
  alias Openmaru.Ledger.Chain

  @vectors_path "test/fixtures/ledger_vectors.json"

  defp vectors, do: @vectors_path |> File.read!() |> Jason.decode!()

  defp int(nil), do: nil
  defp int(value) when is_binary(value), do: String.to_integer(value)

  defp account_input(json) do
    %{
      id: json["id"],
      key: json["key"],
      ledger: json["ledger"],
      code: json["code"],
      flags: Enum.map(json["flags"], &String.to_existing_atom/1)
    }
  end

  defp transfer_input(json) do
    Map.new(json, fn
      {"flags", flags} ->
        {:flags, Enum.map(flags, &String.to_existing_atom/1)}

      {key, value} when key in ["amount", "user_data_64"] ->
        {String.to_existing_atom(key), int(value)}

      {key, value} ->
        {String.to_existing_atom(key), value}
    end)
  end

  # Replays the vector history: one create_transfers call (or sweeper run) per step.
  defp replay_vectors!(vectors) do
    results = vectors["accounts"] |> Enum.map(&account_input/1) |> Ledger.create_accounts()
    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

    for step <- vectors["steps"] do
      {:ok, clock, 0} = DateTime.from_iso8601(step["clock"])
      set_clock(clock)

      case step do
        %{"expire" => true} -> assert {:ok, 1} = Ledger.expire_pending()
        %{"create_transfers" => inputs} -> create!(Enum.map(inputs, &transfer_input/1))
      end
    end

    :ok
  end

  defp tamper!(sql, params) do
    Repo.query!("ALTER TABLE ledger_transfers DISABLE TRIGGER USER")
    Repo.query!(sql, params)
    Repo.query!("ALTER TABLE ledger_transfers ENABLE TRIGGER USER")
  end

  defp some_transfers!(n) do
    a = account!()
    b = account!()
    for i <- 1..n, do: hd(create!(transfer(debit_account_id: a, credit_account_id: b, amount: i)))
  end

  describe "hash chain" do
    test "G01-T15 seq is gapless from 1 and hashes equal ledger_vectors.json from scripts/ledger_vector.py" do
      vectors = vectors()
      assert head_seq() == 0
      replay_vectors!(vectors)

      expected = vectors["transfers"]
      stored = expected |> Enum.map(& &1["id"]) |> Ledger.lookup_transfers()
      assert Enum.map(stored, & &1.seq) == Enum.to_list(1..length(expected))

      for {json, row} <- Enum.zip(expected, stored) do
        assert %{
                 id: json["id"],
                 debit_account_id: json["debit_account_id"],
                 credit_account_id: json["credit_account_id"],
                 amount: int(json["amount"]),
                 requested_amount: int(json["requested_amount"]),
                 pending_id: json["pending_id"],
                 flags: json["flags"],
                 timeout_secs: json["timeout_secs"],
                 ledger: json["ledger"],
                 code: json["code"],
                 user_data_128: json["user_data_128"],
                 user_data_64: int(json["user_data_64"]),
                 timestamp: int(json["timestamp"]),
                 seq: int(json["seq"])
               } == %{
                 Map.take(row, [
                   :id,
                   :debit_account_id,
                   :credit_account_id,
                   :amount,
                   :requested_amount,
                   :pending_id,
                   :timeout_secs,
                   :ledger,
                   :code,
                   :user_data_128,
                   :user_data_64,
                   :timestamp,
                   :seq
                 ])
                 | flags: Chain.flag_bits(row.flags)
               },
               "row seq #{json["seq"]}"

        assert Base.encode16(Chain.encode(row), case: :lower) == json["encoded"]
        assert Base.encode16(row.prev_hash, case: :lower) == json["prev_hash"]
        assert Base.encode16(row.hash, case: :lower) == json["hash"], "hash at seq #{json["seq"]}"
      end

      assert hd(expected)["prev_hash"] == vectors["genesis_prev_hash"]
      assert Ledger.verify_chain(1, length(expected)) == :ok
    end

    test "G01-T15 the fixture is the script's current output" do
      script = Path.expand("../../scripts/ledger_vector.py", File.cwd!())

      case System.find_executable("python3") do
        nil ->
          flunk("python3 is required to check #{@vectors_path} against scripts/ledger_vector.py")

        python ->
          assert {output, 0} = System.cmd(python, [script])
          assert output == File.read!(@vectors_path)
      end
    end

    test "G01-T15 each row links to the previous row's hash" do
      rows = some_transfers!(4) |> Enum.map(& &1.id) |> Ledger.lookup_transfers()

      assert Enum.map(rows, & &1.seq) == [1, 2, 3, 4]
      assert hd(rows).prev_hash == :binary.copy(<<0>>, 32)

      for [prev, row] <- Enum.chunk_every(rows, 2, 1, :discard) do
        assert row.prev_hash == prev.hash
        assert row.hash == :crypto.hash(:sha256, prev.hash <> Chain.encode(row))
      end
    end
  end

  describe "verify_chain/2" do
    test "G01-T16 a tampered amount → {:error, {:hash_mismatch, seq}}" do
      [_, x | _] = some_transfers!(4)
      assert Ledger.verify_chain(1, 4) == :ok

      tamper!("UPDATE ledger_transfers SET amount = amount + 1 WHERE id = $1", [
        Ecto.UUID.dump!(x.id)
      ])

      assert Ledger.verify_chain(1, 4) == {:error, {:hash_mismatch, 2}}
      assert Ledger.verify_chain(2, 2) == {:error, {:hash_mismatch, 2}}
      # A range after the tampered row trusts the row before it and still verifies.
      assert Ledger.verify_chain(3, 4) == :ok
    end

    test "G01-T16 tampered hashes and links, and missing rows, are detected" do
      [_, _, x, _] = some_transfers!(4)
      id = Ecto.UUID.dump!(x.id)

      tamper!("UPDATE ledger_transfers SET prev_hash = sha256(prev_hash) WHERE id = $1", [id])
      assert Ledger.verify_chain(1, 4) == {:error, {:hash_mismatch, 3}}

      # Correct link, altered stored hash.
      tamper!("UPDATE ledger_transfers SET prev_hash = $2, hash = sha256(hash) WHERE id = $1", [
        id,
        hash_at(2)
      ])

      assert Ledger.verify_chain(1, 4) == {:error, {:hash_mismatch, 3}}

      tamper!("DELETE FROM ledger_transfers WHERE id = $1", [id])
      assert Ledger.verify_chain(1, 4) == {:error, {:seq_gap, 3}}
    end

    test "G01-T16 an empty or partial range verifies what exists" do
      assert Ledger.verify_chain(1, 10) == :ok
      some_transfers!(3)
      assert Ledger.verify_chain(1, 10) == :ok
      assert Ledger.verify_chain(2, 3) == :ok
    end
  end

  defp hash_at(seq) do
    %{rows: [[hash]]} = Repo.query!("SELECT hash FROM ledger_transfers WHERE seq = $1", [seq])
    hash
  end

  describe "verify_balances/0" do
    test "G01-T17 a drifted balance column → {:error, [{account_id, expected, actual}]}" do
      a = dmnec!() |> fund!(100)
      b = account!()
      create!(transfer(debit_account_id: a, credit_account_id: b, amount: 30, flags: [:pending]))

      [p] =
        create!(
          transfer(debit_account_id: a, credit_account_id: b, amount: 20, flags: [:pending])
        )

      create!(transfer(flags: [:post_pending], pending_id: p.id, amount: 15, code: nil))
      create!(transfer(debit_account_id: a, credit_account_id: b, amount: 5))

      assert Ledger.verify_balances() == :ok

      Repo.query!(
        "UPDATE ledger_accounts SET credits_posted = credits_posted + 7 WHERE id = $1",
        [
          Ecto.UUID.dump!(a)
        ]
      )

      expected = bal(debits_pending: 30, debits_posted: 20, credits_posted: 100)
      actual = %{expected | credits_posted: 107}
      assert Ledger.verify_balances() == {:error, [{a, expected, actual}]}

      Repo.query!("UPDATE ledger_accounts SET credits_pending = 1 WHERE id = $1", [
        Ecto.UUID.dump!(b)
      ])

      assert {:error, drifted} = Ledger.verify_balances()

      assert Enum.sort(drifted) ==
               Enum.sort([
                 {a, expected, actual},
                 {b, bal(credits_pending: 30, credits_posted: 20),
                  bal(credits_pending: 1, credits_posted: 20)}
               ])
    end
  end
end
