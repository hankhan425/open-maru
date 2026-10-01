defmodule Openmaru.Audit do
  @moduledoc """
  The append-only security audit log (SPEC-09 §7): sign-ins, token mint/revoke, secret
  writes, pause/resume/stop, admin actions, spec activations. A database trigger rejects
  `UPDATE`, `DELETE` and `TRUNCATE` on `audit_log`.

  Client IPs are stored only as a keyed hash (`hash_ip/1`, HMAC-SHA-256 with the
  `:ip_hash_key` of this module's config), so equal addresses can be correlated without
  keeping them (SPEC-09 §7, OQ-6). The key is dedicated to this purpose
  (`AUDIT_IP_HASH_KEY` in production, not derived from `SECRET_KEY_BASE`), and each row
  records the key's id (`key_id/1`, a fingerprint of the key). After a rotation, hashes
  under the new key do not match older ones; the id tells them apart.
  """

  alias Openmaru.Audit.Entry
  alias Openmaru.Repo

  @user_agent_max 512

  @typedoc "Who acted: `{kind, id}` with kind `:person`, `:agent` or `:system`."
  @type actor :: {:person | :agent | :system, Ecto.UUID.t() | nil} | nil

  @typedoc """
  An audit event. `:action` is a dotted name (`auth.sign_in_succeeded`); `:target` is
  `{type, id}`; `:ip` is an `:inet` address or its string form.
  """
  @type attrs :: %{
          required(:action) => String.t(),
          optional(:actor) => actor(),
          optional(:target) => {String.t(), Ecto.UUID.t()} | nil,
          optional(:ip) => :inet.ip_address() | String.t() | nil,
          optional(:user_agent) => String.t() | nil,
          optional(:metadata) => map()
        }

  @doc "Appends an entry."
  @spec record(attrs()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(%{action: action} = attrs) when is_binary(action) do
    {actor_kind, actor_id} = actor(attrs[:actor])
    {target_type, target_id} = attrs[:target] || {nil, nil}

    Repo.insert(%Entry{
      action: action,
      actor_kind: actor_kind,
      actor_id: actor_id,
      target_type: target_type,
      target_id: target_id,
      ip_hash: hash_ip(attrs[:ip]),
      ip_hash_key_id: if(attrs[:ip], do: ip_hash_key_id()),
      user_agent: truncate(attrs[:user_agent]),
      metadata: Map.get(attrs, :metadata, %{}),
      occurred_at: Openmaru.Schema.timestamp()
    })
  end

  @doc """
  Keyed hash (lowercase hex) of a client IP, or `nil` for `nil`. Tuples and their string
  forms hash alike.
  """
  @spec hash_ip(:inet.ip_address() | String.t() | nil) :: String.t() | nil
  def hash_ip(nil), do: nil
  def hash_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string() |> hash_ip()

  def hash_ip(ip) when is_binary(ip) do
    :hmac
    |> :crypto.mac(:sha256, ip_hash_key(), ip)
    |> Base.encode16(case: :lower)
  end

  @doc "The id of the configured IP hash key (see `key_id/1`)."
  @spec ip_hash_key_id() :: String.t()
  def ip_hash_key_id, do: key_id(ip_hash_key())

  @doc """
  The id recorded next to hashes made with `key`: the first 8 hex digits of a SHA-256
  over the key. It changes whenever the key does, so a rotation needs no separate id.
  """
  @spec key_id(binary()) :: String.t()
  def key_id(key) when is_binary(key) do
    :sha256
    |> :crypto.hash(["openmaru audit ip hash key id:", key])
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end

  defp actor(nil), do: {nil, nil}
  defp actor({kind, id}) when kind in [:person, :agent, :system], do: {Atom.to_string(kind), id}

  defp truncate(nil), do: nil
  defp truncate(string), do: String.slice(string, 0, @user_agent_max)

  defp ip_hash_key do
    :openmaru |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:ip_hash_key)
  end
end
