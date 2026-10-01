defmodule Openmaru.Ledger.CreateTransfers do
  @moduledoc false
  # `Openmaru.Ledger.create_transfers/1`: normalizes input, takes the ledger lock, loads
  # everything the batch touches in a few queries, applies `Openmaru.Ledger.Rules` in
  # memory, then writes the created rows, the changed balances and the expiry index.

  alias Openmaru.{Ledger, Repo}
  alias Openmaru.Ledger.{Chain, Flags, Rules}

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @i32_max 2_147_483_647
  @insert_chunk 2_000

  @keys [
    :id,
    :debit_account_id,
    :credit_account_id,
    :amount,
    :pending_id,
    :flags,
    :timeout_secs,
    :code,
    :user_data_128,
    :user_data_64
  ]

  # Row maps use these atoms as keys; query results are zipped with them in this order.
  @transfer_fields [
    :id,
    :debit_account_id,
    :credit_account_id,
    :amount,
    :requested_amount,
    :pending_id,
    :flags,
    :timeout_secs,
    :ledger,
    :code,
    :user_data_128,
    :user_data_64,
    :timestamp,
    :seq,
    :prev_hash,
    :hash
  ]
  @account_fields [
    :id,
    :ledger,
    :flags,
    :debits_pending,
    :debits_posted,
    :credits_pending,
    :credits_posted
  ]
  @resolution_fields [:id, :pending_id, :flags, :user_data_64]

  @doc """
  Creates transfers. With `expiry: true` (the sweeper only), voids may resolve pending
  transfers at or after their expiry.
  """
  @spec run([Ledger.transfer()], keyword()) :: [Rules.result()]
  def run(transfers, opts \\ [])
  def run([], _opts), do: []

  def run(transfers, opts) when is_list(transfers) do
    inputs = Enum.map(transfers, &normalize/1)

    {:ok, results} =
      Repo.transaction(fn ->
        Ledger.lock!()
        state = load(inputs, Keyword.get(opts, :expiry, false))
        {results, state} = Rules.apply_batch(inputs, state)
        persist(state)
        results
      end)

    results
  end

  ## Input

  defp normalize(%{} = transfer) do
    case Map.keys(transfer) -- @keys do
      [] -> :ok
      extra -> raise ArgumentError, "unknown transfer fields: #{inspect(extra)}"
    end

    %{
      id: id(transfer[:id], :id),
      debit_account_id: uuid(transfer[:debit_account_id], :debit_account_id),
      credit_account_id: uuid(transfer[:credit_account_id], :credit_account_id),
      amount: integer(transfer[:amount], :amount, 0, @i64_max),
      pending_id: id(transfer[:pending_id], :pending_id),
      flags: Flags.to_bits(:transfer, Map.get(transfer, :flags, [])),
      timeout_secs: integer(transfer[:timeout_secs], :timeout_secs, 0, @i32_max) || 0,
      code: integer(transfer[:code], :code, 0, @i32_max),
      user_data_128: uuid(transfer[:user_data_128], :user_data_128),
      user_data_64: integer(transfer[:user_data_64], :user_data_64, @i64_min, @i64_max)
    }
  end

  defp normalize(other),
    do: raise(ArgumentError, "a transfer must be a map, got: #{inspect(other)}")

  # The zero UUID counts as "no id" (TigerBeetle's id 0).
  defp id(value, field) do
    case uuid(value, field) do
      <<0::128>> -> nil
      raw -> raw
    end
  end

  @doc false
  @spec uuid(term(), atom()) :: <<_::128>> | nil
  def uuid(nil, _field), do: nil

  def uuid(value, field) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, raw} -> raw
      :error -> raise ArgumentError, "#{field} must be a UUID, got: #{inspect(value)}"
    end
  end

  def uuid(value, field),
    do: raise(ArgumentError, "#{field} must be a UUID, got: #{inspect(value)}")

  defp integer(nil, _field, _min, _max), do: nil

  defp integer(value, _field, min, max) when is_integer(value) and value >= min and value <= max,
    do: value

  defp integer(value, field, min, max),
    do:
      raise(
        ArgumentError,
        "#{field} must be an integer in #{min}..#{max}, got: #{inspect(value)}"
      )

  ## Load

  defp load(inputs, expiry?) do
    pending_ids = inputs |> Enum.map(& &1.pending_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    ids = inputs |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)
    transfers = select_transfers(Enum.uniq(ids ++ pending_ids))

    pending_accounts =
      for id <- pending_ids,
          p = transfers[id],
          account <- [p.debit_account_id, p.credit_account_id],
          do: account

    input_accounts = Enum.flat_map(inputs, &[&1.debit_account_id, &1.credit_account_id])
    account_ids = (input_accounts ++ pending_accounts) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    {seq, timestamp, hash} = head()

    Rules.new_state(%{
      accounts: select_accounts(account_ids),
      transfers: transfers,
      resolutions: select_resolutions(pending_ids),
      seq: seq,
      timestamp: timestamp,
      hash: hash,
      now: DateTime.to_unix(Openmaru.Clock.now(), :microsecond),
      expiry?: expiry?
    })
  end

  defp head do
    case Repo.query!(
           "SELECT seq, timestamp, hash FROM ledger_transfers ORDER BY seq DESC LIMIT 1",
           [],
           cache_statement: "ledger_head"
         ) do
      %{rows: [[seq, timestamp, hash]]} -> {seq, timestamp, hash}
      %{rows: []} -> {0, 0, Chain.genesis()}
    end
  end

  defp select_transfers([]), do: %{}

  defp select_transfers(ids) do
    "ledger_transfers"
    |> select_rows(@transfer_fields, "id = ANY($1)", [ids])
    |> Map.new(&{&1.id, &1})
  end

  defp select_resolutions([]), do: %{}

  defp select_resolutions(pending_ids) do
    "ledger_transfers"
    |> select_rows(@resolution_fields, "pending_id = ANY($1)", [pending_ids])
    |> Map.new(&{&1.pending_id, &1})
  end

  defp select_accounts([]), do: %{}

  defp select_accounts(ids) do
    "ledger_accounts"
    |> select_rows(@account_fields, "id = ANY($1)", [ids])
    |> Map.new(&{&1.id, &1})
  end

  @doc "The stored transfer columns, in hash-encoding order."
  @spec transfer_fields() :: [atom()]
  def transfer_fields, do: @transfer_fields

  @doc "Selects `fields` of `table` rows matching `where` as maps keyed by those fields."
  @spec select_rows(String.t(), [atom()], String.t(), list()) :: [map()]
  def select_rows(table, fields, where, params) do
    sql = "SELECT #{Enum.map_join(fields, ", ", &Atom.to_string/1)} FROM #{table} WHERE #{where}"
    %{rows: rows} = Repo.query!(sql, params, cache_statement: "ledger_#{:erlang.phash2(sql)}")

    Enum.map(rows, &(fields |> Enum.zip(&1) |> Map.new()))
  end

  ## Persist

  defp persist(state) do
    state.created
    |> Enum.reverse()
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(&Repo.insert_all("ledger_transfers", &1))

    update_balances(state)
    update_expiries(state.expiries)
  end

  defp update_balances(%{dirty: dirty, accounts: accounts}) do
    if MapSet.size(dirty) > 0 do
      changed = Enum.map(dirty, &Map.fetch!(accounts, &1))

      Repo.query!(
        """
        UPDATE ledger_accounts AS a
        SET debits_pending = v.debits_pending, debits_posted = v.debits_posted,
            credits_pending = v.credits_pending, credits_posted = v.credits_posted
        FROM unnest($1::uuid[], $2::bigint[], $3::bigint[], $4::bigint[], $5::bigint[])
          AS v(id, debits_pending, debits_posted, credits_pending, credits_posted)
        WHERE a.id = v.id
        """,
        [
          Enum.map(changed, & &1.id),
          Enum.map(changed, & &1.debits_pending),
          Enum.map(changed, & &1.debits_posted),
          Enum.map(changed, & &1.credits_pending),
          Enum.map(changed, & &1.credits_posted)
        ],
        cache_statement: "ledger_update_balances"
      )
    end

    :ok
  end

  defp update_expiries(expiries) do
    {adds, removes} = Enum.split_with(expiries, &match?({_id, {:add, _at}}, &1))

    adds
    |> Enum.map(fn {id, {:add, at}} -> %{pending_id: id, expires_at: at} end)
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(&Repo.insert_all("ledger_pending_expiries", &1))

    if removes != [] do
      Repo.query!(
        "DELETE FROM ledger_pending_expiries WHERE pending_id = ANY($1)",
        [Enum.map(removes, &elem(&1, 0))],
        cache_statement: "ledger_delete_expiries"
      )
    end

    :ok
  end
end
