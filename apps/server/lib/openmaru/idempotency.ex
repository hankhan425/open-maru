defmodule Openmaru.Idempotency do
  @moduledoc """
  Storage for `Idempotency-Key` replays (CONVENTIONS §5). Keys are scoped per principal
  and kept for 24 hours; a replay within that window returns the original response.

  A request that is still executing holds its key for 5 minutes; after that the
  key is treated as abandoned (for example, the request crashed) and may be retried.
  """

  import Ecto.Query

  alias Openmaru.{Clock, Error, Repo}
  alias Openmaru.Idempotency.Key

  @ttl_seconds 24 * 3600
  @in_flight_seconds 5 * 60

  @doc """
  Claims `key` for `principal` and a request fingerprint.

    * `{:execute, key}` — first use (or the previous use expired): run the request, then
      call `complete/3`.
    * `{:replay, key}` — an identical request already finished: return its response.
    * `{:error, %Error{code: :idempotency_conflict}}` — the key was used with a different
      request, or the first request is still executing.
  """
  @spec claim(String.t(), String.t(), String.t()) ::
          {:execute, Key.t()} | {:replay, Key.t()} | {:error, Error.t()}
  def claim(principal, key, request_hash) do
    claim(principal, key, request_hash, Clock.now(), 1)
  end

  defp claim(principal, key, request_hash, now, retries) do
    case Repo.get_by(Key, principal: principal, key: key) do
      nil ->
        insert(principal, key, request_hash, now, retries)

      %Key{} = existing ->
        cond do
          reusable?(existing, now) ->
            Repo.delete_all(from k in Key, where: k.id == ^existing.id)
            insert(principal, key, request_hash, now, retries)

          existing.request_hash != request_hash ->
            {:error,
             Error.new(:idempotency_conflict, "Idempotency-Key was used with a different request")}

          is_nil(existing.status) ->
            {:error,
             Error.new(
               :idempotency_conflict,
               "A request with this Idempotency-Key is in progress"
             )}

          true ->
            {:replay, existing}
        end
    end
  end

  defp reusable?(%Key{} = key, now) do
    expired?(key, now) or
      (is_nil(key.status) and
         DateTime.compare(DateTime.add(key.inserted_at, @in_flight_seconds, :second), now) != :gt)
  end

  defp expired?(%Key{expires_at: expires_at}, now), do: DateTime.compare(expires_at, now) != :gt

  defp insert(principal, key, request_hash, now, retries) do
    now = %{now | microsecond: {elem(now.microsecond, 0), 6}}

    row = %{
      id: Openmaru.UUIDv7.generate(),
      key: key,
      principal: principal,
      request_hash: request_hash,
      expires_at: DateTime.add(now, @ttl_seconds, :second),
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Key, [row], on_conflict: :nothing, conflict_target: [:principal, :key]) do
      {1, _} -> {:execute, struct!(Key, row)}
      {0, _} when retries > 0 -> claim(principal, key, request_hash, now, retries - 1)
      {0, _} -> {:error, Error.new(:idempotency_conflict, "Idempotency-Key is in use")}
    end
  end

  @doc """
  Stores the response for a claimed key. 5xx responses are not stored: the key is
  released so the client can retry.
  """
  @spec complete(Key.t(), pos_integer(), String.t()) :: :ok
  def complete(%Key{} = key, status, _body) when status >= 500, do: release(key)

  def complete(%Key{id: id}, status, body) do
    Repo.update_all(from(k in Key, where: k.id == ^id),
      set: [status: status, body: body, updated_at: Openmaru.Schema.timestamp()]
    )

    :ok
  end

  @doc "Releases a claimed key without storing a response."
  @spec release(Key.t()) :: :ok
  def release(%Key{id: id}) do
    Repo.delete_all(from k in Key, where: k.id == ^id)
    :ok
  end
end
