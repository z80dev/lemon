defmodule LemonTcg.Ledger do
  @moduledoc """
  Append-only audit trail for every cash movement on the desk.

  Entries are prepended for O(1) writes; `entries/1` returns them oldest
  first. The ledger is the source of truth for risk's daily-spend window —
  balances live on `LemonTcg.Portfolio`.
  """

  defstruct entries: []

  @type entry :: %{
          type: atom(),
          amount_usd: float(),
          at_ms: integer(),
          meta: map()
        }

  @type t :: %__MODULE__{entries: [entry()]}

  @spend_types [:buy, :fee]

  def new, do: %__MODULE__{}

  @doc "Record a movement. `amount_usd` is positive; `type` conveys direction."
  @spec record(t(), atom(), number(), map()) :: t()
  def record(%__MODULE__{} = ledger, type, amount_usd, meta \\ %{})
      when is_atom(type) and is_number(amount_usd) do
    entry = %{
      type: type,
      amount_usd: Float.round(amount_usd * 1.0, 2),
      at_ms: System.system_time(:millisecond),
      meta: meta
    }

    %{ledger | entries: [entry | ledger.entries]}
  end

  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: Enum.reverse(entries)

  @doc "USD spent on buys and fees within the trailing `window_ms` (default 24h)."
  @spec spent_within(t(), non_neg_integer()) :: float()
  def spent_within(%__MODULE__{entries: entries}, window_ms \\ 86_400_000) do
    cutoff = System.system_time(:millisecond) - window_ms

    entries
    |> Enum.take_while(&(&1.at_ms >= cutoff))
    |> Enum.filter(&(&1.type in @spend_types))
    |> Enum.reduce(0.0, &(&1.amount_usd + &2))
    |> Float.round(2)
  end
end
