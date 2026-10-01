defmodule Openmaru.Ledger.Flags do
  @moduledoc """
  Account and transfer flags (SPEC-03 §2): lists of atoms in Elixir, bit sets in the
  database and in the hash encoding.

  Also an `Ecto.ParameterizedType` for schema fields: `field :flags, Flags, kind: :transfer`.
  """

  use Ecto.ParameterizedType

  import Bitwise

  @account [debits_must_not_exceed_credits: 1, credits_must_not_exceed_debits: 2]
  @transfer [
    linked: 1,
    pending: 2,
    post_pending: 4,
    void_pending: 8,
    balancing_debit: 16,
    balancing_credit: 32
  ]

  @type kind :: :account | :transfer
  @type account_flag :: :debits_must_not_exceed_credits | :credits_must_not_exceed_debits
  @type transfer_flag ::
          :linked
          | :pending
          | :post_pending
          | :void_pending
          | :balancing_debit
          | :balancing_credit

  @doc "The bit for one flag."
  @spec bit(kind(), atom()) :: pos_integer()
  def bit(kind, flag) do
    case Keyword.fetch(table(kind), flag) do
      {:ok, bit} -> bit
      :error -> raise ArgumentError, "unknown #{kind} flag #{inspect(flag)}"
    end
  end

  @doc "Bit set for a list of flags; raises `ArgumentError` on an unknown flag."
  @spec to_bits(kind(), [atom()]) :: non_neg_integer()
  def to_bits(kind, flags) when is_list(flags),
    do: Enum.reduce(flags, 0, &(bit(kind, &1) ||| &2))

  def to_bits(kind, flags),
    do: raise(ArgumentError, "#{kind} flags must be a list, got: #{inspect(flags)}")

  @doc "Flags of a bit set, in bit order."
  @spec to_list(kind(), non_neg_integer()) :: [atom()]
  def to_list(kind, bits) when is_integer(bits),
    do: for({flag, bit} <- table(kind), (bits &&& bit) != 0, do: flag)

  defp table(:account), do: @account
  defp table(:transfer), do: @transfer

  @impl Ecto.ParameterizedType
  def init(opts), do: Keyword.fetch!(opts, :kind)

  @impl Ecto.ParameterizedType
  def type(_kind), do: :integer

  @impl Ecto.ParameterizedType
  def cast(flags, kind) when is_list(flags) do
    {:ok, to_list(kind, to_bits(kind, flags))}
  rescue
    ArgumentError -> :error
  end

  def cast(_flags, _kind), do: :error

  @impl Ecto.ParameterizedType
  def load(nil, _loader, _kind), do: {:ok, nil}
  def load(bits, _loader, kind) when is_integer(bits), do: {:ok, to_list(kind, bits)}

  @impl Ecto.ParameterizedType
  def dump(nil, _dumper, _kind), do: {:ok, nil}

  def dump(flags, _dumper, kind) when is_list(flags) do
    {:ok, to_bits(kind, flags)}
  rescue
    ArgumentError -> :error
  end

  def dump(_flags, _dumper, _kind), do: :error
end
