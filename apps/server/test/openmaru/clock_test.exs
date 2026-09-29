defmodule Openmaru.ClockTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  setup do
    Openmaru.Mocks.stub_defaults()
  end

  test "T02-T07 now/0 returns a UTC DateTime with microsecond precision" do
    now = Openmaru.Clock.now()

    assert %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = now
    assert {_, 6} = now.microsecond
    assert abs(DateTime.diff(now, DateTime.utc_now(), :second)) <= 1
  end

  test "T02-T07 the system implementation returns UTC" do
    assert %DateTime{time_zone: "Etc/UTC"} = Openmaru.Clock.System.now()
  end

  test "T02-T07 a Mox override is visible in an async test, including spawned tasks" do
    fixed = ~U[2030-01-02 03:04:05.000000Z]
    stub(Openmaru.ClockMock, :now, fn -> fixed end)

    assert Openmaru.Clock.now() == fixed
    assert Task.async(fn -> Openmaru.Clock.now() end) |> Task.await() == fixed
  end
end
