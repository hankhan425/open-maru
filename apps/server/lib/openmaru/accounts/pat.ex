defmodule Openmaru.Accounts.PAT do
  @moduledoc """
  Personal access tokens (SPEC-09 §1): how the CLI and scripts act as a person.

  A token is `om_pat_` followed by 32 random bytes in unpadded base64url. It is returned
  once, by `create/3`; the database keeps its SHA-256 and last four characters
  (`Openmaru.Accounts.PersonalAccessToken`). Tokens may expire (`ttl_days`) and can be
  revoked. `verify/1` records use in `last_used_at` at most once a minute, so a busy
  token does not write on every request.

  Creating and revoking are audited (`pat.created`, `pat.revoked`); the token itself
  never reaches the audit log.
  """

  import Ecto.Query

  alias Openmaru.Accounts.{PersonalAccessToken, User}
  alias Openmaru.{Audit, Clock, Error, Repo}

  @prefix "om_pat_"
  @touch_interval_seconds 60
  @default_limit 50

  @doc "The prefix every PAT starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Creates a token for `user`. `attrs` has `name` (required, at most 100 characters) and
  optional `ttl_days` (1–365); string or atom keys. `meta` (client IP and user agent)
  goes to the audit log.

  Returns the plaintext token — the only time it is available — and the stored record.
  """
  @spec create(User.t(), map(), Openmaru.Accounts.meta()) ::
          {:ok, String.t(), PersonalAccessToken.t()} | {:error, Ecto.Changeset.t()}
  def create(%User{id: user_id}, attrs, meta \\ %{}) do
    token = @prefix <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    changeset =
      %PersonalAccessToken{
        user_id: user_id,
        token_hash: hash(token),
        last4: String.slice(token, -4, 4)
      }
      |> PersonalAccessToken.create_changeset(attrs, Openmaru.Schema.timestamp())

    with {:ok, pat} <- Repo.insert(changeset) do
      audit(meta, "pat.created", user_id, pat, %{"name" => pat.name})
      {:ok, token, pat}
    end
  end

  @doc """
  Resolves a token to its user and record, recording the use (see the module doc).

  Errors: `invalid_token` with `details.reason` `unknown`, `revoked` or `expired`;
  `forbidden` (`user_suspended`) when the user is suspended.
  """
  @spec verify(term()) :: {:ok, User.t(), PersonalAccessToken.t()} | {:error, Error.t()}
  def verify(token) when is_binary(token) do
    query =
      from p in PersonalAccessToken,
        join: u in User,
        on: u.id == p.user_id,
        where: p.token_hash == ^hash(token),
        select: {p, u}

    now = Clock.now()

    case Repo.one(query) do
      nil -> {:error, invalid_token("unknown")}
      {%PersonalAccessToken{revoked_at: %DateTime{}}, _user} -> {:error, invalid_token("revoked")}
      {pat, user} -> check_live(pat, user, now)
    end
  end

  def verify(_token), do: {:error, invalid_token("unknown")}

  defp check_live(%PersonalAccessToken{expires_at: expires_at} = pat, user, now) do
    cond do
      expires_at && DateTime.compare(expires_at, now) != :gt ->
        {:error, invalid_token("expired")}

      User.suspended?(user) ->
        {:error, Error.new(:forbidden, "This account is suspended", %{reason: "user_suspended"})}

      true ->
        {:ok, user, touch(pat, now)}
    end
  end

  # Skipped without a query when the row read shows a use within the minute; the
  # condition in the UPDATE keeps concurrent requests to one write.
  defp touch(%PersonalAccessToken{last_used_at: %DateTime{} = last} = pat, now) do
    if DateTime.diff(now, last, :microsecond) < @touch_interval_seconds * 1_000_000,
      do: pat,
      else: write_last_used(pat, now)
  end

  defp touch(pat, now), do: write_last_used(pat, now)

  defp write_last_used(%PersonalAccessToken{id: id} = pat, now) do
    now = pad(now)
    cutoff = DateTime.add(now, -@touch_interval_seconds, :second)

    query =
      from p in PersonalAccessToken,
        where: p.id == ^id,
        where: is_nil(p.last_used_at) or p.last_used_at <= ^cutoff

    case Repo.update_all(query, set: [last_used_at: now, updated_at: now]) do
      {1, _} -> %{pat | last_used_at: now, updated_at: now}
      {0, _} -> pat
    end
  end

  @doc """
  Revokes `user`'s token `id`; it stops working immediately. Revoking a revoked token is
  a no-op. A token that is not the user's (or does not exist) is `not_found`.
  """
  @spec revoke(User.t(), Ecto.UUID.t(), Openmaru.Accounts.meta()) :: :ok | {:error, Error.t()}
  def revoke(%User{id: user_id}, id, meta \\ %{}) do
    now = Openmaru.Schema.timestamp()

    query =
      from p in PersonalAccessToken,
        where: p.id == ^id and p.user_id == ^user_id and is_nil(p.revoked_at),
        select: p

    case Repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, [pat]} ->
        audit(meta, "pat.revoked", user_id, pat, %{"name" => pat.name})
        :ok

      {0, _} ->
        if Repo.exists?(
             from p in PersonalAccessToken, where: p.id == ^id and p.user_id == ^user_id
           ),
           do: :ok,
           else: {:error, Error.new(:not_found, "Token not found")}
    end
  end

  @doc """
  `user`'s tokens that are not revoked, newest first (expired ones included, so the
  user sees them lapse). Options: `:limit` (default #{@default_limit}) and `:before`, the id
  of the last token on the previous page.
  """
  @spec list(User.t(), keyword()) :: [PersonalAccessToken.t()]
  def list(%User{id: user_id}, opts \\ []) do
    PersonalAccessToken
    |> where([p], p.user_id == ^user_id and is_nil(p.revoked_at))
    |> before(Keyword.get(opts, :before))
    |> order_by(desc: :id)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> Repo.all()
  end

  defp before(query, nil), do: query
  defp before(query, id), do: where(query, [p], p.id < ^id)

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp invalid_token(reason) do
    Error.new(:invalid_token, "Invalid personal access token", %{reason: reason})
  end

  defp audit(meta, action, user_id, pat, metadata) do
    {:ok, _entry} =
      Audit.record(%{
        action: action,
        actor: {:person, user_id},
        target: {"personal_access_token", pat.id},
        ip: meta[:ip],
        user_agent: meta[:user_agent],
        metadata: metadata
      })

    :ok
  end

  defp pad(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
