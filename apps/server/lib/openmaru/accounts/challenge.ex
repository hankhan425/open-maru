defmodule Openmaru.Accounts.Challenge do
  @moduledoc """
  Server-side state of an auth ceremony: a WebAuthn challenge (`passkey_registration`,
  `passkey_login`) or OAuth session params (`oauth`). Valid for 5 minutes and consumed
  by the first attempt to finish the ceremony (C01).
  """

  use Openmaru.Schema

  @type kind :: String.t()

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: kind() | nil,
          challenge: binary() | nil,
          user_id: Ecto.UUID.t() | nil,
          data: map() | nil,
          expires_at: DateTime.t() | nil,
          consumed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "auth_challenges" do
    field :kind, :string
    field :challenge, :binary
    field :user_id, Ecto.UUID
    field :data, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end
end
