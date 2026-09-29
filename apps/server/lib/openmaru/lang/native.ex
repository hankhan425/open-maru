defmodule Openmaru.Lang.Native do
  @moduledoc false
  # Rustler bindings for crates/maru_nif. Only `Openmaru.Lang` calls this module.

  @test_helpers Application.compile_env(:openmaru, :nif_test_helpers, false)

  use Rustler,
    otp_app: :openmaru,
    crate: "maru_nif",
    path: "../../crates/maru_nif",
    features: if(@test_helpers, do: ["test-helpers"], else: [])

  def version, do: :erlang.nif_error(:nif_not_loaded)
  def echo_json(_input), do: :erlang.nif_error(:nif_not_loaded)

  if @test_helpers do
    def panic_test, do: :erlang.nif_error(:nif_not_loaded)
  end
end
