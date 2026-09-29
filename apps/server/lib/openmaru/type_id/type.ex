defmodule Openmaru.TypeID.Type do
  @moduledoc """
  `Ecto.ParameterizedType` for API-facing ids.

      field :goal_id, Openmaru.TypeID.Type, prefix: "goal"

  `cast/2` accepts only a TypeID with the configured prefix and yields its UUID, so
  changesets over API params reject bare UUIDs and ids of the wrong kind. Stored and
  loaded values are plain UUIDs (like `Ecto.UUID`).
  """

  use Ecto.ParameterizedType

  alias Openmaru.TypeID

  @impl Ecto.ParameterizedType
  def init(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    unless TypeID.known_prefix?(prefix) do
      raise ArgumentError, "unknown TypeID prefix: #{inspect(prefix)}"
    end

    %{prefix: prefix}
  end

  @impl Ecto.ParameterizedType
  def type(_params), do: :uuid

  @impl Ecto.ParameterizedType
  def cast(nil, _params), do: {:ok, nil}

  def cast(value, %{prefix: prefix}) when is_binary(value) do
    case TypeID.decode(value, prefix) do
      {:ok, uuid} -> {:ok, uuid}
      {:error, :invalid_id} -> :error
    end
  end

  def cast(_value, _params), do: :error

  @impl Ecto.ParameterizedType
  def load(nil, _loader, _params), do: {:ok, nil}
  def load(value, _loader, _params), do: Ecto.UUID.load(value)

  @impl Ecto.ParameterizedType
  def dump(nil, _dumper, _params), do: {:ok, nil}
  def dump(value, _dumper, _params), do: Ecto.UUID.dump(value)

  @impl Ecto.ParameterizedType
  def equal?(a, b, _params), do: a == b
end
