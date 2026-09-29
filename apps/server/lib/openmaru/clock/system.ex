defmodule Openmaru.Clock.System do
  @moduledoc "Wall-clock implementation of `Openmaru.Clock`."

  @behaviour Openmaru.Clock

  @impl Openmaru.Clock
  def now, do: DateTime.utc_now(:microsecond)
end
