defmodule Openmaru.Audit.Entry do
  @moduledoc "A row of the append-only `audit_log` (SPEC-09 §7)."

  use Openmaru.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          action: String.t() | nil,
          actor_kind: String.t() | nil,
          actor_id: Ecto.UUID.t() | nil,
          target_type: String.t() | nil,
          target_id: Ecto.UUID.t() | nil,
          ip_hash: String.t() | nil,
          user_agent: String.t() | nil,
          metadata: map() | nil,
          occurred_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "audit_log" do
    field :action, :string
    field :actor_kind, :string
    field :actor_id, Ecto.UUID
    field :target_type, :string
    field :target_id, Ecto.UUID
    field :ip_hash, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
