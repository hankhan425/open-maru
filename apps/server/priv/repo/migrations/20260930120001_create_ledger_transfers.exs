defmodule Openmaru.Repo.Migrations.CreateLedgerTransfers do
  use Ecto.Migration

  # SPEC-03 §2, §4, §7. Only Openmaru.Ledger writes these tables.
  def change do
    create table(:ledger_transfers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :debit_account_id, references(:ledger_accounts, type: :uuid), null: false
      add :credit_account_id, references(:ledger_accounts, type: :uuid), null: false
      add :amount, :bigint, null: false
      add :requested_amount, :bigint, null: false
      add :pending_id, references(:ledger_transfers, type: :uuid)
      # Bits: 0 linked, 1 pending, 2 post_pending, 3 void_pending, 4 balancing_debit,
      # 5 balancing_credit.
      add :flags, :integer, null: false
      add :timeout_secs, :integer, null: false
      add :ledger, :integer, null: false
      add :code, :integer, null: false
      add :user_data_128, :uuid
      add :user_data_64, :bigint
      # Server-assigned microseconds since the Unix epoch, strictly increasing.
      add :timestamp, :bigint, null: false
      add :seq, :bigint, null: false
      add :prev_hash, :binary, null: false
      add :hash, :binary, null: false
    end

    create unique_index(:ledger_transfers, [:seq])
    create unique_index(:ledger_transfers, [:timestamp])
    create index(:ledger_transfers, [:debit_account_id, :seq])
    create index(:ledger_transfers, [:credit_account_id, :seq])

    # A pending transfer resolves (post, void or expiry) at most once.
    create unique_index(:ledger_transfers, [:pending_id],
             where: "(flags & 12) <> 0",
             name: :ledger_transfers_pending_id_resolves_once
           )

    create constraint(:ledger_transfers, :amounts_valid,
             check: "amount >= 0 AND requested_amount >= amount"
           )

    create constraint(:ledger_transfers, :accounts_different,
             check: "debit_account_id <> credit_account_id"
           )

    create constraint(:ledger_transfers, :flags_valid, check: "flags >= 0 AND flags < 64")

    create constraint(:ledger_transfers, :pending_id_iff_resolution,
             check: "(pending_id IS NOT NULL) = ((flags & 12) <> 0)"
           )

    create constraint(:ledger_transfers, :timeout_only_pending,
             check: "timeout_secs >= 0 AND (timeout_secs = 0 OR (flags & 2) <> 0)"
           )

    create constraint(:ledger_transfers, :ledger_and_code_positive,
             check: "ledger > 0 AND code > 0"
           )

    create constraint(:ledger_transfers, :seq_positive, check: "seq > 0")

    create constraint(:ledger_transfers, :hashes_32_bytes,
             check: "octet_length(prev_hash) = 32 AND octet_length(hash) = 32"
           )

    execute(
      """
      CREATE FUNCTION ledger_transfers_reject_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'ledger_transfers is immutable: % is not allowed', TG_OP
          USING ERRCODE = 'insufficient_privilege';
      END
      $$
      """,
      "DROP FUNCTION ledger_transfers_reject_mutation()"
    )

    execute(
      """
      CREATE TRIGGER ledger_transfers_immutable
      BEFORE UPDATE OR DELETE ON ledger_transfers
      FOR EACH ROW EXECUTE FUNCTION ledger_transfers_reject_mutation()
      """,
      "DROP TRIGGER ledger_transfers_immutable ON ledger_transfers"
    )

    execute(
      """
      CREATE TRIGGER ledger_transfers_no_truncate
      BEFORE TRUNCATE ON ledger_transfers
      FOR EACH STATEMENT EXECUTE FUNCTION ledger_transfers_reject_mutation()
      """,
      "DROP TRIGGER ledger_transfers_no_truncate ON ledger_transfers"
    )

    # Unresolved pending transfers with a timeout, for the expiry sweeper. Derived state:
    # a row is added with its pending transfer and removed when that transfer resolves,
    # so the sweeper never scans resolved history.
    create table(:ledger_pending_expiries, primary_key: false) do
      add :pending_id, references(:ledger_transfers, type: :uuid), primary_key: true
      # Microseconds since the Unix epoch: the pending timestamp + timeout_secs.
      add :expires_at, :bigint, null: false
    end

    create index(:ledger_pending_expiries, [:expires_at, :pending_id])
  end
end
