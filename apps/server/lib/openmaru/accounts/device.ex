defmodule Openmaru.Accounts.Device do
  @moduledoc """
  Device login for the CLI (SPEC-09 §1), after RFC 8628.

  1. The CLI calls `start/1` and shows the user code (`XXXX-XXXX`, eight characters
     from `BCDFGHJKLMNPQRSTVWXZ23456789`) and the verification URI.
  2. A signed-in person enters the code on the web and approves or denies it
     (`approve/3`, `deny/3`).
  3. The CLI polls `poll/2` with the device code, at most every 5 seconds, until the
     code is approved (it receives a new PAT named `CLI (<user agent>)`), denied, or
     10 minutes old.

  Poll errors use RFC 8628 codes in our envelope (400): `authorization_pending`,
  `slow_down` (polled less than 5 s after the previous poll; the interval restarts),
  `expired_token`, `access_denied`, and `invalid_grant` for an unknown or already used
  device code. A code issues one token.

  The device code (32 random bytes) is stored as SHA-256; the user code is stored
  without its hyphen. Approvals and denials are audited.
  """

  import Ecto.Query

  alias Openmaru.Accounts.{DeviceCode, PAT, PersonalAccessToken, User}
  alias Openmaru.{Audit, Clock, Error, Repo}

  @ttl_seconds 600
  @interval_seconds 5
  @alphabet ~c"BCDFGHJKLMNPQRSTVWXZ23456789"
  @alphabet_size length(@alphabet)
  # Largest multiple of the alphabet size below 256: bytes from here up are redrawn so
  # every symbol is equally likely.
  @byte_limit div(256, @alphabet_size) * @alphabet_size
  @user_code_length 8
  @user_code_format ~r/\A[BCDFGHJKLMNPQRSTVWXZ2-9]{8}\z/
  @insert_attempts 5
  @user_agent_max 80

  @typedoc "A started device login, as returned to the CLI."
  @type authorization :: %{
          device_code: String.t(),
          user_code: String.t(),
          expires_in: pos_integer(),
          interval: pos_integer()
        }

  @doc "Seconds a device code stays valid."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Starts a device login. `meta[:user_agent]` (the CLI's) is kept to name the token.
  Returns the device code (shown only here) and the formatted user code.
  """
  @spec start(Openmaru.Accounts.meta()) :: {:ok, authorization()}
  def start(meta \\ %{}) do
    device_code = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = Openmaru.Schema.timestamp()

    row = %{
      device_code_hash: hash(device_code),
      status: "pending",
      user_agent: clean_user_agent(meta[:user_agent]),
      expires_at: DateTime.add(now, @ttl_seconds, :second),
      interval_secs: @interval_seconds,
      inserted_at: now,
      updated_at: now
    }

    user_code = insert_with_free_user_code(row, @insert_attempts)

    {:ok,
     %{
       device_code: device_code,
       user_code: format_user_code(user_code),
       expires_in: @ttl_seconds,
       interval: @interval_seconds
     }}
  end

  # User codes are unique; on the rare collision draw again.
  defp insert_with_free_user_code(row, attempts) when attempts > 0 do
    user_code = new_user_code()
    row = Map.merge(row, %{id: Openmaru.UUIDv7.generate(), user_code: user_code})

    case Repo.insert_all(DeviceCode, [row], on_conflict: :nothing, conflict_target: [:user_code]) do
      {1, _} -> user_code
      {0, _} -> insert_with_free_user_code(row, attempts - 1)
    end
  end

  defp new_user_code do
    @user_code_length |> random_symbols([]) |> List.to_string()
  end

  defp random_symbols(0, acc), do: acc

  defp random_symbols(n, acc) do
    <<byte>> = :crypto.strong_rand_bytes(1)

    if byte < @byte_limit,
      do: random_symbols(n - 1, [Enum.at(@alphabet, rem(byte, @alphabet_size)) | acc]),
      else: random_symbols(n, acc)
  end

  @doc """
  Polls a device code. Returns the new token once the code is approved; otherwise one of
  the errors in the module doc. `meta` (the CLI's IP and user agent) goes to the audit
  log with the new token.
  """
  @spec poll(String.t(), Openmaru.Accounts.meta()) ::
          {:ok, String.t(), PersonalAccessToken.t()} | {:error, Error.t()}
  def poll(device_code, meta \\ %{}) when is_binary(device_code) do
    # Errors are results, not rollbacks: the poll time and expiry they record must stick.
    {:ok, result} = Repo.transaction(fn -> poll_locked(hash(device_code), meta) end)
    result
  end

  defp poll_locked(device_code_hash, meta) do
    query =
      from d in DeviceCode, where: d.device_code_hash == ^device_code_hash, lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, device_error(:invalid_grant)}
      %DeviceCode{status: "consumed"} -> {:error, device_error(:invalid_grant)}
      %DeviceCode{status: "denied"} -> {:error, device_error(:access_denied)}
      code -> poll_live(code, Openmaru.Schema.timestamp(), meta)
    end
  end

  defp poll_live(%DeviceCode{} = code, now, meta) do
    cond do
      expired?(code, now) ->
        mark_expired(code)
        {:error, device_error(:expired_token)}

      code.status == "pending" ->
        record_poll(code, now)

      code.status == "approved" ->
        issue(code, meta)
    end
  end

  defp record_poll(%DeviceCode{last_polled_at: last} = code, now) do
    set!(code, last_polled_at: now)

    if last && DateTime.diff(now, last, :microsecond) < code.interval_secs * 1_000_000,
      do: {:error, device_error(:slow_down)},
      else: {:error, device_error(:authorization_pending)}
  end

  defp issue(%DeviceCode{user_id: user_id} = code, meta) do
    user = Repo.get!(User, user_id)

    if User.suspended?(user) do
      {:error, device_error(:access_denied)}
    else
      # Always valid: the stored user agent is at most 80 characters, the name limit 100.
      {:ok, token, pat} = PAT.create(user, %{name: token_name(code.user_agent)}, meta)
      set!(code, status: "consumed")
      {:ok, token, pat}
    end
  end

  defp token_name(nil), do: "CLI"
  defp token_name(user_agent), do: "CLI (#{user_agent})"

  @doc """
  Approves the device login with `user_code` for `user`: the CLI's next poll receives a
  token acting as `user`. The code is matched ignoring case, spaces and the hyphen.

  Errors: `not_found` (unknown code), `expired_token`, `invalid_grant` (already approved
  or denied).
  """
  @spec approve(User.t(), term(), Openmaru.Accounts.meta()) :: :ok | {:error, Error.t()}
  def approve(%User{} = user, user_code, meta \\ %{}),
    do: decide(user, user_code, "approved", meta)

  @doc "Denies the device login with `user_code`; the CLI's next poll gets `access_denied`. Errors as `approve/3`."
  @spec deny(User.t(), term(), Openmaru.Accounts.meta()) :: :ok | {:error, Error.t()}
  def deny(%User{} = user, user_code, meta \\ %{}), do: decide(user, user_code, "denied", meta)

  defp decide(user, user_code, status, meta) do
    with {:ok, user_code} <- normalize_user_code(user_code) do
      {:ok, result} = Repo.transaction(fn -> decide_locked(user_code, user, status, meta) end)
      result
    end
  end

  defp decide_locked(user_code, user, status, meta) do
    query = from d in DeviceCode, where: d.user_code == ^user_code, lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, unknown_user_code()}
      code -> decide_live(code, user, status, Openmaru.Schema.timestamp(), meta)
    end
  end

  defp decide_live(code, user, status, now, meta) do
    cond do
      expired?(code, now) ->
        mark_expired(code)
        {:error, device_error(:expired_token)}

      code.status != "pending" ->
        {:error, device_error(:invalid_grant)}

      true ->
        set!(code, status: status, user_id: user.id)
        action = if status == "approved", do: "auth.device_approved", else: "auth.device_denied"
        audit(meta, action, user, code)
        :ok
    end
  end

  defp normalize_user_code(user_code) when is_binary(user_code) do
    normalized = user_code |> String.upcase() |> String.replace(["-", " "], "")

    if normalized =~ @user_code_format,
      do: {:ok, normalized},
      else: {:error, unknown_user_code()}
  end

  defp normalize_user_code(_user_code), do: {:error, unknown_user_code()}

  @doc """
  Deletes device codes that expired more than a day ago (kept that long so a late poll
  still gets `expired_token`). Returns the number deleted.
  """
  @spec prune() :: non_neg_integer()
  def prune do
    day_ago = DateTime.add(Clock.now(), -24 * 3600, :second)
    {deleted, _} = Repo.delete_all(from d in DeviceCode, where: d.expires_at <= ^day_ago)
    deleted
  end

  ## Helpers

  defp expired?(%DeviceCode{status: "expired"}, _now), do: true

  defp expired?(%DeviceCode{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp mark_expired(%DeviceCode{status: "expired"}), do: :ok
  defp mark_expired(code), do: set!(code, status: "expired")

  defp set!(%DeviceCode{id: id}, changes) do
    changes = Keyword.put(changes, :updated_at, Openmaru.Schema.timestamp())
    {1, _} = Repo.update_all(from(d in DeviceCode, where: d.id == ^id), set: changes)
    :ok
  end

  defp format_user_code(<<first::binary-size(4), second::binary-size(4)>>),
    do: first <> "-" <> second

  # Printable ASCII only, one line, short enough for a token name.
  defp clean_user_agent(user_agent) when is_binary(user_agent) do
    user_agent
    |> String.replace(~r/[^\x20-\x7E]/, "")
    |> String.trim()
    |> String.slice(0, @user_agent_max)
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean_user_agent(_user_agent), do: nil

  defp hash(code), do: :crypto.hash(:sha256, code)

  defp unknown_user_code, do: Error.new(:not_found, "Unknown device code")

  defp device_error(:authorization_pending),
    do: Error.new(:authorization_pending, "Waiting for approval")

  defp device_error(:slow_down),
    do: Error.new(:slow_down, "Polling too fast", %{interval: @interval_seconds})

  defp device_error(:expired_token), do: Error.new(:expired_token, "The device code has expired")
  defp device_error(:access_denied), do: Error.new(:access_denied, "The request was denied")
  defp device_error(:invalid_grant), do: Error.new(:invalid_grant, "Unknown or used device code")

  defp audit(meta, action, user, code) do
    {:ok, _entry} =
      Audit.record(%{
        action: action,
        actor: {:person, user.id},
        target: {"device_code", code.id},
        ip: meta[:ip],
        user_agent: meta[:user_agent],
        metadata: %{"client_user_agent" => code.user_agent}
      })

    :ok
  end
end
