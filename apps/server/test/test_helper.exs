Mox.defmock(Openmaru.ClockMock, for: Openmaru.Clock)
Mox.defmock(Openmaru.HealthMock, for: Openmaru.Health)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Openmaru.Repo, :manual)
