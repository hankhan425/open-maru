defmodule Openmaru.Ledger.Rules do
  @moduledoc false
  # The pure core of `Openmaru.Ledger.create_transfers/1` (SPEC-03 §4): validates and
  # applies a batch against an in-memory state loaded under the ledger lock, so a failed
  # linked chain is undone by discarding its state. `Openmaru.Ledger.CreateTransfers`
  # loads the state and writes the outcome.
  #
  # Inputs and rows use 16-byte binary UUIDs and integer flag bits (database form).

  import Bitwise

  alias Openmaru.Ledger
  alias Openmaru.Ledger.Chain

  @i64_max 9_223_372_036_854_775_807
  @micros_per_sec 1_000_000

  @linked 1
  @pending 2
  @post 4
  @void 8
  @balancing_debit 16
  @balancing_credit 32
  @resolution @post ||| @void
  @balancing @balancing_debit ||| @balancing_credit

  @dmnec 1
  @cmned 2

  @type uuid :: <<_::128>>

  @type input :: %{
          id: uuid() | nil,
          debit_account_id: uuid() | nil,
          credit_account_id: uuid() | nil,
          amount: non_neg_integer() | nil,
          pending_id: uuid() | nil,
          flags: non_neg_integer(),
          timeout_secs: non_neg_integer(),
          code: non_neg_integer() | nil,
          user_data_128: uuid() | nil,
          user_data_64: integer() | nil
        }

  @type account :: %{
          id: uuid(),
          ledger: pos_integer(),
          flags: non_neg_integer(),
          debits_pending: non_neg_integer(),
          debits_posted: non_neg_integer(),
          credits_pending: non_neg_integer(),
          credits_posted: non_neg_integer()
        }

  @type row :: %{atom() => term()}

  @type state :: %{
          accounts: %{uuid() => account()},
          transfers: %{uuid() => row()},
          resolutions: %{uuid() => row()},
          seq: non_neg_integer(),
          timestamp: integer(),
          hash: <<_::256>>,
          now: integer(),
          expiry?: boolean(),
          created: [row()],
          dirty: MapSet.t(uuid()),
          expiries: %{uuid() => {:add, integer()} | :remove}
        }

  @type result :: {:ok, :created | :exists} | {:error, atom()}

  @doc "A fresh state over what was loaded; `now` is the Clock in microseconds."
  @spec new_state(map()) :: state()
  def new_state(loaded) do
    Map.merge(
      %{
        accounts: %{},
        transfers: %{},
        resolutions: %{},
        seq: 0,
        timestamp: 0,
        hash: Chain.genesis(),
        expiry?: false,
        created: [],
        dirty: MapSet.new(),
        expiries: %{}
      },
      loaded
    )
  end

  @doc "Applies a batch; results are in input order."
  @spec apply_batch([input()], state()) :: {[result()], state()}
  def apply_batch(inputs, state) do
    {chains, open} = split_chains(inputs)

    {results, state} =
      Enum.reduce(chains, {[], state}, fn chain, {acc, st} ->
        {chain_results, st} = apply_chain(chain, st)
        {Enum.reverse(chain_results, acc), st}
      end)

    {Enum.reverse(results, List.duplicate({:error, :linked_event_chain_open}, length(open))),
     state}
  end

  # A chain ends at the first transfer without `linked`; what is left at the end is open.
  defp split_chains(inputs) do
    {chains, current} =
      Enum.reduce(inputs, {[], []}, fn input, {chains, current} ->
        current = [input | current]

        if (input.flags &&& @linked) != 0,
          do: {chains, current},
          else: {[Enum.reverse(current) | chains], []}
      end)

    {Enum.reverse(chains), Enum.reverse(current)}
  end

  defp apply_chain(members, state) do
    members
    |> Enum.with_index()
    |> Enum.reduce_while({[], state}, fn {input, index}, {acc, st} ->
      case evaluate(input, st) do
        {:created, st} -> {:cont, {[{:ok, :created} | acc], st}}
        {:exists, st} -> {:cont, {[{:ok, :exists} | acc], st}}
        {:error, code} -> {:halt, {:failed, index, code}}
      end
    end)
    |> case do
      {:failed, failed, code} -> {failed_chain(length(members), failed, code), state}
      {results, state} -> {Enum.reverse(results), state}
    end
  end

  # The failing member keeps its code; the rest of the chain is linked_event_failed.
  defp failed_chain(size, failed, code) do
    for index <- 0..(size - 1)//1 do
      if index == failed, do: {:error, code}, else: {:error, :linked_event_failed}
    end
  end

  # SPEC-03 §4.2: the first failing check wins.
  defp evaluate(input, st) do
    with :ok <- check_id(input),
         :new <- check_exists(input, st),
         :ok <- check_flags(input.flags),
         :ok <- check_pending_id(input),
         :ok <- check_code(input),
         :ok <- check_accounts_different(input),
         {:ok, dr} <- fetch_account(input, :debit_account_id, :debit_account_not_found, st),
         {:ok, cr} <- fetch_account(input, :credit_account_id, :credit_account_not_found, st),
         :ok <- check_same_ledger(dr, cr),
         :ok <- check_amount(input),
         :ok <- check_timeout(input),
         {:ok, row, accounts, expiry} <- build(input, dr, cr, st) do
      {:created, commit(row, accounts, expiry, st)}
    else
      :exists -> {:exists, st}
      {:error, _code} = error -> error
    end
  end

  defp check_id(%{id: nil}), do: {:error, :id_must_not_be_zero}
  defp check_id(_input), do: :ok

  defp check_exists(input, st) do
    case Map.fetch(st.transfers, input.id) do
      :error ->
        :new

      {:ok, existing} ->
        if same?(input, existing, st), do: :exists, else: {:error, :exists_with_different_fields}
    end
  end

  # Compares what the input would store with the stored row. Omitted post/void fields
  # mean "from the pending transfer"; a balancing request compares with requested_amount.
  defp same?(input, e, st) do
    input.flags == e.flags and input.pending_id == e.pending_id and
      input.timeout_secs == e.timeout_secs and
      effective(input, st) == Map.take(e, effective_keys())
  end

  defp effective_keys,
    do: [
      :debit_account_id,
      :credit_account_id,
      :requested_amount,
      :code,
      :user_data_128,
      :user_data_64
    ]

  defp effective(%{flags: flags} = input, st) when (flags &&& @resolution) != 0 do
    p = Map.fetch!(st.transfers, input.pending_id)

    %{
      debit_account_id: input.debit_account_id || p.debit_account_id,
      credit_account_id: input.credit_account_id || p.credit_account_id,
      requested_amount: input.amount || p.amount,
      code: input.code || p.code,
      user_data_128: input.user_data_128 || p.user_data_128,
      user_data_64: inherit(input.user_data_64, p.user_data_64)
    }
  end

  defp effective(input, _st) do
    input
    |> Map.take(effective_keys())
    |> Map.put(:requested_amount, input.amount || 0)
  end

  defp inherit(nil, pending_value), do: pending_value
  defp inherit(value, _pending_value), do: value

  defp check_flags(flags) do
    resolution = flags &&& @resolution

    cond do
      resolution == @resolution ->
        {:error, :flags_are_mutually_exclusive}

      resolution != 0 and (flags &&& (@pending ||| @balancing)) != 0 ->
        {:error, :flags_are_mutually_exclusive}

      true ->
        :ok
    end
  end

  defp check_pending_id(%{flags: flags} = input) when (flags &&& @resolution) != 0 do
    cond do
      is_nil(input.pending_id) -> {:error, :pending_id_must_not_be_zero}
      input.pending_id == input.id -> {:error, :pending_id_must_be_different}
      true -> :ok
    end
  end

  defp check_pending_id(%{pending_id: nil}), do: :ok
  defp check_pending_id(_input), do: {:error, :pending_id_must_be_zero}

  # Posts and voids may omit the code (it comes from the pending transfer).
  defp check_code(%{code: nil, flags: flags}) when (flags &&& @resolution) != 0, do: :ok
  defp check_code(%{code: code}) when is_integer(code) and code > 0, do: :ok
  defp check_code(_input), do: {:error, :code_must_not_be_zero}

  defp check_accounts_different(%{debit_account_id: id, credit_account_id: id})
       when not is_nil(id),
       do: {:error, :accounts_must_be_different}

  defp check_accounts_different(_input), do: :ok

  # An omitted account on a post or void comes from the pending transfer.
  defp fetch_account(input, key, missing, st) do
    case Map.fetch!(input, key) do
      nil when (input.flags &&& @resolution) != 0 -> {:ok, nil}
      nil -> {:error, missing}
      id -> with :error <- Map.fetch(st.accounts, id), do: {:error, missing}
    end
  end

  defp check_same_ledger(%{ledger: a}, %{ledger: b}) when a != b,
    do: {:error, :accounts_must_have_the_same_ledger}

  defp check_same_ledger(_dr, _cr), do: :ok

  # Zero is allowed for posts (SPEC-03 §4.3), balancing transfers (§4.5) and omitted
  # void amounts.
  defp check_amount(%{flags: flags}) when (flags &&& (@post ||| @balancing)) != 0, do: :ok
  defp check_amount(%{flags: flags, amount: nil}) when (flags &&& @void) != 0, do: :ok
  defp check_amount(%{amount: amount}) when is_integer(amount) and amount > 0, do: :ok
  defp check_amount(_input), do: {:error, :amount_must_not_be_zero}

  defp check_timeout(%{timeout_secs: timeout, flags: flags})
       when timeout > 0 and (flags &&& @pending) == 0,
       do: {:error, :timeout_reserved_for_pending_transfer}

  defp check_timeout(_input), do: :ok

  defp build(%{flags: flags} = input, _dr, _cr, st) when (flags &&& @resolution) != 0,
    do: resolve(input, st)

  defp build(input, dr, cr, st), do: transfer(input, dr, cr, st)

  defp transfer(input, dr, cr, st) do
    requested = input.amount || 0
    amount = requested |> balance_debit(input.flags, dr) |> balance_credit(input.flags, cr)
    pending? = (input.flags &&& @pending) != 0

    with :ok <- check_overflow(dr, cr, amount, pending?),
         :ok <- check_exceeds_credits(dr, amount),
         :ok <- check_exceeds_debits(cr, amount) do
      {dr, cr} =
        if pending?,
          do: {add(dr, :debits_pending, amount), add(cr, :credits_pending, amount)},
          else: {add(dr, :debits_posted, amount), add(cr, :credits_posted, amount)}

      row = %{
        id: input.id,
        debit_account_id: dr.id,
        credit_account_id: cr.id,
        amount: amount,
        requested_amount: requested,
        pending_id: nil,
        flags: input.flags,
        timeout_secs: input.timeout_secs,
        ledger: dr.ledger,
        code: input.code,
        user_data_128: input.user_data_128,
        user_data_64: input.user_data_64
      }

      expiry =
        if pending? and input.timeout_secs > 0,
          do: {:add, input.id, next_timestamp(st) + input.timeout_secs * @micros_per_sec}

      {:ok, row, [dr, cr], expiry}
    end
  end

  # SPEC-03 §4.5: available = credits_posted − debits_posted − debits_pending (never < 0).
  defp balance_debit(amount, flags, dr) when (flags &&& @balancing_debit) != 0,
    do: min(amount, max(dr.credits_posted - dr.debits_posted - dr.debits_pending, 0))

  defp balance_debit(amount, _flags, _dr), do: amount

  defp balance_credit(amount, flags, cr) when (flags &&& @balancing_credit) != 0,
    do: min(amount, max(cr.debits_posted - cr.credits_posted - cr.credits_pending, 0))

  defp balance_credit(amount, _flags, _cr), do: amount

  defp check_overflow(dr, cr, amount, pending?) do
    {debit_column, credit_column} =
      if pending?,
        do: {:debits_pending, :credits_pending},
        else: {:debits_posted, :credits_posted}

    if Map.fetch!(dr, debit_column) + amount > @i64_max or
         Map.fetch!(cr, credit_column) + amount > @i64_max or
         dr.debits_pending + dr.debits_posted + amount > @i64_max or
         cr.credits_pending + cr.credits_posted + amount > @i64_max,
       do: {:error, :overflows},
       else: :ok
  end

  defp check_exceeds_credits(%{flags: flags} = dr, amount) when (flags &&& @dmnec) != 0 do
    if dr.debits_pending + dr.debits_posted + amount > dr.credits_posted,
      do: {:error, :exceeds_credits},
      else: :ok
  end

  defp check_exceeds_credits(_dr, _amount), do: :ok

  defp check_exceeds_debits(%{flags: flags} = cr, amount) when (flags &&& @cmned) != 0 do
    if cr.credits_pending + cr.credits_posted + amount > cr.debits_posted,
      do: {:error, :exceeds_debits},
      else: :ok
  end

  defp check_exceeds_debits(_cr, _amount), do: :ok

  # SPEC-03 §4.3: post or void a pending transfer.
  defp resolve(input, st) do
    post? = (input.flags &&& @post) != 0

    with {:ok, p} <- fetch_pending(input.pending_id, st),
         :ok <- check_matches_pending(input, p),
         :ok <- check_pending_amount(input, p, post?),
         :ok <- check_pending_status(p, st),
         :ok <- check_expired(p, st) do
      amount = if post?, do: input.amount || p.amount, else: p.amount
      dr = Map.fetch!(st.accounts, p.debit_account_id)
      cr = Map.fetch!(st.accounts, p.credit_account_id)

      if post? and
           (dr.debits_posted + amount > @i64_max or cr.credits_posted + amount > @i64_max),
         do: {:error, :overflows},
         else: settle(input, p, amount, post?, dr, cr)
    end
  end

  # Releases the pending amount and, for a post, adds the posted amount.
  defp settle(input, p, amount, post?, dr, cr) do
    dr = add(dr, :debits_pending, -p.amount)
    cr = add(cr, :credits_pending, -p.amount)
    posted = if post?, do: amount, else: 0

    row = %{
      id: input.id,
      debit_account_id: p.debit_account_id,
      credit_account_id: p.credit_account_id,
      amount: amount,
      requested_amount: amount,
      pending_id: p.id,
      flags: input.flags,
      timeout_secs: 0,
      ledger: p.ledger,
      code: p.code,
      user_data_128: input.user_data_128 || p.user_data_128,
      user_data_64: inherit(input.user_data_64, p.user_data_64)
    }

    expiry = if p.timeout_secs > 0, do: {:remove, p.id}
    {:ok, row, [add(dr, :debits_posted, posted), add(cr, :credits_posted, posted)], expiry}
  end

  defp fetch_pending(pending_id, st) do
    case Map.fetch(st.transfers, pending_id) do
      :error ->
        {:error, :pending_transfer_not_found}

      {:ok, %{flags: flags}} when (flags &&& @pending) == 0 ->
        {:error, :pending_transfer_not_pending}

      {:ok, p} ->
        {:ok, p}
    end
  end

  defp check_matches_pending(input, p) do
    cond do
      input.debit_account_id not in [nil, p.debit_account_id] ->
        {:error, :pending_transfer_has_different_debit_account_id}

      input.credit_account_id not in [nil, p.credit_account_id] ->
        {:error, :pending_transfer_has_different_credit_account_id}

      input.code not in [nil, p.code] ->
        {:error, :pending_transfer_has_different_code}

      true ->
        :ok
    end
  end

  defp check_pending_amount(%{amount: amount}, p, true = _post?)
       when is_integer(amount) and amount > p.amount,
       do: {:error, :exceeds_pending_transfer_amount}

  defp check_pending_amount(%{amount: amount}, p, false = _post?)
       when is_integer(amount) and amount != p.amount,
       do: {:error, :pending_transfer_has_different_amount}

  defp check_pending_amount(_input, _p, _post?), do: :ok

  defp check_pending_status(p, st) do
    case Map.fetch(st.resolutions, p.id) do
      :error ->
        :ok

      {:ok, %{flags: flags}} when (flags &&& @post) != 0 ->
        {:error, :pending_transfer_already_posted}

      {:ok, resolution} ->
        if expiry?(resolution, p),
          do: {:error, :pending_transfer_expired},
          else: {:error, :pending_transfer_already_voided}
    end
  end

  # The sweeper's void: deterministic id and user_data_64 = -1 (SPEC-03 §4.3).
  defp expiry?(resolution, p) do
    resolution.user_data_64 == -1 and resolution.id == expiry_id(p.id)
  end

  @doc "The id of the sweeper's void for a pending transfer (binary form)."
  @spec expiry_id(uuid()) :: uuid()
  def expiry_id(pending_id),
    do: Ecto.UUID.dump!(Ledger.uuidv5("expire:" <> Ecto.UUID.load!(pending_id)))

  # Only the sweeper may resolve a pending transfer at or after its expiry.
  defp check_expired(_p, %{expiry?: true}), do: :ok

  defp check_expired(%{timeout_secs: timeout} = p, st) when timeout > 0 do
    if p.timestamp + timeout * @micros_per_sec <= next_timestamp(st),
      do: {:error, :pending_transfer_expired},
      else: :ok
  end

  defp check_expired(_p, _st), do: :ok

  defp add(account, column, delta), do: Map.update!(account, column, &(&1 + delta))

  # Strictly increasing even when the Clock repeats or goes back.
  defp next_timestamp(st), do: max(st.now, st.timestamp + 1)

  defp commit(row, accounts, expiry, st) do
    timestamp = next_timestamp(st)
    row = Map.merge(row, %{timestamp: timestamp, seq: st.seq + 1, prev_hash: st.hash})
    row = Map.put(row, :hash, Chain.hash(st.hash, row))

    %{
      st
      | accounts: Enum.reduce(accounts, st.accounts, &Map.put(&2, &1.id, &1)),
        dirty: Enum.reduce(accounts, st.dirty, &MapSet.put(&2, &1.id)),
        transfers: Map.put(st.transfers, row.id, row),
        resolutions:
          if(row.pending_id,
            do: Map.put(st.resolutions, row.pending_id, row),
            else: st.resolutions
          ),
        seq: row.seq,
        timestamp: timestamp,
        hash: row.hash,
        created: [row | st.created],
        expiries: track_expiry(st.expiries, expiry)
    }
  end

  defp track_expiry(expiries, nil), do: expiries
  defp track_expiry(expiries, {:add, id, at}), do: Map.put(expiries, id, {:add, at})

  # A pending created and resolved in the same batch never reaches the table.
  defp track_expiry(expiries, {:remove, id}) do
    case Map.fetch(expiries, id) do
      {:ok, {:add, _at}} -> Map.delete(expiries, id)
      _ -> Map.put(expiries, id, :remove)
    end
  end
end
