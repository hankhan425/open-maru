defmodule Openmaru.Repo.Migrations.CreatePersonalAccessTokens do
  use Ecto.Migration

  def change do
    # SPEC-09 §1: `om_pat_` + 32 random bytes; only the SHA-256 and the last four
    # characters are kept.
    create table(:personal_access_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :token_hash, :bytea, null: false
      add :last4, :text, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:personal_access_tokens, [:token_hash])
    create index(:personal_access_tokens, [:user_id])
  end
end
