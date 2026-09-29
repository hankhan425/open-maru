defmodule Openmaru.RateLimit do
  @moduledoc """
  Rate-limit counters (SPEC-09 §6), backed by Hammer's ETS fixed-window algorithm.
  Started in the application supervision tree; see `OpenmaruWeb.Plugs.RateLimit`.
  """

  use Hammer, backend: :ets
end
