defmodule Openmaru.Ledger.Expiry do
  @moduledoc false
  # The pending-expiry sweep behind `Openmaru.Ledger.expire_pending/0` (SPEC-03 §4.3).

  alias Openmaru.Ledger
  alias Openmaru.Ledger.CreateTransfers
  alias Openmaru.Repo

  @batch 500

  @spec run() :: {:ok, non_neg_integer()}
  def run do
    now = DateTime.to_unix(Openmaru.Clock.now(), :microsecond)
    sweep(now, {-1, <<0::128>>}, 0)
  end

  # Walks due entries in (expires_at, pending_id) order, one transaction per batch, so
  # each entry is visited once per run even if its void fails.
  defp sweep(now, {after_at, after_id}, count) do
    %{rows: due} =
      Repo.query!(
        """
        SELECT expires_at, pending_id FROM ledger_pending_expiries
        WHERE expires_at <= $1 AND (expires_at, pending_id) > ($2, $3)
        ORDER BY expires_at, pending_id
        LIMIT $4
        """,
        [now, after_at, after_id, @batch]
      )

    case due do
      [] ->
        {:ok, count}

      due ->
        voids =
          for [_at, pending_id] <- due do
            pending = Ecto.UUID.load!(pending_id)

            %{
              id: Ledger.uuidv5("expire:" <> pending),
              pending_id: pending,
              flags: [:void_pending],
              user_data_64: -1
            }
          end

        results = CreateTransfers.run(voids, expiry: true)
        drop_stale(due, results)
        [last_at, last_id] = List.last(due)
        sweep(now, {last_at, last_id}, count + Enum.count(results, &(&1 == {:ok, :created})))
    end
  end

  # An entry whose pending transfer is already resolved is stale: remove it.
  defp drop_stale(due, results) do
    stale =
      for {[_at, pending_id], result} <- Enum.zip(due, results),
          result != {:ok, :created},
          do: pending_id

    if stale != [] do
      Repo.query!("DELETE FROM ledger_pending_expiries WHERE pending_id = ANY($1)", [stale])
    end

    :ok
  end
end
