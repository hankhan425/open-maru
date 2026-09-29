defmodule Openmaru.FixturesTest do
  use ExUnit.Case, async: true

  import Openmaru.Fixtures

  @docs_example Path.expand("../../../../docs/mvp/specs/examples/lumen.maru", __DIR__)

  test "T02-T14 fixture!(\"lumen.maru\") equals the docs example byte-for-byte" do
    assert fixture!("lumen.maru") == File.read!(@docs_example)
  end

  test "T02-T14 fixture!/1 raises for a missing fixture" do
    assert_raise File.Error, fn -> fixture!("missing.maru") end
  end
end
