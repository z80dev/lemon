defmodule LemonTcg.Portfolio do
  @moduledoc """
  Cash, positions, and P&L for one trading desk session.

  Positions are one-of-one tokens (tokenized graded cards), keyed by mint.
  All valuation is USD; lamports amounts ride along in position metadata
  for on-chain settlement later.
  """

  alias LemonTcg.Execution.Fill
  alias LemonTcg.Ledger

  defstruct cash_usd: 0.0,
            positions: %{},
            realized_pnl_usd: 0.0,
            fees_usd: 0.0,
            ledger: nil

  @type position :: %{
          mint: String.t(),
          collection: String.t(),
          name: String.t() | nil,
          cost_basis_usd: float(),
          acquired_at_ms: integer(),
          venue: String.t(),
          meta: map()
        }

  @type t :: %__MODULE__{
          cash_usd: float(),
          positions: %{String.t() => position()},
          realized_pnl_usd: float(),
          fees_usd: float(),
          ledger: Ledger.t()
        }

  @spec new(number()) :: t()
  def new(starting_cash_usd) when is_number(starting_cash_usd) do
    ledger = Ledger.record(Ledger.new(), :deposit, starting_cash_usd, %{source: "initial"})
    %__MODULE__{cash_usd: Float.round(starting_cash_usd * 1.0, 2), ledger: ledger}
  end

  @spec apply_buy(t(), Fill.t()) :: {:ok, t()} | {:error, term()}
  def apply_buy(%__MODULE__{} = portfolio, %Fill{side: :buy} = fill) do
    total = Float.round(fill.price_usd + fill.fee_usd, 2)

    cond do
      Map.has_key?(portfolio.positions, fill.mint) ->
        {:error, {:already_holding, fill.mint}}

      total > portfolio.cash_usd ->
        {:error, {:insufficient_cash, total, portfolio.cash_usd}}

      true ->
        position = %{
          mint: fill.mint,
          collection: fill.collection,
          name: fill.name,
          cost_basis_usd: fill.price_usd,
          acquired_at_ms: fill.executed_at_ms,
          venue: fill.venue,
          meta: fill.meta || %{}
        }

        ledger =
          portfolio.ledger
          |> Ledger.record(:buy, fill.price_usd, fill_meta(fill))
          |> record_fee(fill)

        {:ok,
         %{
           portfolio
           | cash_usd: Float.round(portfolio.cash_usd - total, 2),
             positions: Map.put(portfolio.positions, fill.mint, position),
             fees_usd: Float.round(portfolio.fees_usd + fill.fee_usd, 2),
             ledger: ledger
         }}
    end
  end

  @spec apply_sell(t(), Fill.t()) :: {:ok, t()} | {:error, term()}
  def apply_sell(%__MODULE__{} = portfolio, %Fill{side: :sell} = fill) do
    case Map.fetch(portfolio.positions, fill.mint) do
      :error ->
        {:error, {:not_holding, fill.mint}}

      {:ok, position} ->
        proceeds = Float.round(fill.price_usd - fill.fee_usd, 2)
        realized = Float.round(proceeds - position.cost_basis_usd, 2)

        ledger =
          portfolio.ledger
          |> Ledger.record(:sell, fill.price_usd, fill_meta(fill))
          |> record_fee(fill)

        {:ok,
         %{
           portfolio
           | cash_usd: Float.round(portfolio.cash_usd + proceeds, 2),
             positions: Map.delete(portfolio.positions, fill.mint),
             realized_pnl_usd: Float.round(portfolio.realized_pnl_usd + realized, 2),
             fees_usd: Float.round(portfolio.fees_usd + fill.fee_usd, 2),
             ledger: ledger
         }}
    end
  end

  @doc """
  Net worth marked against per-collection floor prices in USD.

  Positions in collections missing from `floors_usd` fall back to cost
  basis and are reported so the caller can see how much of the mark is
  unpriced.
  """
  @spec mark_to_market(t(), %{String.t() => number()}) :: map()
  def mark_to_market(%__MODULE__{} = portfolio, floors_usd \\ %{}) do
    {inventory_value, unpriced} =
      Enum.reduce(portfolio.positions, {0.0, 0}, fn {_mint, position}, {value, unpriced} ->
        case Map.get(floors_usd, position.collection) do
          nil -> {value + position.cost_basis_usd, unpriced + 1}
          floor_usd -> {value + floor_usd * 1.0, unpriced}
        end
      end)

    cost_basis = total_cost_basis(portfolio)

    %{
      cash_usd: portfolio.cash_usd,
      inventory_value_usd: Float.round(inventory_value, 2),
      inventory_cost_basis_usd: cost_basis,
      net_worth_usd: Float.round(portfolio.cash_usd + inventory_value, 2),
      unrealized_pnl_usd: Float.round(inventory_value - cost_basis, 2),
      realized_pnl_usd: portfolio.realized_pnl_usd,
      fees_usd: portfolio.fees_usd,
      position_count: map_size(portfolio.positions),
      unpriced_positions: unpriced
    }
  end

  @spec total_cost_basis(t()) :: float()
  def total_cost_basis(%__MODULE__{positions: positions}) do
    positions
    |> Enum.reduce(0.0, fn {_mint, position}, acc -> acc + position.cost_basis_usd end)
    |> Float.round(2)
  end

  defp record_fee(ledger, %Fill{fee_usd: fee} = fill) when fee > 0.0 do
    Ledger.record(ledger, :fee, fee, fill_meta(fill))
  end

  defp record_fee(ledger, _fill), do: ledger

  defp fill_meta(%Fill{} = fill) do
    %{mint: fill.mint, collection: fill.collection, venue: fill.venue, side: fill.side}
  end
end
