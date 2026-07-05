defmodule LemonTcg.Execution.Venues.Paper do
  @moduledoc """
  Paper-trading venue: real quotes, simulated fills.

  Buys fill at the listing's ask plus a taker fee. Sells fill at the
  collection's current floor minus an exit haircut (models the spread you
  give up hitting bids / accepting instant-buyback offers) minus the fee.
  Fees and haircut are basis points, tunable per desk:

    * `:taker_fee_bps` — default 200 (2%, Magic Eden-ish)
    * `:exit_haircut_bps` — default 300

  Market data flows through the same `opts` (`:source`, `:req_options`),
  so paper trading against the fixture source is fully offline.
  """

  @behaviour LemonTcg.Execution.Venue

  alias LemonTcg.Execution.Fill
  alias LemonTcg.{Fx, MarketData}
  alias LemonTcg.MarketData.Listing

  @default_taker_fee_bps 200
  @default_exit_haircut_bps 300

  @impl true
  def name, do: "paper"

  @impl true
  def buy(%Listing{} = listing, opts \\ []) do
    with {:ok, price_usd} <- Fx.listing_usd(listing, opts) do
      fee_usd = bps(price_usd, Keyword.get(opts, :taker_fee_bps, @default_taker_fee_bps))

      {:ok,
       %Fill{
         side: :buy,
         venue: name(),
         collection: listing.collection,
         mint: listing.mint,
         name: listing.name,
         price_lamports: listing.price_lamports,
         price_usd: Float.round(price_usd, 2),
         fee_usd: fee_usd,
         executed_at_ms: System.system_time(:millisecond),
         txid: "paper_buy_#{:erlang.unique_integer([:positive])}",
         meta: %{currency: listing.currency, source_venue: listing.venue}
       }}
    end
  end

  @impl true
  def sell(position, opts \\ []) do
    with {:ok, floor} <- MarketData.floor(position.collection, opts),
         {:ok, floor_usd} <- Fx.floor_usd(floor, opts) do
      haircut_bps = Keyword.get(opts, :exit_haircut_bps, @default_exit_haircut_bps)
      price_usd = Float.round(floor_usd * (1.0 - haircut_bps / 10_000), 2)
      fee_usd = bps(price_usd, Keyword.get(opts, :taker_fee_bps, @default_taker_fee_bps))

      {:ok,
       %Fill{
         side: :sell,
         venue: name(),
         collection: position.collection,
         mint: position.mint,
         name: position.name,
         price_lamports: floor.floor_lamports,
         price_usd: price_usd,
         fee_usd: fee_usd,
         executed_at_ms: System.system_time(:millisecond),
         txid: "paper_sell_#{:erlang.unique_integer([:positive])}"
       }}
    end
  end

  defp bps(amount, bps), do: Float.round(amount * bps / 10_000, 2)
end
