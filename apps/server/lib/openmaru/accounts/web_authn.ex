defmodule Openmaru.Accounts.WebAuthn do
  @moduledoc """
  WebAuthn ceremonies on top of `wax_` (SPEC-09 §1).

  Options are built in the W3C JSON shapes (`PublicKeyCredentialCreationOptionsJSON`,
  `PublicKeyCredentialRequestOptionsJSON`), so browsers can pass them to
  `PublicKeyCredential.parseCreationOptionsFromJSON/…RequestOptionsFromJSON`. Responses
  are accepted in the matching `RegistrationResponseJSON`/`AuthenticationResponseJSON`
  shapes (base64url fields).

  Policy: user verification required, discoverable credentials (resident keys)
  required, `none` attestation. The relying party comes from this module's config
  (`:rp_id`, `:rp_name`, `:origin`). Challenge storage and expiry are the caller's job
  (`Openmaru.Accounts`); wax's own timeout is set to the same 5 minutes.
  """

  @challenge_ttl_seconds 300
  # ES256, EdDSA, RS256.
  @algorithms [-7, -8, -257]
  @transports ~w(usb nfc ble smart-card hybrid internal)

  @typedoc "A decoded `RegistrationResponseJSON`."
  @type registration :: %{
          client_data_json: binary(),
          attestation_object: binary(),
          transports: [String.t()]
        }

  @typedoc "A decoded `AuthenticationResponseJSON`."
  @type assertion :: %{
          credential_id: binary(),
          client_data_json: binary(),
          authenticator_data: binary(),
          signature: binary(),
          user_handle: binary() | nil
        }

  @typedoc "A verified new credential."
  @type attested :: %{credential_id: binary(), cose_key: map(), sign_count: non_neg_integer()}

  @doc "Seconds a challenge stays valid."
  @spec challenge_ttl_seconds() :: pos_integer()
  def challenge_ttl_seconds, do: @challenge_ttl_seconds

  @doc "A fresh 32-byte challenge."
  @spec new_challenge() :: binary()
  def new_challenge, do: :crypto.strong_rand_bytes(32)

  @doc "A fresh 32-byte WebAuthn user handle (`user.id`)."
  @spec new_user_handle() :: binary()
  def new_user_handle, do: :crypto.strong_rand_bytes(32)

  @doc """
  `PublicKeyCredentialCreationOptionsJSON` for `challenge` and `user_handle`.
  `exclude` lists credential ids the user already registered.
  """
  @spec creation_options(binary(), binary(), String.t(), [binary()]) :: map()
  def creation_options(challenge, user_handle, user_name, exclude) do
    %{
      "challenge" => encode64(challenge),
      "rp" => %{"id" => rp_id(), "name" => rp_name()},
      "user" => %{"id" => encode64(user_handle), "name" => user_name, "displayName" => user_name},
      "pubKeyCredParams" => Enum.map(@algorithms, &%{"type" => "public-key", "alg" => &1}),
      "timeout" => @challenge_ttl_seconds * 1000,
      "attestation" => "none",
      "authenticatorSelection" => %{
        "residentKey" => "required",
        "requireResidentKey" => true,
        "userVerification" => "required"
      },
      "excludeCredentials" => Enum.map(exclude, &%{"type" => "public-key", "id" => encode64(&1)})
    }
  end

  @doc "`PublicKeyCredentialRequestOptionsJSON` for a discoverable-credential sign-in."
  @spec request_options(binary()) :: map()
  def request_options(challenge) do
    %{
      "challenge" => encode64(challenge),
      "rpId" => rp_id(),
      "timeout" => @challenge_ttl_seconds * 1000,
      "userVerification" => "required",
      "allowCredentials" => []
    }
  end

  @doc "Decodes a `RegistrationResponseJSON`; `:error` if a field is missing or malformed."
  @spec parse_registration(term()) :: {:ok, registration()} | :error
  def parse_registration(%{"response" => %{} = response}) do
    with {:ok, client_data_json} <- decode64(response["clientDataJSON"]),
         {:ok, attestation_object} <- decode64(response["attestationObject"]) do
      {:ok,
       %{
         client_data_json: client_data_json,
         attestation_object: attestation_object,
         transports: transports(response["transports"])
       }}
    end
  end

  def parse_registration(_credential), do: :error

  @doc "Decodes an `AuthenticationResponseJSON`; `:error` if a field is missing or malformed."
  @spec parse_assertion(term()) :: {:ok, assertion()} | :error
  def parse_assertion(%{"rawId" => raw_id, "response" => %{} = response}) do
    with {:ok, credential_id} <- decode64(raw_id),
         {:ok, client_data_json} <- decode64(response["clientDataJSON"]),
         {:ok, authenticator_data} <- decode64(response["authenticatorData"]),
         {:ok, signature} <- decode64(response["signature"]),
         {:ok, user_handle} <- optional64(response["userHandle"]) do
      {:ok,
       %{
         credential_id: credential_id,
         client_data_json: client_data_json,
         authenticator_data: authenticator_data,
         signature: signature,
         user_handle: user_handle
       }}
    end
  end

  def parse_assertion(_credential), do: :error

  @doc """
  Verifies a registration against the stored `challenge` bytes: client data type,
  challenge and origin, rp id hash, user presence and verification, attestation.
  """
  @spec verify_registration(registration(), binary()) :: {:ok, attested()} | {:error, term()}
  def verify_registration(%{} = registration, challenge) do
    wax_challenge =
      Wax.new_registration_challenge(
        wax_opts(challenge) ++ [attestation: "none", verify_trust_root: false]
      )

    safely(fn ->
      with {:ok, {auth_data, _attestation}} <-
             Wax.register(
               registration.attestation_object,
               registration.client_data_json,
               wax_challenge
             ) do
        %{credential_id: credential_id, credential_public_key: cose_key} =
          auth_data.attested_credential_data

        {:ok,
         %{credential_id: credential_id, cose_key: cose_key, sign_count: auth_data.sign_count}}
      end
    end)
  end

  @doc """
  Verifies an assertion for the credential's `cose_key` against the stored `challenge`
  bytes. Returns the authenticator's sign count; checking it is the caller's job.
  """
  @spec verify_assertion(assertion(), binary(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def verify_assertion(%{} = assertion, challenge, cose_key) do
    wax_challenge = Wax.new_authentication_challenge(wax_opts(challenge))
    credential_id = assertion.credential_id

    safely(fn ->
      with {:ok, auth_data} <-
             Wax.authenticate(
               credential_id,
               assertion.authenticator_data,
               assertion.signature,
               assertion.client_data_json,
               wax_challenge,
               [{credential_id, cose_key}]
             ) do
        {:ok, auth_data.sign_count}
      end
    end)
  end

  @doc "Base64url without padding."
  @spec encode64(binary()) :: String.t()
  def encode64(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Decodes base64url, with or without padding."
  @spec decode64(term()) :: {:ok, binary()} | :error
  def decode64(string) when is_binary(string) and string != "" do
    Base.url_decode64(String.trim_trailing(string, "="), padding: false)
  end

  def decode64(_value), do: :error

  defp optional64(nil), do: {:ok, nil}
  defp optional64(string), do: decode64(string)

  defp transports(list) when is_list(list), do: Enum.filter(list, &(&1 in @transports))
  defp transports(_value), do: []

  defp wax_opts(challenge) do
    [
      bytes: challenge,
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "required",
      timeout: @challenge_ttl_seconds
    ]
  end

  # wax parses untrusted client data and CBOR with raising pattern matches.
  defp safely(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  end

  defp rp_id, do: Keyword.fetch!(config(), :rp_id)
  defp rp_name, do: Keyword.fetch!(config(), :rp_name)
  defp origin, do: Keyword.fetch!(config(), :origin)
  defp config, do: Application.fetch_env!(:openmaru, __MODULE__)
end
