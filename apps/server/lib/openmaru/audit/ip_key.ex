defmodule Openmaru.Audit.IpKey do
  @moduledoc """
  A key for the audit log's IP hashes (SPEC-09 §7, OQ-6): random, for one UTC `day`, stored
  sealed under the configured wrapping key (`wrapping_key_id` is that key's fingerprint).
  Destroying it clears `sealed_key` and sets `destroyed_at`.
  """

  use Openmaru.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          day: Date.t() | nil,
          wrapping_key_id: String.t() | nil,
          sealed_key: binary() | nil,
          destroyed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "audit_ip_hash_keys" do
    field :day, :date
    field :wrapping_key_id, :string
    field :sealed_key, :binary, redact: true
    field :destroyed_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
