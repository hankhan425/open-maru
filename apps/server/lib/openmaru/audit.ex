defmodule Openmaru.Audit do
  @moduledoc """
  The append-only security audit log (SPEC-09 §7): sign-ins, token mint/revoke, secret
  writes, pause/resume/stop, admin actions, spec activations. A database trigger rejects
  `UPDATE`, `DELETE` and `TRUNCATE` on `audit_log`.

  Client IPs are stored only as a keyed hash (HMAC-SHA-256), so equal addresses can be
  correlated without keeping them (SPEC-09 §7, OQ-6). Each UTC day gets its own random key
  (`Openmaru.Audit.IpKey`), created on first use and stored sealed (AES-256-GCM) under the
  wrapping key in this module's config (`AUDIT_IP_HASH_KEY` in production). Each row records
  the id of the key that hashed its IP. `destroy_expired_ip_keys/0` (hourly) destroys a key
  30 days after its day ends, so an address stays linkable for at most 31 days; a key
  sealed under a previous wrapping key can't be used and is destroyed on the next run.
  """

  import Ecto.Query

  alias Openmaru.Audit.{Entry, IpKey}
  alias Openmaru.Repo

  @user_agent_max 512
  @ip_key_retention_days 30

  @typedoc "Who acted: `{kind, id}` with kind `:person`, `:agent` or `:system`."
  @type actor :: {:person | :agent | :system, Ecto.UUID.t() | nil} | nil

  @typedoc "A client address: an `:inet` tuple or its string form."
  @type ip :: :inet.ip_address() | String.t()

  @typedoc """
  An audit event. `:action` is a dotted name (`auth.sign_in_succeeded`); `:target` is
  `{type, id}`.
  """
  @type attrs :: %{
          required(:action) => String.t(),
          optional(:actor) => actor(),
          optional(:target) => {String.t(), Ecto.UUID.t()} | nil,
          optional(:ip) => ip() | nil,
          optional(:user_agent) => String.t() | nil,
          optional(:metadata) => map()
        }

  @doc "Appends an entry."
  @spec record(attrs()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(%{action: action} = attrs) when is_binary(action) do
    {actor_kind, actor_id} = actor(attrs[:actor])
    {target_type, target_id} = attrs[:target] || {nil, nil}
    {ip_hash, ip_hash_key_id} = hash_with_current_key(attrs[:ip])

    Repo.insert(%Entry{
      action: action,
      actor_kind: actor_kind,
      actor_id: actor_id,
      target_type: target_type,
      target_id: target_id,
      ip_hash: ip_hash,
      ip_hash_key_id: ip_hash_key_id,
      user_agent: truncate(attrs[:user_agent]),
      metadata: Map.get(attrs, :metadata, %{}),
      occurred_at: Openmaru.Schema.timestamp()
    })
  end

  @doc """
  Keyed hash (lowercase hex) of a client IP under today's key, or `nil` for `nil`. Tuples
  and their string forms hash alike.
  """
  @spec hash_ip(ip() | nil) :: String.t() | nil
  def hash_ip(ip), do: ip |> hash_with_current_key() |> elem(0)

  @doc "The id of today's IP hash key, the value rows hashed today record in `ip_hash_key_id`."
  @spec ip_hash_key_id() :: String.t()
  def ip_hash_key_id, do: current_ip_key() |> elem(0)

  @doc """
  The hashes of `ip` under every key that is not yet destroyed, newest day first: the way
  to find an address in the log across days (SPEC-09 §7).
  """
  @spec hashes_for_ip(ip()) :: [%{ip_hash_key_id: String.t(), ip_hash: String.t()}]
  def hashes_for_ip(ip) do
    wrapping_key = wrapping_key()
    wrapping_key_id = key_id(wrapping_key)
    oldest = oldest_kept_day()

    IpKey
    |> where([k], k.wrapping_key_id == ^wrapping_key_id and not is_nil(k.sealed_key))
    |> where([k], k.day >= ^oldest)
    |> order_by([k], desc: k.day, asc: k.id)
    |> Repo.all()
    |> Enum.map(&%{ip_hash_key_id: &1.id, ip_hash: hmac(unseal!(&1, wrapping_key), ip)})
  end

  @doc """
  Destroys every IP hash key whose day ended more than #{@ip_key_retention_days} days ago, and
  every key sealed under another wrapping key (unusable after a rotation). Returns how many
  were destroyed. Run hourly by `Openmaru.Audit.IpKeySweeper`.
  """
  @spec destroy_expired_ip_keys() :: non_neg_integer()
  def destroy_expired_ip_keys do
    oldest = oldest_kept_day()
    wrapping_key_id = key_id(wrapping_key())

    {count, _rows} =
      IpKey
      |> where([k], not is_nil(k.sealed_key))
      |> where([k], k.day < ^oldest or k.wrapping_key_id != ^wrapping_key_id)
      |> Repo.update_all(set: [sealed_key: nil, destroyed_at: Openmaru.Schema.timestamp()])

    count
  end

  @doc """
  A fingerprint of `key`: the first 8 hex digits of a SHA-256 over it. `IpKey` rows record
  the fingerprint of the wrapping key that sealed them.
  """
  @spec key_id(binary()) :: String.t()
  def key_id(key) when is_binary(key) do
    :sha256
    |> :crypto.hash(["openmaru audit ip hash key id:", key])
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end

  defp hash_with_current_key(nil), do: {nil, nil}

  defp hash_with_current_key(ip) do
    {key_id, key} = current_ip_key()
    {hmac(key, ip), key_id}
  end

  defp hmac(key, ip) when is_tuple(ip), do: hmac(key, ip |> :inet.ntoa() |> to_string())

  defp hmac(key, ip) when is_binary(ip) do
    :hmac |> :crypto.mac(:sha256, key, ip) |> Base.encode16(case: :lower)
  end

  # Today's key: the oldest live one sealed under the current wrapping key, or a new one.
  # There is no unique index on the day, so a first write never waits for another
  # transaction; if two create a key at once, later writes use the older.
  defp current_ip_key do
    wrapping_key = wrapping_key()
    wrapping_key_id = key_id(wrapping_key)
    day = today()

    IpKey
    |> where([k], k.day == ^day and k.wrapping_key_id == ^wrapping_key_id)
    |> where([k], not is_nil(k.sealed_key))
    |> order_by([k], asc: k.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      %IpKey{} = ip_key -> {ip_key.id, unseal!(ip_key, wrapping_key)}
      nil -> create_ip_key(day, wrapping_key, wrapping_key_id)
    end
  end

  defp create_ip_key(day, wrapping_key, wrapping_key_id) do
    key = :crypto.strong_rand_bytes(32)
    ip_key = %IpKey{id: Openmaru.UUIDv7.generate(), day: day, wrapping_key_id: wrapping_key_id}
    ip_key = Repo.insert!(%{ip_key | sealed_key: seal(key, ip_key, wrapping_key)})
    {ip_key.id, key}
  end

  defp seal(key, ip_key, wrapping_key) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, kek(wrapping_key), iv, key, aad(ip_key), true)

    iv <> tag <> ciphertext
  end

  defp unseal!(%IpKey{sealed_key: <<iv::binary-12, tag::binary-16, ciphertext::binary>>} = k, wk) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, kek(wk), iv, ciphertext, aad(k), tag, false) do
      :error -> raise "audit IP hash key #{k.id} does not unseal under the wrapping key"
      key -> key
    end
  end

  # The sealed key is bound to its row, so it can't be moved to another day.
  defp aad(%IpKey{id: id, day: day, wrapping_key_id: wrapping_key_id}),
    do: "openmaru audit ip hash key:#{id}:#{Date.to_iso8601(day)}:#{wrapping_key_id}"

  defp kek(wrapping_key),
    do: :crypto.hash(:sha256, ["openmaru audit ip key wrapping:", wrapping_key])

  defp today, do: Openmaru.Clock.now() |> DateTime.to_date()

  defp oldest_kept_day, do: Date.add(today(), -@ip_key_retention_days)

  defp actor(nil), do: {nil, nil}
  defp actor({kind, id}) when kind in [:person, :agent, :system], do: {Atom.to_string(kind), id}

  defp truncate(nil), do: nil
  defp truncate(string), do: String.slice(string, 0, @user_agent_max)

  defp wrapping_key do
    :openmaru |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:ip_key_wrapping_key)
  end
end
