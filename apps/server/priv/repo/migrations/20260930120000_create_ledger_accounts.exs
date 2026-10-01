defmodule Openmaru.Repo.Migrations.CreateLedgerAccounts do
  use Ecto.Migration

  # SPEC-03 §2–§3. Only Openmaru.Ledger writes this table.
  def change do
    create table(:ledger_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :key, :text, null: false
      add :ledger, :integer, null: false
      add :code, :integer, null: false
      # Bit 0 debits_must_not_exceed_credits, bit 1 credits_must_not_exceed_debits.
      add :flags, :integer, null: false, default: 0
      add :debits_pending, :bigint, null: false, default: 0
      add :debits_posted, :bigint, null: false, default: 0
      add :credits_pending, :bigint, null: false, default: 0
      add :credits_posted, :bigint, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:ledger_accounts, [:key])

    create constraint(:ledger_accounts, :key_not_empty, check: "key <> ''")
    create constraint(:ledger_accounts, :ledger_positive, check: "ledger > 0")
    create constraint(:ledger_accounts, :code_positive, check: "code > 0")
    # Known bits only, and the two balance constraints exclude each other.
    create constraint(:ledger_accounts, :flags_valid, check: "flags IN (0, 1, 2)")

    create constraint(:ledger_accounts, :balances_non_negative,
             check:
               "debits_pending >= 0 AND debits_posted >= 0 AND credits_pending >= 0 AND credits_posted >= 0"
           )

    execute(
      """
      CREATE FUNCTION ledger_accounts_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        -- Only the four balance columns may change.
        IF TG_OP = 'UPDATE' THEN
          IF (NEW.id, NEW.key, NEW.ledger, NEW.code, NEW.flags, NEW.inserted_at)
             IS NOT DISTINCT FROM (OLD.id, OLD.key, OLD.ledger, OLD.code, OLD.flags, OLD.inserted_at) THEN
            RETURN NEW;
          END IF;
        END IF;
        RAISE EXCEPTION 'ledger_accounts is immutable except for balances: % is not allowed', TG_OP
          USING ERRCODE = 'insufficient_privilege';
      END
      $$
      """,
      "DROP FUNCTION ledger_accounts_guard()"
    )

    execute(
      """
      CREATE TRIGGER ledger_accounts_immutable
      BEFORE UPDATE OR DELETE ON ledger_accounts
      FOR EACH ROW EXECUTE FUNCTION ledger_accounts_guard()
      """,
      "DROP TRIGGER ledger_accounts_immutable ON ledger_accounts"
    )

    execute(
      """
      CREATE TRIGGER ledger_accounts_no_truncate
      BEFORE TRUNCATE ON ledger_accounts
      FOR EACH STATEMENT EXECUTE FUNCTION ledger_accounts_guard()
      """,
      "DROP TRIGGER ledger_accounts_no_truncate ON ledger_accounts"
    )

    # System accounts (SPEC-03 §3). Ids are uuidv5(key) in the openmaru namespace
    # (Openmaru.Ledger.uuidv5/1); dropping the table removes them on rollback.
    execute(
      """
      INSERT INTO ledger_accounts (id, key, ledger, code, flags, inserted_at) VALUES
        ('13a8b848-795e-5365-8aab-dcb51235c51d', 'system:allowance_source', 1, 600, 0, now()),
        ('3dd63a3b-7c4c-520f-ae03-92e4f528ac2a', 'system:allowance_sink', 1, 610, 0, now())
      """,
      "SELECT 1"
    )
  end
end
