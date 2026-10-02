# Defined at compile time so modules configured to call them compile without warnings.
Mox.defmock(Openmaru.ClockMock, for: Openmaru.Clock)
Mox.defmock(Openmaru.HealthMock, for: Openmaru.Health)
Mox.defmock(Openmaru.Mandates.TokenVerifierMock, for: Openmaru.Mandates.TokenVerifier)

defmodule Openmaru.Mocks do
  @moduledoc """
  Default stubs for the Mox mocks defined above.

  Every case template calls `stub_defaults/0`, so tests see real behaviour
  unless they override a mock with `Mox.stub/3` or `Mox.expect/4`.
  """

  @doc "Stubs every mock with its production implementation for the calling process."
  @spec stub_defaults() :: :ok
  def stub_defaults do
    Mox.stub_with(Openmaru.ClockMock, Openmaru.Clock.System)
    Mox.stub_with(Openmaru.HealthMock, Openmaru.Health.Postgres)

    Mox.stub_with(
      Openmaru.Mandates.TokenVerifierMock,
      Openmaru.Mandates.TokenVerifier.Unimplemented
    )

    :ok
  end
end
