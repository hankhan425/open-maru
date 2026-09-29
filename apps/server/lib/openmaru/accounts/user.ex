defmodule Openmaru.Accounts.User do
  @moduledoc """
  A person (SPEC-02 §2). Created handle-less by the first sign-in; the handle is picked
  once and never changes (C01).

  Handles match `^[a-z0-9][a-z0-9_-]{1,29}$` after lower-casing, are unique ignoring
  case (`citext`), and exclude a reserved list.
  """

  use Openmaru.Schema

  import Ecto.Changeset

  @handle_format ~r/\A[a-z0-9][a-z0-9_-]{1,29}\z/
  @reserved_handles ~w(admin api app auth help mcp openmaru root settings support system www gw)
  @display_name_max 80

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          handle: String.t() | nil,
          display_name: String.t() | nil,
          email: String.t() | nil,
          platform_role: String.t() | nil,
          suspended_at: DateTime.t() | nil,
          webauthn_user_handle: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "users" do
    field :handle, :string
    field :display_name, :string
    field :email, :string
    field :platform_role, :string, default: "user"
    field :suspended_at, :utc_datetime_usec
    field :webauthn_user_handle, :binary

    timestamps()
  end

  @doc "Handles nobody may take."
  @spec reserved_handles() :: [String.t()]
  def reserved_handles, do: @reserved_handles

  @doc "Whether the user is suspended (SPEC-09 §6)."
  @spec suspended?(t()) :: boolean()
  def suspended?(%__MODULE__{suspended_at: suspended_at}), do: not is_nil(suspended_at)

  @doc "A new user from a first sign-in: optional provider-verified `email` and `display_name`."
  @spec registration_changeset(map()) :: Ecto.Changeset.t()
  def registration_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:email, :display_name, :webauthn_user_handle])
    |> update_change(:display_name, &String.trim/1)
    |> update_change(:display_name, &truncate(&1, @display_name_max))
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
    |> unique_constraint(:webauthn_user_handle)
  end

  @doc """
  Sets the handle of a user that has none. The value is lower-cased before validation.
  A taken handle is reported on `:handle` with `constraint: :unique`.
  """
  @spec handle_changeset(t(), map()) :: Ecto.Changeset.t()
  def handle_changeset(%__MODULE__{handle: nil} = user, attrs) do
    user
    |> cast(attrs, [:handle], empty_values: [])
    |> update_change(:handle, &String.downcase/1)
    |> validate_required([:handle])
    |> validate_format(:handle, @handle_format,
      message: "must be 2-30 characters: a-z, 0-9, _ or -, starting with a letter or digit"
    )
    |> validate_exclusion(:handle, @reserved_handles, message: "is reserved")
    |> unique_constraint(:handle)
    |> check_constraint(:handle, name: :handle_format, message: "has an invalid format")
  end

  @doc "Updates the display name (trimmed; blank clears it; at most #{@display_name_max} characters)."
  @spec profile_changeset(t(), map()) :: Ecto.Changeset.t()
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &String.trim/1)
    |> validate_length(:display_name, max: @display_name_max)
  end

  @doc "Sets the email from a provider-verified address (lower-cased; unique)."
  @spec email_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def email_changeset(user, email) do
    user
    |> change(email: String.downcase(email))
    |> unique_constraint(:email)
  end

  defp truncate(nil, _max), do: nil
  defp truncate(string, max), do: String.slice(string, 0, max)
end
