defmodule Openmaru.Health do
  @moduledoc """
  Dependency checks reported by `GET /healthz`.

  Mox-able in tests via `Openmaru.HealthMock`.
  """

  @doc "Checks that the database answers a trivial query."
  @callback check_db() :: :ok | {:error, term()}
end
