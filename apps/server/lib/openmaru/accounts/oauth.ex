defmodule Openmaru.Accounts.OAuth do
  @moduledoc """
  GitHub and Google sign-in through `assent` (SPEC-09 §1).

  Provider credentials and endpoint overrides come from this module's config:

      config :openmaru, Openmaru.Accounts.OAuth,
        providers: [
          github: [client_id: "…", client_secret: "…"],
          google: [client_id: "…", client_secret: "…"]
        ]

  A provider without a `client_id` is disabled. Every flow carries a random `state`;
  Google (OpenID Connect) also carries a `nonce` checked against the ID token. The
  session params are stored server-side by `Openmaru.Accounts`.
  """

  @strategies %{github: Assent.Strategy.Github, google: Assent.Strategy.Google}
  @session_param_keys %{"state" => :state, "nonce" => :nonce, "code_verifier" => :code_verifier}

  @typedoc "A supported provider."
  @type provider :: :github | :google

  @typedoc "The normalized account the provider returned."
  @type account :: %{
          uid: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil
        }

  @doc "Resolves a provider name from a URL to an enabled provider."
  @spec fetch_provider(term()) :: {:ok, provider()} | :error
  def fetch_provider(name) when is_binary(name) do
    case Enum.find(Map.keys(@strategies), &(Atom.to_string(&1) == name)) do
      nil -> :error
      provider -> if enabled?(provider), do: {:ok, provider}, else: :error
    end
  end

  def fetch_provider(_name), do: :error

  @doc "The provider's authorization URL and the session params to keep until the callback."
  @spec authorize_url(provider(), String.t()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_url(provider, redirect_uri) do
    config = config(provider, redirect_uri)
    config = if provider == :google, do: Keyword.put(config, :nonce, random()), else: config

    @strategies[provider].authorize_url(config)
  end

  @doc "Exchanges the callback `params` for the provider's account."
  @spec callback(provider(), String.t(), map(), map()) :: {:ok, account()} | {:error, term()}
  def callback(provider, redirect_uri, session_params, params) do
    config = provider |> config(redirect_uri) |> Keyword.put(:session_params, session_params)

    case @strategies[provider].callback(config, params) do
      {:ok, %{user: %{"sub" => sub} = user}} when not is_nil(sub) ->
        {:ok,
         %{
           uid: to_string(sub),
           email: blank_to_nil(user["email"]),
           email_verified: user["email_verified"] == true,
           name: blank_to_nil(user["name"]) || blank_to_nil(user["preferred_username"])
         }}

      {:ok, _other} ->
        {:error, :missing_subject}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Session params with string keys (as stored) back to the atoms assent expects."
  @spec restore_session_params(map()) :: map()
  def restore_session_params(stored) do
    for {key, atom} <- @session_param_keys, Map.has_key?(stored, key), into: %{} do
      {atom, stored[key]}
    end
  end

  defp enabled?(provider) do
    case provider_config(provider)[:client_id] do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  defp config(provider, redirect_uri) do
    provider
    |> provider_config()
    |> Keyword.put(:redirect_uri, redirect_uri)
  end

  defp provider_config(provider) do
    :openmaru
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
  end

  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil
end
