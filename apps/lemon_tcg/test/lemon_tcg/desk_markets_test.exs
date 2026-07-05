defmodule LemonTcg.DeskMarketsTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Desk
  alias LemonTcg.Risk.Policy

  # End-to-end desk flow against a stubbed Collector Crypt marketplace:
  # venue-qualified watchlist, USDC quotes, paper fills.

  defp cc_plug do
    fn conn ->
      assert conn.request_path == "/marketplace"

      Req.Test.json(conn, %{
        "filterNFtCard" => [
          %{
            "id" => "cc-1",
            "itemName" => "Umbreon Gold Star",
            "nftAddress" => "MintUmbreon",
            "nftStandard" => "core",
            "gradingCompany" => "CGC",
            "grade" => 9,
            "listing" => %{"price" => 320.0, "currency" => "USDC", "marketplace" => "CC"},
            "owner" => %{"wallet" => "SellerX"}
          }
        ],
        "findTotal" => 1
      })
    end
  end

  test "desk browses, paper-buys, and paper-sells a venue-qualified USDC listing" do
    collection = "collector_crypt:Pokemon"

    desk =
      start_supervised!(
        {Desk,
         starting_cash_usd: 1_000.0,
         watchlist: [collection],
         market_opts: [req_options: [plug: cc_plug(), retry: false], fresh?: true],
         policy: %Policy{
           max_trade_usd: 500.0,
           max_daily_spend_usd: 1_000.0,
           min_cash_reserve_usd: 0.0
         }}
      )

    {:ok, [listing]} = Desk.listings(desk, collection)
    assert listing.collection == collection
    assert listing.currency == "USDC"
    assert listing.name == "Umbreon Gold Star CGC 9"

    assert {:ok, fill} = Desk.buy(desk, collection, "MintUmbreon")
    assert fill.price_usd == 320.0
    assert fill.fee_usd == 6.4

    snapshot = Desk.snapshot(desk)
    assert snapshot.mark.position_count == 1
    assert snapshot.floors_usd[collection] == 320.0

    # Position keeps the qualified collection, so the paper sell resolves
    # the same market for its floor.
    assert {:ok, sell_fill} = Desk.sell(desk, "MintUmbreon")
    assert sell_fill.side == :sell
    assert sell_fill.price_usd > 0.0
    assert Desk.snapshot(desk).mark.position_count == 0
  end

  test "venue map routes fills by listing market" do
    collection = "collector_crypt:Pokemon"

    desk =
      start_supervised!(
        {Desk,
         starting_cash_usd: 1_000.0,
         watchlist: [collection],
         venue: %{:default => LemonTcg.Execution.Venues.Paper},
         market_opts: [req_options: [plug: cc_plug(), retry: false], fresh?: true],
         policy: %Policy{
           max_trade_usd: 500.0,
           max_daily_spend_usd: 1_000.0,
           min_cash_reserve_usd: 0.0
         }}
      )

    assert {:ok, fill} = Desk.buy(desk, collection, "MintUmbreon")
    assert fill.venue == "paper"
  end
end
