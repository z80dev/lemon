defmodule LemonTcg.MarketData.Sources.PhygitalsTest do
  use ExUnit.Case, async: true

  alias LemonTcg.MarketData.Sources.Phygitals
  alias LemonTcg.MarketData.{Floor, Listing}

  @usdc_mint "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

  defp req_opts(fun), do: [req_options: [plug: fun, retry: false]]

  defp listings_body do
    %{
      "listings" => [
        %{
          "address" => "GradedMint111",
          "name" => "2023 Charizard ex",
          "price" => "70000000000",
          "listed" => true,
          "burned" => false,
          "owner" => "SellerOne",
          "currency" => @usdc_mint,
          "marketplace" => "TENSOR",
          "token_standard" => "CORE_NFT",
          "collection_address" => "BSG6DyEihFFtfvxtL9mKYsvTwiZXB1rq5gARMTJC2xAM",
          "metadata" => [
            %{"key" => "Grade", "value" => "CGC 10.0"},
            %{"key" => "Grader", "value" => "CGC"}
          ]
        },
        %{
          "address" => "RawMint222",
          "name" => "2021 Phoebe Battle Styles #130",
          "price" => "290000",
          "lastSale" => "740000",
          "listed" => true,
          "burned" => false,
          "owner" => "SellerTwo",
          "currency" => @usdc_mint,
          "marketplace" => "MAGICEDEN",
          "token_standard" => "CNFT",
          "metadata" => [%{"key" => "Grade", "value" => "Ungraded"}]
        },
        %{
          "address" => "SentinelMint333",
          "name" => "Fake-Listed Card",
          "price" => "10000000000000",
          "listed" => true,
          "burned" => false,
          "currency" => @usdc_mint,
          "marketplace" => "TENSOR"
        },
        %{
          "address" => "BurnedMint444",
          "name" => "Redeemed Card",
          "price" => "500000",
          "listed" => true,
          "burned" => true,
          "currency" => @usdc_mint
        },
        %{
          "address" => "DelistedMint555",
          "name" => "Delisted Card",
          "price" => "500000",
          "listed" => false,
          "currency" => @usdc_mint
        }
      ],
      "amount" => 275
    }
  end

  test "listings parse micro-USDC strings, fold grades, drop sentinel/burned/delisted rows" do
    plug = fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["searchTerm"] == "charizard"
      assert params["sortBy"] == "price-low-high"
      assert params["listedStatus"] == "listed"
      Req.Test.json(conn, listings_body())
    end

    assert {:ok, [raw_listing, graded_listing]} =
             Phygitals.listings("charizard", req_opts(plug))

    assert %Listing{
             venue: "phygitals",
             chain: :solana,
             mint: "RawMint222",
             currency: "USDC",
             price: 0.29,
             price_usd: 0.29,
             seller: "SellerTwo"
           } = raw_listing

    # Ungraded rows keep the bare name.
    assert raw_listing.name == "2021 Phoebe Battle Styles #130"

    assert %Listing{mint: "GradedMint111", price_usd: 70_000.0} = graded_listing
    # The Grade trait row is folded into the display name for comps.
    assert graded_listing.name == "2023 Charizard ex CGC 10.0"
    # The executing venue survives in raw for buy routing (Tensor/ME).
    assert graded_listing.raw["marketplace"] == "TENSOR"
    assert graded_listing.raw["token_standard"] == "CORE_NFT"
  end

  test "the all pseudo-collection sends an empty search term" do
    plug = fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["searchTerm"] == ""
      Req.Test.json(conn, listings_body())
    end

    assert {:ok, _listings} = Phygitals.listings("all", req_opts(plug))
  end

  test "floor derives from the cheapest listing with the query's server-side total" do
    plug = fn conn -> Req.Test.json(conn, listings_body()) end

    assert {:ok, %Floor{} = floor} = Phygitals.floor("charizard", req_opts(plug))
    assert floor.venue == "phygitals"
    assert floor.currency == "USDC"
    assert floor.floor == 0.29
    assert floor.floor_usd == 0.29
    # Unlike Collector Crypt's findTotal, amount is computed per query.
    assert floor.listed_count == 275
  end

  test "non-USDC currencies are skipped rather than misdecimaled" do
    body = %{
      "listings" => [
        %{
          "address" => "WeirdMint",
          "name" => "Odd Currency",
          "price" => "1000000",
          "listed" => true,
          "currency" => "SomeOtherMint111111111111111111111111111111"
        }
      ],
      "amount" => 1
    }

    plug = fn conn -> Req.Test.json(conn, body) end

    assert {:ok, []} = Phygitals.listings("all", req_opts(plug))
    assert {:error, {:no_listings, "all"}} = Phygitals.floor("all", req_opts(plug))
  end

  test "http failures surface as tagged errors" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end
    assert {:error, :rate_limited} = Phygitals.listings("all", req_opts(plug))
  end
end
