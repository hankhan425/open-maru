defmodule Openmaru.Health.Postgres do
  @moduledoc "Checks the database by running `SELECT 1` through `Openmaru.Repo`."

  @behaviour Openmaru.Health

  alias Ecto.Adapters.SQL

  @timeout 2_000

  @impl Openmaru.Health
  def check_db do
    case SQL.query(Openmaru.Repo, "SELECT 1", [], timeout: @timeout) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  rescue
    error in DBConnection.ConnectionError -> {:error, error}
  end
end
