defmodule Openmaru.UUIDv7Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Openmaru.UUIDv7

  property "T02-T06 ids generated later sort after earlier ones" do
    check all(n <- integer(2..500), max_runs: 200) do
      ids = for _ <- 1..n, do: UUIDv7.generate()

      assert ids == Enum.sort(ids)
      assert ids |> Enum.uniq() |> length() == n

      raw = Enum.map(ids, &Ecto.UUID.dump!/1)
      assert raw == Enum.sort(raw)
    end
  end

  test "T02-T06 stays monotonic past the per-millisecond counter (burst of 20k)" do
    ids = for _ <- 1..20_000, do: UUIDv7.generate()

    assert ids == Enum.sort(ids)
    assert ids |> Enum.uniq() |> length() == 20_000
  end

  test "T02-T06 ids carry version 7, the RFC 9562 variant, and the current time" do
    before = System.system_time(:millisecond)
    id = UUIDv7.generate()
    later = System.system_time(:millisecond)

    <<ms::48, version::4, _::12, variant::2, _::62>> = Ecto.UUID.dump!(id)

    assert version == 7
    assert variant == 0b10
    # The counter may borrow up to a few ms under bursts; allow a small skew.
    assert ms >= before and ms <= later + 50
  end

  test "T02-T06 autogenerate/0 produces a v7 id (Ecto.Type)" do
    id = UUIDv7.autogenerate()
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert <<_::48, 7::4, _::bitstring>> = Ecto.UUID.dump!(id)
  end
end
