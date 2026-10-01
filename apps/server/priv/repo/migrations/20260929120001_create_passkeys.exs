defmodule Openmaru.Repo.Migrations.CreatePasskeys do
  use Ecto.Migration

  def change do
    create table(:passkeys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :credential_id, :bytea, null: false
      # CBOR-encoded COSE public key.
      add :cose_key, :bytea, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :transports, {:array, :text}, null: false, default: []
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:passkeys, [:credential_id])
    create index(:passkeys, [:user_id])
  end
end
