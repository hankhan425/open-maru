defmodule Openmaru.TypeIDTest do
  use ExUnit.Case, async: true

  alias Openmaru.TypeID

  # CONVENTIONS §4.
  @prefixes ~w(usr org ver goal circ agent mand mtok dec task lease evid spend xfer acct don sess evt pat upl)

  test "T02-T05 the known prefixes are exactly those in CONVENTIONS §4" do
    assert Enum.sort(TypeID.prefixes()) == Enum.sort(@prefixes)
  end

  for prefix <- @prefixes do
    test "T02-T05 #{prefix} ids round-trip" do
      prefix = unquote(prefix)
      uuid = Openmaru.UUIDv7.generate()

      id = TypeID.encode(prefix, uuid)

      assert id =~ ~r/\A#{prefix}_[0-7][0-9a-hjkmnp-tv-z]{25}\z/
      assert TypeID.decode(id, prefix) == {:ok, uuid}
    end
  end

  test "T02-T05 round-trips the nil and max UUIDs" do
    for uuid <- ["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"] do
      assert {:ok, ^uuid} = uuid |> then(&TypeID.encode("org", &1)) |> TypeID.decode("org")
    end
  end

  test "T02-T05 wrong prefix is invalid_id" do
    id = TypeID.encode("org", Openmaru.UUIDv7.generate())

    assert TypeID.decode(id, "goal") == {:error, :invalid_id}
    assert TypeID.decode(id, "nope") == {:error, :invalid_id}
  end

  test "T02-T05 garbage is invalid_id" do
    valid = TypeID.encode("org", Openmaru.UUIDv7.generate())
    "org_" <> suffix = valid

    garbage = [
      "",
      "org",
      "org_",
      "org_123",
      "org" <> suffix,
      "org__" <> suffix,
      "ORG_" <> suffix,
      "org_" <> String.upcase(suffix),
      "org_" <> suffix <> "0",
      "org_8" <> binary_part(suffix, 1, 25),
      "org_u" <> binary_part(suffix, 1, 25),
      "org_" <> binary_part(suffix, 0, 25) <> "-",
      " " <> valid,
      Openmaru.UUIDv7.generate()
    ]

    for input <- garbage do
      assert TypeID.decode(input, "org") == {:error, :invalid_id}, "accepted #{inspect(input)}"
    end

    assert TypeID.decode(nil, "org") == {:error, :invalid_id}
    assert TypeID.decode(123, "org") == {:error, :invalid_id}
  end

  test "T02-T05 encode rejects unknown prefixes and non-UUIDs" do
    assert_raise ArgumentError, fn -> TypeID.encode("nope", Openmaru.UUIDv7.generate()) end
    assert_raise ArgumentError, fn -> TypeID.encode("org", "not-a-uuid") end
  end

  describe "Ecto type" do
    setup do
      {:ok, type: Ecto.ParameterizedType.init(TypeID.Type, prefix: "org")}
    end

    test "T02-T05 casts a TypeID with the right prefix to its UUID", %{type: type} do
      uuid = Openmaru.UUIDv7.generate()

      assert Ecto.Type.cast(type, TypeID.encode("org", uuid)) == {:ok, uuid}
      assert Ecto.Type.cast(type, TypeID.encode("goal", uuid)) == :error
      assert Ecto.Type.cast(type, uuid) == :error
      assert Ecto.Type.cast(type, "garbage") == :error
      assert Ecto.Type.cast(type, nil) == {:ok, nil}
    end

    test "T02-T05 dumps and loads UUIDs like Ecto.UUID", %{type: type} do
      uuid = Openmaru.UUIDv7.generate()
      {:ok, raw} = Ecto.UUID.dump(uuid)

      assert Ecto.Type.dump(type, uuid) == {:ok, raw}
      assert Ecto.Type.load(type, raw) == {:ok, uuid}
    end

    test "T02-T05 rejects an unknown prefix at definition time" do
      assert_raise ArgumentError, fn -> Ecto.ParameterizedType.init(TypeID.Type, prefix: "x") end
    end
  end
end
