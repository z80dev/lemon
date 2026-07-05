# Paper-trade a tokenized-card collection from the command line.
#
#   mix run scripts/tcg_live_demo.exs                    # offline fixture data
#   mix run scripts/tcg_live_demo.exs -- --live SYMBOL   # live Magic Eden quotes
#
# Live mode reads quotes from Magic Eden's public API (no key needed) but
# still fills on the paper venue — no wallet, no on-chain writes.

alias LemonTcg.Desk
alias LemonTcg.MarketData.Sources.Fixture
alias LemonTcg.Risk.Policy

{live?, collection} =
  case System.argv() do
    ["--live", symbol | _] -> {true, symbol}
    _ -> {false, "demo_vaulted_cards"}
  end

market_opts = if live?, do: [], else: [source: Fixture]

{:ok, desk} =
  Desk.start_link(
    starting_cash_usd: 2_000.0,
    watchlist: [collection],
    market_opts: market_opts,
    policy: %Policy{
      max_trade_usd: 750.0,
      max_daily_spend_usd: 1_500.0,
      min_cash_reserve_usd: 100.0,
      allowed_collections: [collection]
    }
  )

IO.puts("== TCG live desk demo (#{if live?, do: "LIVE quotes", else: "fixture quotes"}) ==")

case Desk.listings(desk, collection, 5) do
  {:ok, []} ->
    IO.puts("No live listings for #{collection}.")

  {:ok, listings} ->
    IO.puts("\nCheapest asks for #{collection}:")

    Enum.each(listings, fn l ->
      IO.puts("  #{l.mint} | #{l.name || "unnamed"} | #{l.price_sol} SOL")
    end)

    cheapest = hd(listings)

    case Desk.buy(desk, collection, cheapest.mint) do
      {:ok, fill} ->
        IO.puts("\nBought #{fill.mint} for $#{fill.price_usd} (+$#{fill.fee_usd} fee)")

        snapshot = Desk.snapshot(desk)
        IO.puts("Net worth: $#{snapshot.mark.net_worth_usd} | Cash: $#{snapshot.mark.cash_usd}")

        {:ok, sell} = Desk.sell(desk, fill.mint)
        IO.puts("Sold back at floor: $#{sell.price_usd} (-$#{sell.fee_usd} fee)")

        final = Desk.snapshot(desk)

        IO.puts(
          "Final net worth: $#{final.mark.net_worth_usd} " <>
            "(realized P&L $#{final.mark.realized_pnl_usd}, fees $#{final.mark.fees_usd})"
        )

      {:error, reason} ->
        IO.puts("\nBuy blocked: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Failed to fetch listings: #{inspect(reason)}")
end
