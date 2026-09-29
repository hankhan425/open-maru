defmodule Openmaru.Schema do
  @moduledoc """
  `use Openmaru.Schema` in place of `use Ecto.Schema`.

  Sets UUIDv7 primary keys (`Openmaru.UUIDv7`), UUID foreign keys, and
  `utc_datetime_usec` timestamps taken from `Openmaru.Clock` (SPEC-02 §2).
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Openmaru.UUIDv7, autogenerate: true}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [
        type: :utc_datetime_usec,
        autogenerate: {Openmaru.Schema, :timestamp, []}
      ]
    end
  end

  @doc "Current `Openmaru.Clock` time, padded to microsecond precision for `utc_datetime_usec`."
  @spec timestamp() :: DateTime.t()
  def timestamp do
    %DateTime{microsecond: {us, _precision}} = now = Openmaru.Clock.now()
    %{now | microsecond: {us, 6}}
  end
end
