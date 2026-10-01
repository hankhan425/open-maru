defmodule Openmaru.Test.FakeAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator for tests (C01).

  It holds one ES256 (P-256) credential and answers the server's options with the JSON
  a browser would send back (`RegistrationResponseJSON` and
  `AuthenticationResponseJSON`, base64url fields):

      auth = FakeAuthenticator.new()
      {credential, auth} = FakeAuthenticator.attest(auth, options["public_key"])
      {assertion, auth} = FakeAuthenticator.assert(auth, options["public_key"])

  Registration uses the `none` attestation format. Every assertion increments the sign
  count unless `:sign_count` is given. Options that tamper with the output:

    * `:user_verified` — set the UV flag (default `true`);
    * `:user_present` — set the UP flag (default `true`);
    * `:sign_count` — the counter to report;
    * `:origin`, `:rp_id`, `:challenge` (raw bytes), `:type` — override client data or
      authenticator data;
    * `:user_handle` — the `userHandle` returned by an assertion (`nil` omits it).
  """

  @flag_user_present 0x01
  @flag_user_verified 0x04
  @flag_attested_credential_data 0x40

  defstruct [
    :credential_id,
    :private_key,
    :public_key,
    :user_handle,
    :origin,
    :rp_id,
    sign_count: 0
  ]

  @type t :: %__MODULE__{
          credential_id: binary(),
          private_key: binary(),
          public_key: binary(),
          user_handle: binary() | nil,
          origin: String.t(),
          rp_id: String.t() | nil,
          sign_count: non_neg_integer()
        }

  @doc """
  A new authenticator with a fresh key pair and a random 32-byte credential id.
  `:origin` defaults to the configured WebAuthn origin.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id:
        Keyword.get_lazy(opts, :credential_id, fn -> :crypto.strong_rand_bytes(32) end),
      private_key: private_key,
      public_key: public_key,
      origin: Keyword.get_lazy(opts, :origin, &configured_origin/0),
      rp_id: Keyword.get(opts, :rp_id)
    }
  end

  @doc """
  Answers `PublicKeyCredentialCreationOptions` (the server's `public_key` map) with a
  `none` attestation. Returns the credential JSON and the authenticator, which now
  remembers the user handle and the rp id from the options.
  """
  @spec attest(t(), map(), keyword()) :: {map(), t()}
  def attest(%__MODULE__{} = auth, public_key_options, opts \\ []) do
    rp_id = Keyword.get(opts, :rp_id, get_in(public_key_options, ["rp", "id"]))
    user_handle = public_key_options |> get_in(["user", "id"]) |> decode64()
    auth = %{auth | rp_id: rp_id, user_handle: user_handle}

    client_data = client_data(auth, "webauthn.create", public_key_options, opts)

    auth_data =
      authenticator_data(auth, opts, @flag_attested_credential_data, auth.sign_count) <>
        attested_credential_data(auth)

    attestation_object =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth_data)})

    credential = %{
      "id" => encode64(auth.credential_id),
      "rawId" => encode64(auth.credential_id),
      "type" => "public-key",
      "authenticatorAttachment" => "platform",
      "clientExtensionResults" => %{},
      "response" => %{
        "clientDataJSON" => encode64(client_data),
        "attestationObject" => encode64(attestation_object),
        "transports" => ["internal", "hybrid"]
      }
    }

    {credential, auth}
  end

  @doc """
  Answers `PublicKeyCredentialRequestOptions` (the server's `public_key` map) with a
  signed assertion. Returns the assertion JSON and the authenticator with its new sign
  count.
  """
  @spec assert(t(), map(), keyword()) :: {map(), t()}
  def assert(%__MODULE__{} = auth, public_key_options, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, auth.sign_count + 1)
    auth = %{auth | rp_id: auth.rp_id || public_key_options["rpId"]}

    client_data = client_data(auth, "webauthn.get", public_key_options, opts)
    auth_data = authenticator_data(auth, opts, 0, sign_count)

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [auth.private_key, :secp256r1]
      )

    user_handle = Keyword.get(opts, :user_handle, auth.user_handle)

    assertion = %{
      "id" => encode64(auth.credential_id),
      "rawId" => encode64(auth.credential_id),
      "type" => "public-key",
      "authenticatorAttachment" => "platform",
      "clientExtensionResults" => %{},
      "response" => %{
        "clientDataJSON" => encode64(client_data),
        "authenticatorData" => encode64(auth_data),
        "signature" => encode64(signature),
        "userHandle" => user_handle && encode64(user_handle)
      }
    }

    {assertion, %{auth | sign_count: sign_count}}
  end

  @doc "The credential's COSE public key (as stored by the server)."
  @spec cose_key(t()) :: map()
  def cose_key(%__MODULE__{public_key: <<4, x::binary-size(32), y::binary-size(32)>>}) do
    %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
  end

  @doc "Base64url without padding, as WebAuthn JSON uses."
  @spec encode64(binary()) :: String.t()
  def encode64(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Decodes base64url with or without padding."
  @spec decode64(String.t()) :: binary()
  def decode64(string), do: Base.url_decode64!(string, padding: false)

  defp client_data(auth, default_type, public_key_options, opts) do
    challenge =
      Keyword.get_lazy(opts, :challenge, fn -> decode64(public_key_options["challenge"]) end)

    Jason.encode!(%{
      "type" => Keyword.get(opts, :type, default_type),
      "challenge" => encode64(challenge),
      "origin" => Keyword.get(opts, :origin, auth.origin),
      "crossOrigin" => false
    })
  end

  defp authenticator_data(auth, opts, extra_flags, sign_count) do
    flags =
      extra_flags
      |> flag(Keyword.get(opts, :user_present, true), @flag_user_present)
      |> flag(Keyword.get(opts, :user_verified, true), @flag_user_verified)

    rp_id = Keyword.get(opts, :rp_id, auth.rp_id)
    :crypto.hash(:sha256, rp_id) <> <<flags::8, sign_count::unsigned-big-32>>
  end

  defp attested_credential_data(auth) do
    cose_key =
      auth
      |> cose_key()
      |> Map.new(fn
        {k, v} when is_binary(v) -> {k, bytes(v)}
        pair -> pair
      end)
      |> CBOR.encode()

    <<0::128, byte_size(auth.credential_id)::unsigned-big-16>> <> auth.credential_id <> cose_key
  end

  defp flag(flags, true, bit), do: Bitwise.bor(flags, bit)
  defp flag(flags, false, _bit), do: flags

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}

  defp configured_origin do
    :openmaru |> Application.fetch_env!(Openmaru.Accounts.WebAuthn) |> Keyword.fetch!(:origin)
  end
end
