# Browse live tokenized-card markets across venues (read-only, no keys).
#
#   mix run scripts/tcg_markets_demo.exs
#
# Hits Collector Crypt (Solana, USDC) and OpenSea/Courtyard (Polygon)
# with their public APIs and prints the cheapest listings + floor for
# each. OpenSea self-provisions a free key on first call.

alias LemonTcg.MarketData

markets = [
  "collector_crypt:Pokemon",
  "collector_crypt:One Piece",
  "opensea:courtyard-nft",
  "magic_eden:collector_crypt"
]

IO.puts("== Live tokenized-card markets ==\n")

Enum.each(markets, fn market ->
  IO.puts("#{market}")

  case MarketData.floor(market, fresh?: true) do
    {:ok, floor} ->
      usd =
        case LemonTcg.Fx.floor_usd(floor, fresh?: true) do
          {:ok, u} -> "$#{u}"
          _ -> "?"
        end

      native = MarketData.Floor.native_floor(floor)
      listed = floor.listed_count || "?"
      IO.puts("  floor: #{native} #{floor.currency} (#{usd}) · #{listed} listed · #{floor.chain}")

    {:error, reason} ->
      IO.puts("  floor unavailable: #{inspect(reason)}")
  end

  case MarketData.listings(market, limit: 3, fresh?: true) do
    {:ok, listings} ->
      Enum.each(listings, fn l ->
        name = l.name || String.slice(l.mint, 0, 16) <> ".."
        IO.puts("  - #{name} — #{MarketData.Listing.native_price(l)} #{l.currency}")
      end)

    {:error, reason} ->
      IO.puts("  listings unavailable: #{inspect(reason)}")
  end

  IO.puts("")
end)
