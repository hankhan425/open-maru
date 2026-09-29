defmodule Openmaru.Accounts.UserSession do
  @moduledoc """
  A web session (SPEC-02 §2, SPEC-09 §1). The cookie carries an opaque 32-byte token;
  only its SHA-256 is stored. `expires_at` slides forward with activity; the virtual
  `extended` is `true` on the struct returned by the lookup that moved it.
  """

  use Openmaru.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          token_hash: binary() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          extended: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "user_sessions" do
    field :user_id, Ecto.UUID
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :extended, :boolean, virtual: true, default: false

    timestamps()
  end
end
