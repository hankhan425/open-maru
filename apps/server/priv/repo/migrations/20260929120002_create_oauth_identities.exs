defmodule Openmaru.Repo.Migrations.CreateOauthIdentities do
  use Ecto.Migration

  def change do
    create table(:oauth_identities, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :provider, :text, null: false
      add :provider_uid, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_identities, [:provider, :provider_uid])
    create index(:oauth_identities, [:user_id])
    create constraint(:oauth_identities, :provider, check: "provider IN ('github', 'google')")
  end
end
