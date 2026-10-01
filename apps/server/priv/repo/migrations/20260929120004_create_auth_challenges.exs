defmodule Openmaru.Repo.Migrations.CreateAuthChallenges do
  use Ecto.Migration

  def change do
    # Server-side WebAuthn challenges and OAuth state: 5-minute TTL, single use.
    create table(:auth_challenges, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :kind, :text, null: false
      add :challenge, :bytea
      # The signed-in user who started the ceremony, if any.
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :data, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:auth_challenges, [:expires_at])

    create constraint(:auth_challenges, :kind,
             check: "kind IN ('passkey_registration', 'passkey_login', 'oauth')"
           )
  end
end
