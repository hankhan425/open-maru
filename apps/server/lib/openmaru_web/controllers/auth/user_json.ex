defmodule OpenmaruWeb.Auth.UserJSON do
  @moduledoc """
  User JSON. Everyone sees `id`, `handle`, `display_name` and `created_at`; the user
  themself also sees `email` and `platform_role` (SPEC-09 §4: emails are private).
  """

  alias Openmaru.Accounts.User
  alias Openmaru.TypeID

  @doc "`user` as seen by `viewer` (`nil` for anonymous)."
  @spec user(User.t(), User.t() | nil) :: map()
  def user(%User{} = user, viewer) do
    public = %{
      id: TypeID.encode("usr", user.id),
      handle: user.handle,
      display_name: user.display_name,
      created_at: user.inserted_at
    }

    case viewer do
      %User{id: id} when id == user.id ->
        Map.merge(public, %{email: user.email, platform_role: user.platform_role})

      _other ->
        public
    end
  end
end
