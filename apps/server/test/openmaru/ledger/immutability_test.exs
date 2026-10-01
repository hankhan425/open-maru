defmodule Openmaru.Ledger.ImmutabilityTest do
  use Openmaru.DataCase, async: false

  import Openmaru.LedgerHelpers

  setup do
    a = account!()
    b = account!()
    [x] = create!(transfer(debit_account_id: a, credit_account_id: b, amount: 10))
    %{a: Ecto.UUID.dump!(a), x: Ecto.UUID.dump!(x.id)}
  end

  # Runs `sql` in a savepoint so the sandbox transaction survives the error.
  defp rejected?(sql, params) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> Repo.query!(sql, params) end)
      end

    assert Exception.message(error) =~ "immutable"
    true
  end

  test "G01-T14 raw UPDATE and DELETE on transfers raise", %{x: x} do
    for sql <- [
          "UPDATE ledger_transfers SET amount = 11 WHERE id = $1",
          "UPDATE ledger_transfers SET hash = sha256(hash) WHERE id = $1",
          "UPDATE ledger_transfers SET seq = seq WHERE id = $1",
          "DELETE FROM ledger_transfers WHERE id = $1"
        ] do
      assert rejected?(sql, [x]), sql
    end

    assert rejected?("TRUNCATE ledger_transfers CASCADE", [])

    assert %{rows: [[10]]} =
             Repo.query!("SELECT amount FROM ledger_transfers WHERE id = $1", [x])
  end

  test "G01-T14 account flags, code and key cannot change; rows cannot be deleted", %{a: a} do
    for sql <- [
          "UPDATE ledger_accounts SET flags = 1 WHERE id = $1",
          "UPDATE ledger_accounts SET code = 999 WHERE id = $1",
          "UPDATE ledger_accounts SET key = 'tampered' WHERE id = $1",
          "UPDATE ledger_accounts SET ledger = 2 WHERE id = $1",
          "UPDATE ledger_accounts SET inserted_at = now() WHERE id = $1",
          "DELETE FROM ledger_accounts WHERE id = $1"
        ] do
      assert rejected?(sql, [a]), sql
    end

    assert rejected?("TRUNCATE ledger_accounts CASCADE", [])
  end

  test "G01-T14 balance columns stay updatable", %{a: a} do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE ledger_accounts
        SET debits_pending = debits_pending + 1, debits_posted = debits_posted + 1,
            credits_pending = credits_pending + 1, credits_posted = credits_posted + 1
        WHERE id = $1
        """,
        [a]
      )

    assert %{rows: [[1, 11, 1, 1]]} =
             Repo.query!(
               "SELECT debits_pending, debits_posted, credits_pending, credits_posted FROM ledger_accounts WHERE id = $1",
               [a]
             )
  end

  test "G01-T14 a second resolution of one pending transfer violates the partial unique index" do
    a = account!()
    b = account!()

    [p] =
      create!(transfer(debit_account_id: a, credit_account_id: b, amount: 5, flags: [:pending]))

    [_post] = create!(transfer(flags: [:post_pending], pending_id: p.id, code: nil))

    %{rows: [row]} =
      Repo.query!(
        "SELECT debit_account_id, credit_account_id, ledger, code FROM ledger_transfers WHERE id = $1",
        [Ecto.UUID.dump!(p.id)]
      )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO ledger_transfers (id, debit_account_id, credit_account_id, amount,
              requested_amount, pending_id, flags, timeout_secs, ledger, code, timestamp, seq,
              prev_hash, hash)
            VALUES ($1, $2, $3, 5, 5, $4, 8, 0, $5, $6, 9e15::bigint, 1000000, $7, $7)
            """,
            [Ecto.UUID.dump!(Openmaru.UUIDv7.generate())] ++
              Enum.take(row, 2) ++
              [Ecto.UUID.dump!(p.id)] ++ Enum.drop(row, 2) ++ [:binary.copy(<<0>>, 32)]
          )
        end)
      end

    assert %{postgres: %{code: :unique_violation}} = error
  end

  test "G01-T14 a checkpoint row is immutable except that its anchor can be set once" do
    id = Ecto.UUID.dump!(Openmaru.UUIDv7.generate())
    hash = :binary.copy(<<1>>, 32)

    Repo.query!(
      """
      INSERT INTO ledger_checkpoints (id, date, first_seq, last_seq, count, head_hash,
        prev_checkpoint_hash, checkpoint_hash, inserted_at)
      VALUES ($1, '2026-09-30', 1, 3, 3, $2, $2, $2, now())
      """,
      [id, hash]
    )

    %{num_rows: 1} =
      Repo.query!(~s(UPDATE ledger_checkpoints SET anchor = '{"tx": "abc"}' WHERE id = $1), [id])

    for sql <- [
          ~s(UPDATE ledger_checkpoints SET anchor = '{"tx": "other"}' WHERE id = $1),
          "UPDATE ledger_checkpoints SET count = 4 WHERE id = $1",
          "DELETE FROM ledger_checkpoints WHERE id = $1"
        ] do
      assert rejected?(sql, [id]), sql
    end

    assert rejected?("TRUNCATE ledger_checkpoints", [])
  end
end
