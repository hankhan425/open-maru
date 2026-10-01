# `:bench` tests (G01-T22) run only with `mix test --only bench`.
ExUnit.start(exclude: [:bench])
Ecto.Adapters.SQL.Sandbox.mode(Openmaru.Repo, :manual)
