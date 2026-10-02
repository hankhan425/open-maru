defmodule Openmaru.Repo.Migrations.CreateDeviceCodes do
  use Ecto.Migration

  def change do
    # The CLI's device login (SPEC-09 §1): 10-minute codes, polled every 5 s, used once.
    create table(:device_codes, primary_key: false) do
      add :id, :uuid, primary_key: true
      # SHA-256 of the device code; the code itself is never stored.
      add :device_code_hash, :bytea, null: false
      # Eight characters without the hyphen shown to people.
      add :user_code, :text, null: false
      add :status, :text, null: false, default: "pending"
      # The user who approved or denied the code.
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      # The requesting client's user agent; names the token (`CLI (<user agent>)`).
      add :user_agent, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :interval_secs, :integer, null: false, default: 5
      add :last_polled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_codes, [:device_code_hash])
    create unique_index(:device_codes, [:user_code])
    create index(:device_codes, [:expires_at])

    create constraint(:device_codes, :status,
             check: "status IN ('pending', 'approved', 'denied', 'expired', 'consumed')"
           )

    create constraint(:device_codes, :user_code_format,
             check: "user_code ~ '^[BCDFGHJKLMNPQRSTVWXZ2-9]{8}$'"
           )

    create constraint(:device_codes, :decided_by_user,
             check: "status IN ('pending', 'expired') OR user_id IS NOT NULL"
           )
  end
end
