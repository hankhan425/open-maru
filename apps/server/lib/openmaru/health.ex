defmodule Openmaru.Health do
  @moduledoc """
  Dependency checks reported by `GET /healthz`.

  The implementation is `Openmaru.Health.Postgres`; tests use the Mox mock
  `Openmaru.HealthMock`.
  """

  @doc "Checks that the database answers a trivial query."
  @callback check_db() :: :ok | {:error, term()}

  @impl_module Application.compile_env(:openmaru, :health, Openmaru.Health.Postgres)

  @doc "Runs the configured database check."
  @spec check_db() :: :ok | {:error, term()}
  def check_db, do: @impl_module.check_db()
end
