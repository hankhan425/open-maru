defmodule Openmaru.Accounts do
  @moduledoc """
  People and how they sign in (SPEC-02 §2, SPEC-09 §1): passkeys, GitHub/Google
  identities, handles and web sessions.

  * **Passkeys** — `begin_*` stores a random challenge server-side (5 minutes, single
    use) and returns WebAuthn options; `finish_*` consumes it and verifies the response
    (`Openmaru.Accounts.WebAuthn`). A sign-count that does not increase rejects the
    assertion and is audited.
  * **OAuth** — `begin_oauth/2` stores the state (and OIDC nonce); `oauth_callback/3`
    consumes it. Linking happens only for a signed-in user and a provider-verified
    email; a signed-out sign-in whose email matches an existing user is refused with
    `account_exists` (no silent linking).
  * **Handles** — picked once, never changed (`set_handle/2`).
  * **Sessions** — opaque 32-byte tokens, stored as SHA-256, 30-day sliding expiry.

  Sign-in successes and failures go to `Openmaru.Audit`. Functions that audit take a
  `meta` map with the client's `:ip` and `:user_agent`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Openmaru.Accounts.{Challenge, OAuth, OAuthIdentity, Passkey, User, UserSession, WebAuthn}
  alias Openmaru.{Audit, Clock, Error, Repo}

  @session_ttl_seconds 30 * 24 * 3600
  # A session's expiry moves forward at most this often (bounds writes per session).
  @session_refresh_seconds 3600
  @oauth_ttl_seconds 300
  @anonymous_user_name "openmaru user"

  @typedoc "Client details recorded in the audit log."
  @type meta :: %{
          optional(:ip) => :inet.ip_address() | String.t() | nil,
          optional(:user_agent) => String.t() | nil
        }

  @typedoc "Options for a WebAuthn ceremony: the persisted challenge id and the JSON options."
  @type ceremony :: %{challenge_id: Ecto.UUID.t(), public_key: map()}

  ## Users

  @doc "Fetches a user by id; raises if missing."
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  ## Passkeys

  @doc """
  Starts a passkey registration. With `nil` the finished registration creates a new
  user; with a user it adds a passkey to that user (who must finish it).
  """
  @spec begin_passkey_registration(User.t() | nil) :: {:ok, ceremony()}
  def begin_passkey_registration(user) do
    challenge = WebAuthn.new_challenge()

    {user_handle, name, exclude} =
      case user do
        nil ->
          {WebAuthn.new_user_handle(), @anonymous_user_name, []}

        %User{} = user ->
          ids = Repo.all(from p in Passkey, where: p.user_id == ^user.id, select: p.credential_id)
          {user.webauthn_user_handle || WebAuthn.new_user_handle(), user_name(user), ids}
      end

    {:ok, stored} =
      insert_challenge("passkey_registration", challenge,
        user_id: user && user.id,
        data: %{"user_handle" => WebAuthn.encode64(user_handle)}
      )

    {:ok,
     %{
       challenge_id: stored.id,
       public_key: WebAuthn.creation_options(challenge, user_handle, name, exclude)
     }}
  end

  @doc """
  Finishes a registration begun by the same `user` (or anonymously, with `nil`).
  `params` has `"challenge_id"` and `"credential"` (`RegistrationResponseJSON`).

  Returns the new user (anonymous registration, audited as a sign-in) or the existing
  one. Every failure is `invalid_request`.
  """
  @spec finish_passkey_registration(User.t() | nil, map(), meta()) ::
          {:ok, User.t()} | {:error, Error.t()}
  def finish_passkey_registration(user, params, meta \\ %{}) do
    with {:ok, registration} <- parse(&WebAuthn.parse_registration/1, params),
         {:ok, challenge} <-
           consume_challenge(params["challenge_id"], "passkey_registration", user && user.id),
         {:ok, attested} <- verify_registration(registration, challenge) do
      {:ok, user_handle} = WebAuthn.decode64(challenge.data["user_handle"])
      store_passkey(user, user_handle, attested, registration.transports, meta)
    end
  end

  @doc "Starts a passkey sign-in (discoverable credentials, no user named up front)."
  @spec begin_passkey_login() :: {:ok, ceremony()}
  def begin_passkey_login do
    challenge = WebAuthn.new_challenge()
    {:ok, stored} = insert_challenge("passkey_login", challenge)
    {:ok, %{challenge_id: stored.id, public_key: WebAuthn.request_options(challenge)}}
  end

  @doc """
  Finishes a passkey sign-in. `params` has `"challenge_id"` and `"credential"`
  (`AuthenticationResponseJSON`).

  Errors: `invalid_request` (malformed, or the challenge is unknown, used or expired);
  `unauthenticated` (unknown credential, bad signature or flags, user handle mismatch,
  sign-count regression); `forbidden` (suspended user). Successes and failures are
  audited; a regression also writes `passkey.sign_count_regression`.
  """
  @spec finish_passkey_login(map(), meta()) :: {:ok, User.t()} | {:error, Error.t()}
  def finish_passkey_login(params, meta \\ %{}) do
    with {:ok, assertion} <- parse(&WebAuthn.parse_assertion/1, params),
         {:ok, challenge} <- consume_challenge(params["challenge_id"], "passkey_login", nil),
         {:ok, passkey, user} <- fetch_passkey(assertion.credential_id, meta),
         :ok <- check_user_handle(assertion.user_handle, user, meta),
         {:ok, sign_count} <- verify_assertion(assertion, challenge, passkey, user, meta),
         :ok <- check_sign_count(passkey, sign_count, user, meta),
         :ok <- check_active(user, "passkey", meta),
         :ok <- record_passkey_use(passkey, sign_count, user, meta) do
      audit_sign_in(user, "passkey", meta)
      {:ok, user}
    end
  end

  defp parse(parser, %{"credential" => credential}) do
    case parser.(credential) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, invalid_request("Malformed credential", "malformed_credential")}
    end
  end

  defp parse(_parser, _params) do
    {:error, invalid_request("Malformed credential", "malformed_credential")}
  end

  defp verify_registration(registration, %Challenge{challenge: bytes}) do
    case WebAuthn.verify_registration(registration, bytes) do
      {:ok, attested} ->
        {:ok, attested}

      {:error, _reason} ->
        {:error, invalid_request("Passkey verification failed", "invalid_credential")}
    end
  end

  defp store_passkey(nil, user_handle, attested, transports, meta) do
    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%{webauthn_user_handle: user_handle}))
    |> Multi.run(:passkey, fn repo, %{user: user} ->
      insert_passkey(repo, user, attested, transports)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, passkey: passkey}} ->
        audit(meta, "passkey.registered", {:person, user.id}, {"passkey", passkey.id})
        audit_sign_in(user, "passkey", meta, %{"new_user" => true})
        {:ok, user}

      {:error, _step, _reason, _changes} ->
        {:error, invalid_request("Passkey could not be registered", "invalid_credential")}
    end
  end

  defp store_passkey(%User{} = user, user_handle, attested, transports, meta) do
    Multi.new()
    |> Multi.run(:user, fn repo, _changes ->
      case user.webauthn_user_handle do
        nil -> repo.update(Ecto.Changeset.change(user, webauthn_user_handle: user_handle))
        _set -> {:ok, user}
      end
    end)
    |> Multi.run(:passkey, fn repo, %{user: user} ->
      insert_passkey(repo, user, attested, transports)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, passkey: passkey}} ->
        audit(meta, "passkey.registered", {:person, user.id}, {"passkey", passkey.id})
        {:ok, user}

      {:error, _step, _reason, _changes} ->
        {:error, invalid_request("Passkey could not be registered", "invalid_credential")}
    end
  end

  defp insert_passkey(repo, user, attested, transports) do
    %Passkey{
      user_id: user.id,
      credential_id: attested.credential_id,
      cose_key: Passkey.encode_cose_key(attested.cose_key),
      sign_count: attested.sign_count,
      transports: transports
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:credential_id)
    |> repo.insert()
  end

  defp fetch_passkey(credential_id, meta) do
    query =
      from p in Passkey,
        join: u in User,
        on: u.id == p.user_id,
        where: p.credential_id == ^credential_id,
        select: {p, u}

    case Repo.one(query) do
      {passkey, user} ->
        {:ok, passkey, user}

      nil ->
        audit_sign_in_failure(nil, "passkey", "unknown_credential", meta)
        {:error, unauthenticated()}
    end
  end

  defp check_user_handle(nil, _user, _meta), do: :ok
  defp check_user_handle(handle, %User{webauthn_user_handle: handle}, _meta), do: :ok

  defp check_user_handle(_handle, user, meta) do
    audit_sign_in_failure(user, "passkey", "user_handle_mismatch", meta)
    {:error, unauthenticated()}
  end

  defp verify_assertion(assertion, %Challenge{challenge: bytes}, passkey, user, meta) do
    with {:ok, cose_key} <- Passkey.decode_cose_key(passkey.cose_key),
         {:ok, sign_count} <- WebAuthn.verify_assertion(assertion, bytes, cose_key) do
      {:ok, sign_count}
    else
      _error ->
        audit_sign_in_failure(user, "passkey", "invalid_assertion", meta)
        {:error, unauthenticated()}
    end
  end

  # WebAuthn §7.2 step 21: a counter that is used (either side non-zero) must increase.
  defp check_sign_count(%Passkey{sign_count: stored}, new, _user, _meta)
       when new > stored or (new == 0 and stored == 0),
       do: :ok

  defp check_sign_count(passkey, new, user, meta) do
    sign_count_regression(passkey, new, user, meta)
  end

  defp sign_count_regression(passkey, new, user, meta) do
    audit(meta, "passkey.sign_count_regression", {:person, user.id}, {"passkey", passkey.id}, %{
      "stored_sign_count" => passkey.sign_count,
      "sign_count" => new
    })

    audit_sign_in_failure(user, "passkey", "sign_count_regression", meta)
    {:error, unauthenticated()}
  end

  # Conditional update: a concurrent sign-in that already stored this counter loses.
  defp record_passkey_use(passkey, sign_count, user, meta) do
    query =
      from p in Passkey,
        where: p.id == ^passkey.id,
        where: p.sign_count < ^sign_count or (p.sign_count == 0 and ^sign_count == 0)

    case Repo.update_all(query,
           set: [sign_count: sign_count, last_used_at: Clock.now(), updated_at: Clock.now()]
         ) do
      {1, _} -> :ok
      {0, _} -> sign_count_regression(Repo.reload!(passkey), sign_count, user, meta)
    end
  end

  ## OAuth

  @doc """
  Starts an OAuth sign-in with `provider` (`"github"`/`"google"`). Returns the URL to
  redirect to and the id of the stored state, which the client must present at the
  callback (the web layer keeps it in a cookie). Unknown or disabled providers are
  `not_found`.
  """
  @spec begin_oauth(String.t(), String.t()) ::
          {:ok, %{url: String.t(), state_id: Ecto.UUID.t()}} | {:error, Error.t()}
  def begin_oauth(provider, redirect_uri) do
    with {:ok, provider} <- fetch_provider(provider),
         {:ok, %{url: url, session_params: session_params}} <-
           oauth_authorize_url(provider, redirect_uri) do
      {:ok, stored} =
        insert_challenge("oauth", nil,
          ttl: @oauth_ttl_seconds,
          data: %{"provider" => Atom.to_string(provider), "session_params" => session_params}
        )

      {:ok, %{url: url, state_id: stored.id}}
    end
  end

  @doc """
  Completes an OAuth flow. `params` are the callback query params. `opts`:
  `:state_id` (from `begin_oauth/2`), `:redirect_uri` (as passed there),
  `:current_user` (signed-in user or `nil`) and `:meta`.

  Outcomes (SPEC-09 §1):

    * a known identity signs its user in (`{:signed_in, user}`); signed in as someone
      else → `account_exists`;
    * a new identity while signed in is linked when the provider verified the email
      (`{:linked, user}`), else `forbidden` (`email_not_verified`);
    * a new identity while signed out creates a user (`{:registered, user}`) unless its
      email belongs to an existing user → `account_exists`.

  A suspended user is `forbidden`; state or provider failures are `invalid_request`.
  """
  @spec oauth_callback(String.t(), map(), keyword()) ::
          {:ok, {:signed_in | :registered | :linked, User.t()}} | {:error, Error.t()}
  def oauth_callback(provider, params, opts) do
    current_user = Keyword.get(opts, :current_user)
    meta = Keyword.get(opts, :meta, %{})

    with {:ok, provider} <- fetch_provider(provider),
         {:ok, challenge} <- consume_challenge(Keyword.get(opts, :state_id), "oauth", :any),
         :ok <- same_provider(challenge, provider),
         {:ok, account} <-
           oauth_account(provider, Keyword.fetch!(opts, :redirect_uri), challenge, params) do
      identity =
        Repo.get_by(OAuthIdentity, provider: Atom.to_string(provider), provider_uid: account.uid)

      resolve_identity(identity, current_user, provider, account, meta)
    end
  end

  defp fetch_provider(name) do
    case OAuth.fetch_provider(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, Error.new(:not_found, "Unknown sign-in provider")}
    end
  end

  defp oauth_authorize_url(provider, redirect_uri) do
    case OAuth.authorize_url(provider, redirect_uri) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, Error.new(:internal_error, "Sign-in provider unavailable")}
    end
  end

  defp same_provider(%Challenge{data: %{"provider" => stored}}, provider) do
    if stored == Atom.to_string(provider),
      do: :ok,
      else: {:error, invalid_request("Sign-in state does not match", "invalid_state")}
  end

  defp oauth_account(provider, redirect_uri, challenge, params) do
    session_params = OAuth.restore_session_params(challenge.data["session_params"] || %{})

    case OAuth.callback(provider, redirect_uri, session_params, params) do
      {:ok, account} ->
        {:ok, account}

      {:error, _reason} ->
        {:error, invalid_request("Sign-in with the provider failed", "provider_error")}
    end
  end

  # Known identity of the signed-in user: nothing to do.
  defp resolve_identity(
         %OAuthIdentity{user_id: id},
         %User{id: id} = user,
         _provider,
         _account,
         _meta
       ) do
    {:ok, {:linked, user}}
  end

  defp resolve_identity(%OAuthIdentity{}, %User{}, _provider, _account, _meta) do
    {:error, account_exists()}
  end

  defp resolve_identity(%OAuthIdentity{user_id: user_id}, nil, provider, _account, meta) do
    user = Repo.get!(User, user_id)
    method = Atom.to_string(provider)

    with :ok <- check_active(user, method, meta) do
      audit_sign_in(user, method, meta)
      {:ok, {:signed_in, user}}
    end
  end

  defp resolve_identity(nil, %User{} = user, provider, %{email_verified: true} = account, meta) do
    Multi.new()
    |> Multi.insert(:identity, identity_changeset(user, provider, account))
    |> Multi.run(:user, fn repo, _changes -> maybe_adopt_email(repo, user, account.email) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{identity: identity, user: user}} ->
        audit(meta, "auth.oauth_linked", {:person, user.id}, {"oauth_identity", identity.id}, %{
          "provider" => Atom.to_string(provider)
        })

        {:ok, {:linked, user}}

      {:error, _step, _reason, _changes} ->
        {:error, account_exists()}
    end
  end

  defp resolve_identity(nil, %User{}, _provider, _account, _meta) do
    {:error,
     Error.new(:forbidden, "The provider has not verified this email", %{
       reason: "email_not_verified"
     })}
  end

  defp resolve_identity(nil, nil, provider, account, meta) do
    method = Atom.to_string(provider)

    if account.email && email_taken?(account.email) do
      audit_sign_in_failure(nil, method, "account_exists", meta)
      {:error, account_exists()}
    else
      attrs = %{
        email: if(account.email_verified, do: account.email),
        display_name: account.name
      }

      Multi.new()
      |> Multi.insert(:user, User.registration_changeset(attrs))
      |> Multi.insert(:identity, &identity_changeset(&1.user, provider, account))
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} ->
          audit_sign_in(user, method, meta, %{"new_user" => true})
          {:ok, {:registered, user}}

        {:error, _step, _reason, _changes} ->
          {:error, account_exists()}
      end
    end
  end

  defp identity_changeset(user, provider, account) do
    %OAuthIdentity{
      user_id: user.id,
      provider: Atom.to_string(provider),
      provider_uid: account.uid
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:provider, :provider_uid])
  end

  # A verified provider email fills in a missing email unless another user has it.
  defp maybe_adopt_email(repo, %User{email: nil} = user, email) when is_binary(email) do
    if email_taken?(email), do: {:ok, user}, else: repo.update(User.email_changeset(user, email))
  end

  defp maybe_adopt_email(_repo, user, _email), do: {:ok, user}

  defp email_taken?(email) do
    Repo.exists?(from u in User, where: u.email == ^String.downcase(email))
  end

  ## Handles and profile

  @doc """
  Sets `user`'s handle. The value is lower-cased, must match
  `^[a-z0-9][a-z0-9_-]{1,29}$` and not be reserved (`validation_failed` via the
  changeset), and must be free ignoring case (`handle_taken`). Once set a handle never
  changes: a different value is `invalid_request` with `details.reason` `handle_immutable`;
  the same value is a no-op.
  """
  @spec set_handle(User.t(), term()) :: {:ok, User.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def set_handle(%User{} = user, handle) do
    Repo.transaction(fn ->
      case apply_handle(lock_user(user), handle) do
        {:ok, user} -> user
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Applies a `PATCH /me` body: `"handle"` (see `set_handle/2`) and `"display_name"`.
  Other keys are ignored. Both changes happen in one transaction.
  """
  @spec update_profile(User.t(), map()) ::
          {:ok, User.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def update_profile(%User{} = user, params) when is_map(params) do
    Repo.transaction(fn ->
      locked = lock_user(user)

      with {:ok, user} <- maybe_apply_handle(locked, params),
           {:ok, user} <- maybe_update_display_name(user, params) do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_user(%User{id: id}),
    do: Repo.one!(from u in User, where: u.id == ^id, lock: "FOR UPDATE")

  defp maybe_apply_handle(user, %{"handle" => handle}), do: apply_handle(user, handle)
  defp maybe_apply_handle(user, _params), do: {:ok, user}

  defp maybe_update_display_name(user, %{"display_name" => _} = params) do
    user |> User.profile_changeset(Map.take(params, ["display_name"])) |> Repo.update()
  end

  defp maybe_update_display_name(user, _params), do: {:ok, user}

  defp apply_handle(%User{handle: nil} = user, handle) do
    case user |> User.handle_changeset(%{handle: handle}) |> Repo.update() do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        if Enum.any?(changeset.errors, &match?({:handle, {_, [{:constraint, :unique} | _]}}, &1)),
          do: {:error, Error.new(:handle_taken, "Handle is taken")},
          else: {:error, changeset}
    end
  end

  defp apply_handle(%User{handle: current} = user, handle) when is_binary(handle) do
    if String.downcase(handle) == current, do: {:ok, user}, else: handle_immutable()
  end

  defp apply_handle(_user, _handle), do: handle_immutable()

  defp handle_immutable do
    {:error,
     Error.new(:invalid_request, "Handles cannot be changed", %{reason: "handle_immutable"})}
  end

  ## Sessions

  @doc """
  Creates a web session for `user`. Returns the token for the cookie (32 random bytes,
  base64url) — shown only here; the database keeps its SHA-256.
  """
  @spec create_session(User.t()) :: {:ok, String.t(), UserSession.t()}
  def create_session(%User{id: user_id}) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    session =
      Repo.insert!(%UserSession{
        user_id: user_id,
        token_hash: hash_token(token),
        expires_at: DateTime.add(Openmaru.Schema.timestamp(), @session_ttl_seconds, :second)
      })

    {:ok, token, session}
  end

  @doc """
  Resolves a session token to its user, sliding the expiry to 30 days from now (at
  most once an hour; `session.extended` tells whether this call moved it).

  Errors: `unauthenticated` (unknown, revoked or expired) or `forbidden`
  (`details.reason` `user_suspended`).
  """
  @spec get_session_user(String.t()) :: {:ok, User.t(), UserSession.t()} | {:error, Error.t()}
  def get_session_user(token) when is_binary(token) do
    now = Clock.now()

    query =
      from s in UserSession,
        join: u in User,
        on: u.id == s.user_id,
        where:
          s.token_hash == ^hash_token(token) and is_nil(s.revoked_at) and s.expires_at > ^now,
        select: {s, u}

    case Repo.one(query) do
      nil ->
        {:error, Error.new(:unauthenticated, "Not signed in")}

      {session, user} ->
        if User.suspended?(user),
          do: {:error, suspended()},
          else: {:ok, user, maybe_extend(session, now)}
    end
  end

  def get_session_user(_token), do: {:error, Error.new(:unauthenticated, "Not signed in")}

  defp maybe_extend(%UserSession{} = session, now) do
    if DateTime.diff(session.expires_at, now) > @session_ttl_seconds - @session_refresh_seconds do
      session
    else
      expires_at = DateTime.add(pad(now), @session_ttl_seconds, :second)

      Repo.update_all(from(s in UserSession, where: s.id == ^session.id),
        set: [expires_at: expires_at, updated_at: pad(now)]
      )

      %{session | expires_at: expires_at, extended: true}
    end
  end

  @doc "Revokes a session; its token stops working immediately."
  @spec revoke_session(UserSession.t()) :: :ok
  def revoke_session(%UserSession{id: id}) do
    now = Openmaru.Schema.timestamp()

    Repo.update_all(from(s in UserSession, where: s.id == ^id and is_nil(s.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    :ok
  end

  @doc "Seconds a session lasts after its last activity."
  @spec session_ttl_seconds() :: pos_integer()
  def session_ttl_seconds, do: @session_ttl_seconds

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  ## Maintenance

  @doc """
  Deletes challenges past their expiry and sessions that expired or were revoked more
  than a day ago. Returns the number of rows deleted.
  """
  @spec prune() :: non_neg_integer()
  def prune do
    now = Clock.now()
    day_ago = DateTime.add(now, -24 * 3600, :second)

    {challenges, _} = Repo.delete_all(from c in Challenge, where: c.expires_at <= ^now)

    {sessions, _} =
      Repo.delete_all(
        from s in UserSession,
          where: s.expires_at <= ^now or (not is_nil(s.revoked_at) and s.revoked_at <= ^day_ago)
      )

    challenges + sessions
  end

  ## Challenges

  defp insert_challenge(kind, bytes, opts \\ []) do
    now = Openmaru.Schema.timestamp()
    ttl = Keyword.get(opts, :ttl, WebAuthn.challenge_ttl_seconds())

    Repo.insert(%Challenge{
      kind: kind,
      challenge: bytes,
      user_id: Keyword.get(opts, :user_id),
      data: Keyword.get(opts, :data, %{}),
      expires_at: DateTime.add(now, ttl, :second)
    })
  end

  # Atomically marks an unexpired, unused challenge of `kind` as used. `user_id` must
  # match the one that began it (`nil` for anonymous); `:any` skips the check.
  defp consume_challenge(id, kind, user_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id || ""),
         now = Openmaru.Schema.timestamp(),
         query =
           from(c in Challenge,
             where: c.id == ^uuid and c.kind == ^kind,
             where: is_nil(c.consumed_at) and c.expires_at > ^now,
             select: c
           ),
         {1, [challenge]} <- Repo.update_all(scope_user(query, user_id), set: [consumed_at: now]) do
      {:ok, challenge}
    else
      _ -> {:error, invalid_request("Unknown, used or expired challenge", "invalid_challenge")}
    end
  end

  defp scope_user(query, :any), do: query
  defp scope_user(query, nil), do: where(query, [c], is_nil(c.user_id))
  defp scope_user(query, user_id), do: where(query, [c], c.user_id == ^user_id)

  ## Helpers

  defp check_active(%User{} = user, method, meta) do
    if User.suspended?(user) do
      audit_sign_in_failure(user, method, "user_suspended", meta)
      {:error, suspended()}
    else
      :ok
    end
  end

  defp user_name(%User{handle: handle}) when is_binary(handle), do: handle
  defp user_name(%User{display_name: name}) when is_binary(name), do: name
  defp user_name(_user), do: @anonymous_user_name

  defp audit_sign_in(user, method, meta, extra \\ %{}) do
    audit(
      meta,
      "auth.sign_in_succeeded",
      {:person, user.id},
      nil,
      Map.put(extra, "method", method)
    )
  end

  defp audit_sign_in_failure(user, method, reason, meta) do
    actor = if user, do: {:person, user.id}
    audit(meta, "auth.sign_in_failed", actor, nil, %{"method" => method, "reason" => reason})
  end

  defp audit(meta, action, actor, target, metadata \\ %{}) do
    {:ok, _entry} =
      Audit.record(%{
        action: action,
        actor: actor,
        target: target,
        ip: meta[:ip],
        user_agent: meta[:user_agent],
        metadata: metadata
      })

    :ok
  end

  defp pad(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp invalid_request(message, reason),
    do: Error.new(:invalid_request, message, %{reason: reason})

  defp unauthenticated, do: Error.new(:unauthenticated, "Sign-in failed")

  defp account_exists,
    do: Error.new(:account_exists, "An account with this identity or email already exists")

  defp suspended do
    Error.new(:forbidden, "This account is suspended", %{reason: "user_suspended"})
  end
end
