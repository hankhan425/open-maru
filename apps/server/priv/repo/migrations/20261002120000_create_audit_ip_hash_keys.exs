defmodule Openmaru.Repo.Migrations.CreateAuditIpHashKeys do
  use Ecto.Migration

  def change do
    # SPEC-09 §7, OQ-6: one random key per UTC day hashes the audit log's client IPs. The key
    # is stored sealed under AUDIT_IP_HASH_KEY and destroyed (sealed_key cleared) 30 days after
    # its day ends, after which that day's hashes can no longer be linked to an address.
    # audit_log.ip_hash_key_id holds the id of the row that made a hash. Not unique per day:
    # two first writes of a day may each create a key, and readers take the oldest.
    create table(:audit_ip_hash_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :day, :date, null: false
      # Fingerprint of the wrapping key that sealed this key (Openmaru.Audit.key_id/1).
      add :wrapping_key_id, :text, null: false
      add :sealed_key, :bytea
      add :destroyed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_ip_hash_keys, [:day])

    create constraint(:audit_ip_hash_keys, :destroyed,
             check: "(sealed_key IS NULL) = (destroyed_at IS NOT NULL)"
           )
  end
end
