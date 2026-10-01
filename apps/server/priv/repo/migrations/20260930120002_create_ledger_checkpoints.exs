defmodule Openmaru.Repo.Migrations.CreateLedgerCheckpoints do
  use Ecto.Migration

  # SPEC-03 §2, §7. The table only; the daily checkpoint job is G04, anchoring G05.
  def change do
    create table(:ledger_checkpoints, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :date, :date, null: false
      add :first_seq, :bigint
      add :last_seq, :bigint, null: false
      add :count, :bigint, null: false
      add :head_hash, :binary, null: false
      add :prev_checkpoint_hash, :binary, null: false
      add :checkpoint_hash, :binary, null: false
      add :anchor, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:ledger_checkpoints, [:date])

    create constraint(:ledger_checkpoints, :hashes_32_bytes,
             check:
               "octet_length(head_hash) = 32 AND octet_length(prev_checkpoint_hash) = 32 AND octet_length(checkpoint_hash) = 32"
           )

    create constraint(:ledger_checkpoints, :count_non_negative, check: "count >= 0")

    # Checkpoints are immutable once written, except that the anchor (G05) can be set once.
    execute(
      """
      CREATE FUNCTION ledger_checkpoints_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF OLD.anchor IS NULL AND (to_jsonb(NEW) - 'anchor') = (to_jsonb(OLD) - 'anchor') THEN
            RETURN NEW;
          END IF;
        END IF;
        RAISE EXCEPTION 'ledger_checkpoints is immutable: % is not allowed', TG_OP
          USING ERRCODE = 'insufficient_privilege';
      END
      $$
      """,
      "DROP FUNCTION ledger_checkpoints_guard()"
    )

    execute(
      """
      CREATE TRIGGER ledger_checkpoints_immutable
      BEFORE UPDATE OR DELETE ON ledger_checkpoints
      FOR EACH ROW EXECUTE FUNCTION ledger_checkpoints_guard()
      """,
      "DROP TRIGGER ledger_checkpoints_immutable ON ledger_checkpoints"
    )

    execute(
      """
      CREATE TRIGGER ledger_checkpoints_no_truncate
      BEFORE TRUNCATE ON ledger_checkpoints
      FOR EACH STATEMENT EXECUTE FUNCTION ledger_checkpoints_guard()
      """,
      "DROP TRIGGER ledger_checkpoints_no_truncate ON ledger_checkpoints"
    )
  end
end
