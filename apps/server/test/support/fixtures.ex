defmodule Openmaru.Fixtures do
  @moduledoc """
  Loads files from `test/support/fixtures/`.

  The canonical spec `lumen.maru` is a byte-for-byte copy of
  `docs/mvp/specs/examples/lumen.maru` (CONVENTIONS §2, "Fixtures").
  """

  @fixtures_dir Path.expand("fixtures", __DIR__)

  @doc "Returns the contents of `test/support/fixtures/<name>`; raises if it is missing."
  @spec fixture!(String.t()) :: binary()
  def fixture!(name), do: File.read!(Path.join(@fixtures_dir, name))
end
