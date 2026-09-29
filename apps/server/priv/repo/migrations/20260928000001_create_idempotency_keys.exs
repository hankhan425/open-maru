defmodule Openmaru.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :key, :text, null: false
      add :principal, :text, null: false
      add :request_hash, :text, null: false
      # NULL status/body: the first request is still executing.
      add :status, :integer
      add :body, :text
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_keys, [:principal, :key])
    create index(:idempotency_keys, [:expires_at])
  end
end
