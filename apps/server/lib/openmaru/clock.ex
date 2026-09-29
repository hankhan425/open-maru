defmodule Openmaru.Clock do
  @moduledoc """
  The source of "now" for domain code (CONVENTIONS §2, "Time").

  Never call `DateTime.utc_now/0` in domain code; call `now/0`. The implementation
  is `Openmaru.Clock.System` except in tests, where it is the Mox mock
  `Openmaru.ClockMock` (stubbed with the system clock by default).
  """

  @doc "Returns the current UTC time with microsecond precision."
  @callback now() :: DateTime.t()

  @impl_module Application.compile_env(:openmaru, :clock, Openmaru.Clock.System)

  @doc "Returns the current UTC time from the configured implementation."
  @spec now() :: DateTime.t()
  def now, do: @impl_module.now()
end
