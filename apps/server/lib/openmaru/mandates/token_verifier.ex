defmodule Openmaru.Mandates.TokenVerifier do
  @moduledoc """
  Verifies mandate tokens (`om_mt_…`, SPEC-04 §4) for `OpenmaruWeb.Plugs.ApiAuth`.

  M01 implements the behaviour (`Openmaru.Mandates.Tokens`, full verification order in
  SPEC-04 §4). Until then the configured implementation is
  `Openmaru.Mandates.TokenVerifier.Unimplemented`, which refuses every token. Tests
  use the Mox mock `Openmaru.Mandates.TokenVerifierMock`.

  A refused token is `{:error, reason}`; the plug answers 401 `invalid_token` with the
  reason in `details.reason`.
  """

  alias Openmaru.Accounts.User

  @typedoc """
  Facts the server authorizer supplies (SPEC-04 §4). `ApiAuth` sets `:operation` and
  `:time`; routes that bind a goal, task or amount add the others.
  """
  @type request_facts :: %{
          required(:operation) => :api | :gateway | :mcp,
          required(:time) => DateTime.t(),
          optional(:request_goal) => Ecto.UUID.t(),
          optional(:task) => Ecto.UUID.t(),
          optional(:request_amount) => non_neg_integer()
        }

  @typedoc "A verified token's claims (token id, mandate, org, goal, principal, expiry; M01)."
  @type claims :: map()

  @typedoc """
  The actor a valid token stands for: an org's agent (the agent record, C03) or a person
  acting under a person mandate.
  """
  @type actor :: {:agent, struct(), claims()} | {:person_mandate, User.t(), claims()}

  @typedoc "Why a token was refused (SPEC-04 §4), or `:not_implemented` before M01."
  @type reason ::
          :malformed
          | :bad_signature
          | :revoked
          | :expired
          | :check_failed
          | :mandate_revoked
          | :not_implemented

  @doc "Verifies `token` against `facts`."
  @callback verify(token :: String.t(), facts :: request_facts()) ::
              {:ok, actor()} | {:error, reason()}

  @doc "Verifies `token` with the configured implementation (`config :openmaru, :token_verifier`)."
  @spec verify(String.t(), request_facts()) :: {:ok, actor()} | {:error, reason()}
  def verify(token, facts), do: impl().verify(token, facts)

  # Read at runtime: with a compile-time module, Dialyzer would type every caller
  # against the placeholder, which never succeeds.
  defp impl do
    Application.get_env(:openmaru, :token_verifier, Openmaru.Mandates.TokenVerifier.Unimplemented)
  end
end

defmodule Openmaru.Mandates.TokenVerifier.Unimplemented do
  @moduledoc "The verifier until M01: refuses every mandate token with `:not_implemented`."

  @behaviour Openmaru.Mandates.TokenVerifier

  @impl Openmaru.Mandates.TokenVerifier
  def verify(_token, _facts), do: {:error, :not_implemented}
end
