defmodule Openmaru.Idempotency.Key do
  @moduledoc """
  A stored `Idempotency-Key` (CONVENTIONS §5): the request fingerprint and, once the
  first request finishes, its response. `status`/`body` are `nil` while it executes.
  """

  use Openmaru.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          principal: String.t() | nil,
          request_hash: String.t() | nil,
          status: pos_integer() | nil,
          body: String.t() | nil,
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "idempotency_keys" do
    field :key, :string
    field :principal, :string
    field :request_hash, :string
    field :status, :integer
    field :body, :string
    field :expires_at, :utc_datetime_usec

    timestamps()
  end
end
