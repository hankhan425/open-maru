defmodule Openmaru.Ledger.Verify do
  @moduledoc false
  # Tamper and drift detection (SPEC-03 §7, §8).

  alias Openmaru.Ledger.{Chain, CreateTransfers}
  alias Openmaru.Repo

  @chunk 5_000
  @balance_keys [:debits_pending, :debits_posted, :credits_pending, :credits_posted]

  @spec verify_chain(integer(), integer()) ::
          :ok | {:error, {:hash_mismatch | :seq_gap, pos_integer()}}
  def verify_chain(from_seq, to_seq) when is_integer(from_seq) and is_integer(to_seq) do
    from_seq = max(from_seq, 1)

    with {:ok, prev_hash} <- start_hash(from_seq) do
      walk(from_seq, to_seq, prev_hash)
    end
  end

  # A range starting after seq 1 trusts the stored hash of the row before it.
  defp start_hash(1), do: {:ok, Chain.genesis()}

  defp start_hash(from_seq) do
    case Repo.query!("SELECT hash FROM ledger_transfers WHERE seq = $1", [from_seq - 1]) do
      %{rows: [[hash]]} ->
        {:ok, hash}

      %{rows: []} ->
        if later_rows?(from_seq - 1), do: {:error, {:seq_gap, from_seq - 1}}, else: {:ok, nil}
    end
  end

  defp walk(seq, to_seq, _prev_hash) when seq > to_seq, do: :ok

  defp walk(seq, to_seq, prev_hash) do
    rows =
      CreateTransfers.select_rows(
        "ledger_transfers",
        CreateTransfers.transfer_fields(),
        "seq >= $1 AND seq <= $2 ORDER BY seq LIMIT $3",
        [seq, to_seq, @chunk]
      )

    rows
    |> Enum.reduce_while({seq, prev_hash}, &check_row/2)
    |> case do
      {:error, _reason} = error ->
        error

      {next, _prev} when rows == [] ->
        if later_rows?(next), do: {:error, {:seq_gap, next}}, else: :ok

      {next, prev} ->
        walk(next, to_seq, prev)
    end
  end

  defp check_row(%{seq: seq}, {expected, _prev}) when seq != expected,
    do: {:halt, {:error, {:seq_gap, expected}}}

  # prev_hash is nil only when the range starts beyond the head (no rows to check).
  defp check_row(row, {seq, prev}) do
    if row.prev_hash == prev and Chain.hash(prev, row) == row.hash,
      do: {:cont, {seq + 1, row.hash}},
      else: {:halt, {:error, {:hash_mismatch, seq}}}
  end

  defp later_rows?(seq) do
    match?(
      %{rows: [_]},
      Repo.query!("SELECT 1 FROM ledger_transfers WHERE seq > $1 LIMIT 1", [seq])
    )
  end

  @spec verify_balances() :: :ok | {:error, [{Ecto.UUID.t(), map(), map()}]}
  def verify_balances do
    # An open pending transfer has no resolution row; posts and plain transfers count as
    # posted; voids and resolved pendings count nowhere.
    %{rows: rows} =
      Repo.query!("""
      WITH legs AS (
        SELECT t.debit_account_id AS account_id,
               CASE WHEN t.flags & 2 <> 0 AND r.id IS NULL THEN t.amount ELSE 0 END AS dp,
               CASE WHEN t.flags & 10 = 0 THEN t.amount ELSE 0 END AS dpo,
               0 AS cp, 0 AS cpo
        FROM ledger_transfers t
        LEFT JOIN ledger_transfers r ON r.pending_id = t.id AND t.flags & 2 <> 0
        UNION ALL
        SELECT t.credit_account_id, 0, 0,
               CASE WHEN t.flags & 2 <> 0 AND r.id IS NULL THEN t.amount ELSE 0 END,
               CASE WHEN t.flags & 10 = 0 THEN t.amount ELSE 0 END
        FROM ledger_transfers t
        LEFT JOIN ledger_transfers r ON r.pending_id = t.id AND t.flags & 2 <> 0
      ), sums AS (
        SELECT account_id, sum(dp) AS dp, sum(dpo) AS dpo, sum(cp) AS cp, sum(cpo) AS cpo
        FROM legs GROUP BY account_id
      )
      SELECT a.id,
             coalesce(s.dp, 0), coalesce(s.dpo, 0), coalesce(s.cp, 0), coalesce(s.cpo, 0),
             a.debits_pending, a.debits_posted, a.credits_pending, a.credits_posted
      FROM ledger_accounts a LEFT JOIN sums s ON s.account_id = a.id
      WHERE (coalesce(s.dp, 0), coalesce(s.dpo, 0), coalesce(s.cp, 0), coalesce(s.cpo, 0))
            IS DISTINCT FROM (a.debits_pending, a.debits_posted, a.credits_pending, a.credits_posted)
      ORDER BY a.id
      """)

    case rows do
      [] ->
        :ok

      rows ->
        {:error,
         Enum.map(rows, fn [id | values] ->
           {expected, actual} = values |> Enum.map(&to_integer/1) |> Enum.split(4)
           {Ecto.UUID.load!(id), balances(expected), balances(actual)}
         end)}
    end
  end

  # Sums arrive as numeric; a tampered table could push them past bigint.
  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value

  defp balances(values), do: @balance_keys |> Enum.zip(values) |> Map.new()
end
