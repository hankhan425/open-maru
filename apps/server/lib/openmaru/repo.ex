defmodule Openmaru.Repo do
  use Ecto.Repo,
    otp_app: :openmaru,
    adapter: Ecto.Adapters.Postgres
end
