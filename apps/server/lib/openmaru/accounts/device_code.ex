defmodule Openmaru.Accounts.DeviceCode do
  @moduledoc """
  A device login in progress (SPEC-02 §2, SPEC-09 §1): the CLI holds the device code
  (stored as SHA-256), a person types the user code (stored as eight characters, shown
  as `XXXX-XXXX`). `Openmaru.Accounts.Device` drives it from `pending` to `approved` or
  `denied`, and from `approved` to `consumed` when the token is issued.
  """

  use Openmaru.Schema

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          device_code_hash: binary() | nil,
          user_code: String.t() | nil,
          status: status() | nil,
          user_id: Ecto.UUID.t() | nil,
          user_agent: String.t() | nil,
          expires_at: DateTime.t() | nil,
          interval_secs: pos_integer() | nil,
          last_polled_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "device_codes" do
    field :device_code_hash, :binary
    field :user_code, :string
    field :status, :string, default: "pending"
    field :user_id, Ecto.UUID
    field :user_agent, :string
    field :expires_at, :utc_datetime_usec
    field :interval_secs, :integer, default: 5
    field :last_polled_at, :utc_datetime_usec

    timestamps()
  end
end
