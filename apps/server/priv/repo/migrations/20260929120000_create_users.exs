defmodule Openmaru.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true
      # NULL until the user picks one; immutable once set (C01).
      add :handle, :citext
      add :display_name, :text
      add :email, :citext
      add :platform_role, :text, null: false, default: "user"
      add :suspended_at, :utc_datetime_usec
      # WebAuthn user.id: 32 random bytes, shared by all of the user's passkeys.
      add :webauthn_user_handle, :bytea

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:handle])
    create unique_index(:users, [:email])
    create unique_index(:users, [:webauthn_user_handle])

    # citext's regex operators ignore case; compare the text value.
    create constraint(:users, :handle_format,
             check: "handle IS NULL OR handle::text ~ '^[a-z0-9][a-z0-9_-]{1,29}$'"
           )

    create constraint(:users, :platform_role, check: "platform_role IN ('user', 'admin')")
  end
end
