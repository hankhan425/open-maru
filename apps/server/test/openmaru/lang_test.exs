defmodule Openmaru.LangTest do
  use ExUnit.Case, async: true

  alias Openmaru.Lang

  @root Path.expand("../../../..", __DIR__)
  @vectors_path Path.join(@root, "crates/maru_core/tests/vectors/echo.json")
  @cargo_toml Path.join(@root, "Cargo.toml")

  setup_all do
    {:ok, vectors: @vectors_path |> File.read!() |> Jason.decode!()}
  end

  defp rust_version do
    [_, version] =
      Regex.run(
        ~r/\[workspace\.package\][^\[]*?^version\s*=\s*"([^"]+)"/ms,
        File.read!(@cargo_toml)
      )

    version
  end

  test "T03-T03 version/0 equals the Rust version string" do
    assert Lang.version() == rust_version()
  end

  test "T03-T04 every echo.json vector through the NIF produces the exact expected output", %{
    vectors: vectors
  } do
    assert vectors != []

    for %{"input" => input, "output" => output} <- vectors do
      assert Lang.echo_json(input) == {:ok, output}, "input: #{inspect(input)}"
    end
  end

  test "T03-T04 invalid JSON is {:error, {:invalid_json, message}}" do
    for input <- ["", "{", "[1,]", ~s({"a":1} x), <<0xFF, 0xFE>>] do
      assert {:error, {:invalid_json, message}} = Lang.echo_json(input)
      assert is_binary(message) and message != ""
    end
  end

  test "T03-T05 50 concurrent processes calling echo_json/1 all get correct results", %{
    vectors: vectors
  } do
    expected = Enum.map(vectors, &{:ok, &1["output"]})

    results =
      1..50
      |> Task.async_stream(
        fn _ -> Enum.map(vectors, &Lang.echo_json(&1["input"])) end,
        max_concurrency: 50,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert length(results) == 50
    assert Enum.all?(results, &(&1 == {:ok, expected}))
  end

  test "T03-T06 panic_test/0 returns {:error, :panic} without crashing the VM" do
    assert Lang.panic_test() == {:error, :panic}

    # The NIF library and the VM are still usable afterwards.
    assert Lang.version() == rust_version()
    assert Lang.echo_json(~s({"b":1,"a":2})) == {:ok, ~s({"a":2,"b":1})}
  end
end
