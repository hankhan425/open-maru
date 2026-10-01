defmodule Openmaru.Accounts.OAuthIdentity do
  @moduledoc "A GitHub or Google account linked to a user (SPEC-02 §2, SPEC-09 §1)."

  use Openmaru.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          provider: String.t() | nil,
          provider_uid: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "oauth_identities" do
    field :user_id, Ecto.UUID
    field :provider, :string
    field :provider_uid, :string

    timestamps()
  end
end
