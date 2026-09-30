defmodule Openmaru.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def change do
    # SPEC-09 §7. No foreign keys: rows outlive the users and objects they mention.
    create table(:audit_log, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :action, :text, null: false
      add :actor_kind, :text
      add :actor_id, :uuid
      add :target_type, :text
      add :target_id, :uuid
      # Keyed hash of the client IP and the id of the key that made it (SPEC-09 §7, OQ-6).
      add :ip_hash, :text
      add :ip_hash_key_id, :text
      add :user_agent, :text
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_log, [:action, :occurred_at])
    create index(:audit_log, [:actor_kind, :actor_id, :occurred_at])
    create index(:audit_log, [:target_type, :target_id])

    create constraint(:audit_log, :actor_kind,
             check: "actor_kind IS NULL OR actor_kind IN ('person', 'agent', 'system')"
           )

    create constraint(:audit_log, :ip_hash_key_id,
             check: "(ip_hash IS NULL) = (ip_hash_key_id IS NULL)"
           )

    execute(
      """
      CREATE FUNCTION audit_log_reject_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'audit_log is append-only: % is not allowed', TG_OP
          USING ERRCODE = 'insufficient_privilege';
      END
      $$
      """,
      "DROP FUNCTION audit_log_reject_mutation()"
    )

    execute(
      """
      CREATE TRIGGER audit_log_append_only
      BEFORE UPDATE OR DELETE ON audit_log
      FOR EACH ROW EXECUTE FUNCTION audit_log_reject_mutation()
      """,
      "DROP TRIGGER audit_log_append_only ON audit_log"
    )

    execute(
      """
      CREATE TRIGGER audit_log_no_truncate
      BEFORE TRUNCATE ON audit_log
      FOR EACH STATEMENT EXECUTE FUNCTION audit_log_reject_mutation()
      """,
      "DROP TRIGGER audit_log_no_truncate ON audit_log"
    )
  end
end
