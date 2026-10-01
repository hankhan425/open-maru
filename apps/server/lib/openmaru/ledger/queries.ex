defmodule Openmaru.Ledger.Queries do
  @moduledoc false
  # Read side of `Openmaru.Ledger` (SPEC-03 §4.6).

  import Ecto.Query

  alias Openmaru.{Error, Ledger, Repo}
  alias Openmaru.Ledger.{Account, Transfer}

  @default_limit 100
  @max_limit 1_000
  @filter_keys [:code, :period_key, :from, :to, :cursor, :limit, :order]

  @spec lookup_accounts([Ecto.UUID.t()]) :: [Account.t()]
  def lookup_accounts(ids), do: lookup(Account, ids)

  @spec lookup_transfers([Ecto.UUID.t()]) :: [Transfer.t()]
  def lookup_transfers(ids), do: lookup(Transfer, ids)

  # Found rows in input order; unknown or malformed ids are skipped.
  defp lookup(schema, ids) do
    valid = for id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], uniq: true, do: uuid

    found =
      case valid do
        [] -> %{}
        _ -> schema |> where([r], r.id in ^valid) |> Repo.all() |> Map.new(&{&1.id, &1})
      end

    for id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], row = found[uuid], do: row
  end

  @spec balance(Ecto.UUID.t()) :: {:ok, Ledger.balance()} | {:error, Error.t()}
  def balance(account_id) do
    case lookup_accounts([account_id]) do
      [account] ->
        {:ok,
         %{
           debits_pending: account.debits_pending,
           debits_posted: account.debits_posted,
           credits_pending: account.credits_pending,
           credits_posted: account.credits_posted,
           available: available(account)
         }}

      [] ->
        {:error, Error.new(:not_found, "Ledger account not found")}
    end
  end

  # What a balancing transfer could take (SPEC-03 §4.5): debit side, or credit side for
  # credits_must_not_exceed_debits accounts.
  defp available(%Account{flags: flags} = a) do
    if :credits_must_not_exceed_debits in flags,
      do: a.debits_posted - a.credits_posted - a.credits_pending,
      else: a.credits_posted - a.debits_posted - a.debits_pending
  end

  @spec account_transfers(Ecto.UUID.t(), Ledger.account_filter()) ::
          {:ok, %{data: [Transfer.t()], next_cursor: String.t() | nil}} | {:error, Error.t()}
  def account_transfers(account_id, filter) do
    filter = Map.new(filter)

    case Map.keys(filter) -- @filter_keys do
      [] -> :ok
      extra -> raise ArgumentError, "unknown account_transfers filters: #{inspect(extra)}"
    end

    with {:ok, limit} <- limit(filter),
         {:ok, order} <- order(filter),
         {:ok, cursor} <- decode_cursor(filter[:cursor]),
         {:ok, account_id} <- account_id(account_id) do
      rows =
        Transfer
        |> where([t], t.debit_account_id == ^account_id or t.credit_account_id == ^account_id)
        |> filter_code(filter[:code])
        |> filter_period(filter[:period_key])
        |> filter_time(:from, filter[:from])
        |> filter_time(:to, filter[:to])
        |> after_cursor(order, cursor)
        |> order_by([t], [{^order, t.seq}])
        |> limit(^(limit + 1))
        |> Repo.all()

      {data, rest} = Enum.split(rows, limit)
      next = if rest != [], do: encode_cursor(List.last(data).seq)
      {:ok, %{data: data, next_cursor: next}}
    end
  end

  defp limit(filter) do
    case Map.get(filter, :limit, @default_limit) do
      limit when is_integer(limit) and limit in 1..@max_limit -> {:ok, limit}
      _ -> invalid("limit must be between 1 and #{@max_limit}")
    end
  end

  defp order(filter) do
    case Map.get(filter, :order, :asc) do
      order when order in [:asc, :desc] -> {:ok, order}
      _ -> invalid("order must be :asc or :desc")
    end
  end

  defp account_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid("account id must be a UUID")
    end
  end

  defp filter_code(query, nil), do: query
  defp filter_code(query, codes) when is_list(codes), do: where(query, [t], t.code in ^codes)
  defp filter_code(query, code) when is_integer(code), do: where(query, [t], t.code == ^code)

  defp filter_period(query, nil), do: query

  defp filter_period(query, key) when is_integer(key),
    do: where(query, [t], t.user_data_64 == ^key)

  # `from` is inclusive, `to` exclusive; DateTimes or microseconds since the epoch.
  defp filter_time(query, _bound, nil), do: query

  defp filter_time(query, bound, %DateTime{} = at),
    do: filter_time(query, bound, DateTime.to_unix(at, :microsecond))

  defp filter_time(query, :from, micros) when is_integer(micros),
    do: where(query, [t], t.timestamp >= ^micros)

  defp filter_time(query, :to, micros) when is_integer(micros),
    do: where(query, [t], t.timestamp < ^micros)

  defp after_cursor(query, _order, nil), do: query
  defp after_cursor(query, :asc, seq), do: where(query, [t], t.seq > ^seq)
  defp after_cursor(query, :desc, seq), do: where(query, [t], t.seq < ^seq)

  # Opaque to callers: the last row's seq.
  defp encode_cursor(seq), do: Base.url_encode64("seq:#{seq}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, "seq:" <> digits} <- Base.url_decode64(cursor, padding: false),
         {seq, ""} when seq > 0 <- Integer.parse(digits) do
      {:ok, seq}
    else
      _ -> invalid("invalid cursor")
    end
  end

  defp decode_cursor(_cursor), do: invalid("invalid cursor")

  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}
end
