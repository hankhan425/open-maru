defmodule Openmaru.Accounts.PersonalAccessToken do
  @moduledoc """
  A personal access token (SPEC-02 §2, SPEC-09 §1). Only the SHA-256 of the token and
  its last four characters are stored; `Openmaru.Accounts.PAT` creates and checks them.
  """

  use Openmaru.Schema

  import Ecto.Changeset

  @name_max 100
  @ttl_days_max 365

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          token_hash: binary() | nil,
          last4: String.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          last_used_at: DateTime.t() | nil,
          ttl_days: pos_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "personal_access_tokens" do
    field :user_id, Ecto.UUID
    field :name, :string
    field :token_hash, :binary
    field :last4, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :ttl_days, :integer, virtual: true

    timestamps()
  end

  @doc "Longest allowed name."
  @spec name_max() :: pos_integer()
  def name_max, do: @name_max

  @doc """
  A new token from `attrs`: `name` (required, trimmed, at most #{@name_max} characters)
  and optional `ttl_days` (1–#{@ttl_days_max}), which sets `expires_at` from `now`.
  """
  @spec create_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(token, attrs, now) do
    token
    |> cast(attrs, [:name, :ttl_days])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @name_max)
    |> validate_number(:ttl_days, greater_than: 0, less_than_or_equal_to: @ttl_days_max)
    |> put_expiry(now)
  end

  defp put_expiry(%Ecto.Changeset{valid?: true} = changeset, now) do
    case get_change(changeset, :ttl_days) do
      nil -> changeset
      days -> put_change(changeset, :expires_at, DateTime.add(now, days * 24 * 3600, :second))
    end
  end

  defp put_expiry(changeset, _now), do: changeset
end
