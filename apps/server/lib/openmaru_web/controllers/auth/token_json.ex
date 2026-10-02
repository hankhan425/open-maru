defmodule OpenmaruWeb.Auth.TokenJSON do
  @moduledoc """
  Personal access token JSON. Lists show the name, last four characters and dates; the
  token itself appears only in the response that creates it (`new_pat/2`).
  """

  alias Openmaru.Accounts.PersonalAccessToken
  alias Openmaru.TypeID

  @doc "A stored token, without its value."
  @spec pat(PersonalAccessToken.t()) :: map()
  def pat(%PersonalAccessToken{} = pat) do
    %{
      id: TypeID.encode("pat", pat.id),
      name: pat.name,
      last4: pat.last4,
      created_at: pat.inserted_at,
      last_used_at: pat.last_used_at,
      expires_at: pat.expires_at
    }
  end

  @doc "A token just created, with its value (shown once)."
  @spec new_pat(PersonalAccessToken.t(), String.t()) :: map()
  def new_pat(%PersonalAccessToken{} = record, token) when is_binary(token) do
    record |> pat() |> Map.put(:token, token)
  end
end
