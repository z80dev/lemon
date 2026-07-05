defmodule LemonTcg.MarketsTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Markets
  alias LemonTcg.MarketData.Sources.{CollectorCrypt, Fixture, MagicEden, OpenSea}

  test "qualified collections resolve to their venue source" do
    assert {CollectorCrypt, "Pokemon"} = Markets.resolve("collector_crypt:Pokemon")
    assert {OpenSea, "courtyard-nft"} = Markets.resolve("opensea:courtyard-nft")
    assert {MagicEden, "collector_crypt"} = Markets.resolve("magic_eden:collector_crypt")
    assert {Fixture, "anything"} = Markets.resolve("fixture:anything")
  end

  test "unqualified and unknown-prefix names use the default source" do
    assert {Fixture, "plain_collection"} =
             Markets.resolve("plain_collection", source: Fixture)

    assert {Fixture, "unknown:thing"} = Markets.resolve("unknown:thing", source: Fixture)
  end

  test "market data round-trips the qualified name onto results" do
    collection = "fixture:markets_roundtrip_#{System.unique_integer([:positive])}"

    {:ok, listings} = LemonTcg.MarketData.listings(collection, fresh?: true)
    assert Enum.all?(listings, &(&1.collection == collection))

    {:ok, floor} = LemonTcg.MarketData.floor(collection, fresh?: true)
    assert floor.collection == collection
  end
end
