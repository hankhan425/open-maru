defmodule Openmaru.Factory do
  @moduledoc """
  Plain-function test factories (no ExMachina).

  `build/2` returns an unsaved struct with sensible defaults merged with `attrs`;
  `insert!/2` persists it through `Openmaru.Repo`.
  """

  alias Openmaru.Repo

  @doc "Builds an unsaved struct for `name`, overriding defaults with `attrs`."
  @spec build(atom(), Enumerable.t()) :: struct()
  def build(name, attrs \\ %{})

  def build(:idempotency_key, attrs) do
    now = Openmaru.Clock.now()

    struct!(
      Openmaru.Idempotency.Key,
      Enum.into(attrs, %{
        key: "key-#{System.unique_integer([:positive])}",
        principal: "anonymous",
        request_hash: :crypto.hash(:sha256, "request") |> Base.encode16(case: :lower),
        status: 200,
        body: ~s({"ok":true}),
        expires_at: DateTime.add(now, 24 * 3600, :second)
      })
    )
  end

  @doc "Builds and inserts a struct for `name`."
  @spec insert!(atom(), Enumerable.t()) :: struct()
  def insert!(name, attrs \\ %{}), do: name |> build(attrs) |> Repo.insert!()
end
