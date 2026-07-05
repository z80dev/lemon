defmodule LemonTcg.FxTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Fx
  alias LemonTcg.MarketData.{Floor, Listing}
  alias LemonTcg.MarketData.Sources.Fixture

  test "stables convert 1:1" do
    listing = %Listing{venue: "v", collection: "c", mint: "m", price: 410.0, currency: "USDC"}
    assert {:ok, 410.0} = Fx.listing_usd(listing)
  end

  test "precomputed price_usd wins" do
    listing = %Listing{venue: "v", collection: "c", mint: "m", price_usd: 99.0, currency: "SOL"}
    assert {:ok, 99.0} = Fx.listing_usd(listing)
  end

  test "SOL converts through the market source FX" do
    listing = %Listing{
      venue: "v",
      collection: "c",
      mint: "m",
      price_sol: 2.0,
      currency: "SOL"
    }

    # Fixture FX is 150 USD/SOL.
    assert {:ok, 300.0} = Fx.listing_usd(listing, source: Fixture, fresh?: true)
  end

  test "floors convert like listings" do
    floor = %Floor{
      collection: "c",
      venue: "v",
      currency: "USDC",
      floor: 4.99,
      as_of_ms: 0
    }

    assert {:ok, 4.99} = Fx.floor_usd(floor)
  end

  test "missing price and unsupported currencies are tagged errors" do
    listing = %Listing{venue: "v", collection: "c", mint: "m", currency: "USDC"}
    assert {:error, :missing_price} = Fx.listing_usd(listing)

    weird = %Listing{venue: "v", collection: "c", mint: "m", price: 1.0, currency: "DOGE"}
    assert {:error, {:unsupported_currency, "DOGE"}} = Fx.listing_usd(weird)
  end

  test "ETH spot comes from the FX endpoint" do
    plug = fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["ids"] == "ethereum"
      Req.Test.json(conn, %{"ethereum" => %{"usd" => 2500.0}})
    end

    listing = %Listing{
      venue: "v",
      collection: "c",
      mint: "m",
      price: 0.5,
      currency: "ETH"
    }

    assert {:ok, 1250.0} =
             Fx.listing_usd(listing, req_options: [plug: plug, retry: false], fresh?: true)
  end
end
