defmodule Openmaru.Ledger.CreateAccounts do
  @moduledoc false
  # `Openmaru.Ledger.create_accounts/1`. Each account is independent; results are in
  # input order. Checks: id_must_not_be_zero · exists / exists_with_different_fields ·
  # flags_are_mutually_exclusive · ledger_must_not_be_zero · code_must_not_be_zero ·
  # key_must_not_be_empty · key_exists (the key belongs to another id).

  import Bitwise

  alias Openmaru.{Ledger, Repo}
  alias Openmaru.Ledger.{CreateTransfers, Flags}

  @i32_max 2_147_483_647
  @keys [:id, :key, :ledger, :code, :flags]
  @both_limits 3

  @spec run([Ledger.account_attrs()]) :: [{:ok, :created | :exists} | {:error, atom()}]
  def run([]), do: []

  def run(accounts) when is_list(accounts) do
    inputs = Enum.map(accounts, &normalize/1)

    {:ok, results} =
      Repo.transaction(fn ->
        Ledger.lock!()
        inserted_at = Openmaru.Schema.timestamp()
        {by_id, by_key} = existing(inputs)

        {results, {_by_id, _by_key, new}} =
          Enum.map_reduce(inputs, {by_id, by_key, []}, &apply_account(&1, &2, inserted_at))

        if new != [], do: Repo.insert_all("ledger_accounts", Enum.reverse(new))
        results
      end)

    results
  end

  defp apply_account(input, {by_id, by_key, new} = acc, inserted_at) do
    case evaluate(input, by_id, by_key) do
      :create ->
        row = Map.put(input, :inserted_at, inserted_at)

        {{:ok, :created},
         {Map.put(by_id, row.id, row), Map.put(by_key, row.key, row.id), [row | new]}}

      result ->
        {result, acc}
    end
  end

  defp normalize(%{} = account) do
    case Map.keys(account) -- @keys do
      [] -> :ok
      extra -> raise ArgumentError, "unknown account fields: #{inspect(extra)}"
    end

    %{
      id:
        case CreateTransfers.uuid(account[:id], :id) do
          <<0::128>> -> nil
          raw -> raw
        end,
      key: string(account[:key]),
      ledger: integer(Map.get(account, :ledger, 1), :ledger),
      code: integer(account[:code], :code),
      flags: Flags.to_bits(:account, Map.get(account, :flags, []))
    }
  end

  defp normalize(other),
    do: raise(ArgumentError, "an account must be a map, got: #{inspect(other)}")

  defp string(nil), do: ""
  defp string(key) when is_binary(key), do: key
  defp string(key), do: raise(ArgumentError, "key must be a string, got: #{inspect(key)}")

  defp integer(nil, _field), do: 0

  defp integer(value, _field) when is_integer(value) and value >= 0 and value <= @i32_max,
    do: value

  defp integer(value, field),
    do:
      raise(
        ArgumentError,
        "#{field} must be an integer in 0..#{@i32_max}, got: #{inspect(value)}"
      )

  defp existing(inputs) do
    ids = for %{id: id} <- inputs, id, do: id
    keys = for %{key: key} <- inputs, key != "", do: key

    %{rows: rows} =
      Repo.query!(
        "SELECT id, key, ledger, code, flags FROM ledger_accounts WHERE id = ANY($1) OR key = ANY($2)",
        [ids, keys]
      )

    rows =
      Enum.map(rows, fn [id, key, ledger, code, flags] ->
        %{id: id, key: key, ledger: ledger, code: code, flags: flags}
      end)

    {Map.new(rows, &{&1.id, &1}), Map.new(rows, &{&1.key, &1.id})}
  end

  defp evaluate(%{id: nil}, _by_id, _by_key), do: {:error, :id_must_not_be_zero}

  defp evaluate(input, by_id, by_key) do
    case Map.fetch(by_id, input.id) do
      {:ok, existing} ->
        if Map.take(existing, @keys) == Map.take(input, @keys),
          do: {:ok, :exists},
          else: {:error, :exists_with_different_fields}

      :error ->
        evaluate_new(input, by_key)
    end
  end

  defp evaluate_new(input, by_key) do
    cond do
      (input.flags &&& @both_limits) == @both_limits -> {:error, :flags_are_mutually_exclusive}
      input.ledger == 0 -> {:error, :ledger_must_not_be_zero}
      input.code == 0 -> {:error, :code_must_not_be_zero}
      input.key == "" -> {:error, :key_must_not_be_empty}
      Map.has_key?(by_key, input.key) -> {:error, :key_exists}
      true -> :create
    end
  end
end
