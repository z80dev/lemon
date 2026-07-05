defmodule LemonTcg.MarketData.Sources.CollectorCryptTest do
  use ExUnit.Case, async: true

  alias LemonTcg.MarketData.Sources.CollectorCrypt
  alias LemonTcg.MarketData.{Floor, Listing}

  defp req_opts(fun), do: [req_options: [plug: fun, retry: false]]

  defp marketplace_body do
    %{
      "filterNFtCard" => [
        %{
          "id" => "cc-card-2",
          "itemName" => "Charizard Base Set",
          "nftAddress" => "MintTwo222",
          "nftStandard" => "core",
          "category" => "Pokemon",
          "gradingCompany" => "PSA",
          "grade" => 9,
          "listing" => %{"price" => 410.0, "currency" => "USDC", "marketplace" => "CC"},
          "owner" => %{"wallet" => "SellerTwo"}
        },
        %{
          "id" => "cc-card-1",
          "itemName" => "Pikachu Jungle PSA 8",
          "nftAddress" => "MintOne111",
          "nftStandard" => "pnft",
          "gradingCompany" => "PSA",
          "grade" => "NM-MT 8",
          "listing" => %{"price" => 0.55, "currency" => "SOL", "marketplace" => "ME"},
          "owner" => %{"wallet" => "SellerOne"}
        },
        %{
          "id" => "cc-card-unlisted",
          "itemName" => "Unlisted Card",
          "nftAddress" => "MintNone",
          "listing" => nil
        }
      ],
      "findTotal" => 1234,
      "totalPages" => 13
    }
  end

  test "listings parse USDC and SOL asks, skip unlisted cards, sort by USD" do
    plug = fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["orderBy"] == "listedPriceAsc"
      assert params["categories"] == "Pokemon"
      Req.Test.json(conn, marketplace_body())
    end

    assert {:ok, [sol_listing, usdc_listing]} =
             CollectorCrypt.listings("Pokemon", req_opts(plug))

    assert %Listing{
             venue: "collector_crypt",
             chain: :solana,
             mint: "MintOne111",
             currency: "SOL",
             price: 0.55,
             price_lamports: 550_000_000,
             price_usd: nil
           } = sol_listing

    assert %Listing{mint: "MintTwo222", currency: "USDC", price_usd: 410.0} = usdc_listing
    # Grading metadata is folded into the display name for comps.
    assert usdc_listing.name == "Charizard Base Set PSA 9"
    # Live itemNames already carrying the grader ("... PSA 8") stay untouched
    # even though CC's grade field is the descriptive "NM-MT 8".
    assert sol_listing.name == "Pikachu Jungle PSA 8"
    # The CC card id survives in raw for the sell/list flow.
    assert usdc_listing.raw["id"] == "cc-card-2"
  end

  test "the all pseudo-collection drops the category filter" do
    plug = fn conn ->
      params = URI.decode_query(conn.query_string)
      refute Map.has_key?(params, "categories")
      Req.Test.json(conn, marketplace_body())
    end

    assert {:ok, _listings} = CollectorCrypt.listings("all", req_opts(plug))
  end

  test "floor derives from the cheapest listing; filtered queries drop the stale total" do
    plug = fn conn -> Req.Test.json(conn, marketplace_body()) end

    assert {:ok, %Floor{} = floor} = CollectorCrypt.floor("Pokemon", req_opts(plug))
    assert floor.currency == "SOL"
    assert floor.floor == 0.55
    # findTotal is not category-accurate, so filtered floors report no count.
    assert floor.listed_count == nil
  end

  test "the unfiltered marketplace keeps findTotal as the listed count" do
    plug = fn conn -> Req.Test.json(conn, marketplace_body()) end

    assert {:ok, %Floor{listed_count: 1234}} = CollectorCrypt.floor("all", req_opts(plug))
  end

  test "http failures surface as tagged errors" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end
    assert {:error, :rate_limited} = CollectorCrypt.listings("Pokemon", req_opts(plug))
  end
end
