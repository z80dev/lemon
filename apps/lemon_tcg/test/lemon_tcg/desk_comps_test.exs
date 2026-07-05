defmodule LemonTcg.DeskCompsTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Comps.Comp
  alias LemonTcg.Desk
  alias LemonTcg.MarketData.Listing
  alias LemonTcg.MarketData.Sources.Fixture, as: MarketFixture
  alias LemonTcg.Comps.Sources.Fixture, as: CompFixture
  alias LemonTcg.Risk.Policy

  defp start_desk(collection) do
    start_supervised!(
      {Desk,
       starting_cash_usd: 10_000.0,
       watchlist: [collection],
       market_opts: [source: MarketFixture, comp_source: CompFixture, fresh?: true],
       policy: %Policy{
         max_trade_usd: 5_000.0,
         max_daily_spend_usd: 8_000.0,
         min_cash_reserve_usd: 0.0
       }}
    )
  end

  test "comp lookup is grade-matched through the desk" do
    collection = "desk_comp_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)

    {:ok, matched} = Desk.comp(desk, "desk comp card #{collection} PSA 10")
    assert matched.bucket == "psa_10"
    assert matched.price_usd > 0.0
  end

  test "basis evaluates a live listing against a fixture comp" do
    collection = "desk_basis_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)
    query = "basis card #{collection} PSA 9"

    # Token asks 1 SOL ($150 at fixture FX); comp $500 in the grade_9
    # bucket → strongly positive edge.
    MarketFixture.put_listings(collection, [
      %Listing{
        venue: "fixture",
        collection: collection,
        mint: "#{collection}_mint_basis",
        name: "Basis Card PSA 9",
        price_lamports: 1_000_000_000,
        price_sol: 1.0
      }
    ])

    CompFixture.put_comp(query, %Comp{
      query: query,
      name: "Basis Card",
      prices: %{"grade_9" => 500.0},
      source: "fixture",
      as_of_ms: System.system_time(:millisecond)
    })

    {:ok, basis} = Desk.basis(desk, collection, "#{collection}_mint_basis", query)

    assert basis.token_ask_usd == 150.0
    assert basis.comp_usd == 500.0
    assert basis.comp_bucket == "grade_9"
    assert basis.verdict == "attractive"
    assert basis.edge_usd > 0.0
  end

  test "basis for an unknown mint fails cleanly" do
    collection = "desk_basis_missing_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)

    assert {:error, {:listing_not_found, "nope"}} =
             Desk.basis(desk, collection, "nope", "whatever card")
  end
end
