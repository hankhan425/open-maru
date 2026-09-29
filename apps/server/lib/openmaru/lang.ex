defmodule Openmaru.Lang do
  @moduledoc """
  Thin wrapper over the `maru_core` NIF (ARCHITECTURE §4); the only module that calls
  `Openmaru.Lang.Native`. Every NIF runs on a dirty CPU scheduler.

  A panic inside the NIF is returned as `{:error, :panic}` rather than raised.
  """

  alias Openmaru.Lang.Native

  @doc "The `maru_core` version string."
  @spec version() :: String.t()
  def version, do: Native.version()

  @doc """
  Parses `input` as JSON and re-serializes it with sorted keys and no whitespace
  (the binding harness shared with the WASM package and CLI).
  """
  @spec echo_json(binary()) ::
          {:ok, String.t()} | {:error, {:invalid_json, String.t()}} | {:error, :panic}
  def echo_json(input) when is_binary(input), do: guard_panic(fn -> Native.echo_json(input) end)

  if Application.compile_env(:openmaru, :nif_test_helpers, false) do
    @doc false
    @spec panic_test() :: {:error, :panic}
    def panic_test, do: guard_panic(&Native.panic_test/0)
  end

  defp guard_panic(fun) do
    fun.()
  rescue
    error in ErlangError ->
      case error do
        %ErlangError{original: :nif_panicked} -> {:error, :panic}
        _ -> reraise error, __STACKTRACE__
      end
  end
end
