defmodule LemonTcg.MarketData.Sources.MagicEdenTest do
  use ExUnit.Case, async: true

  alias LemonTcg.MarketData.{Floor, Listing}
  alias LemonTcg.MarketData.Sources.MagicEden

  defp req_opts(fun) do
    [req_options: [plug: fun, retry: false]]
  end

  test "floor parses stats into a Floor struct" do
    plug = fn conn ->
      assert conn.request_path =~ "/collections/cc_vault/stats"
      Req.Test.json(conn, %{"floorPrice" => 2_500_000_000, "listedCount" => 41})
    end

    assert {:ok, %Floor{} = floor} = MagicEden.floor("cc_vault", req_opts(plug))
    assert floor.floor_lamports == 2_500_000_000
    assert floor.floor_sol == 2.5
    assert floor.listed_count == 41
    assert floor.venue == "magic_eden"
  end

  test "floor surfaces unexpected payloads as errors" do
    plug = fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end

    assert {:error, {:unexpected_response, {:stats, _}}} =
             MagicEden.floor("cc_vault", req_opts(plug))
  end

  test "listings parses and sorts asks, skipping malformed entries" do
    plug = fn conn ->
      Req.Test.json(conn, [
        %{
          "tokenMint" => "mint_b",
          "price" => 3.0,
          "seller" => "s2",
          "token" => %{"name" => "Charizard PSA 9"}
        },
        %{"tokenMint" => "mint_a", "price" => 1.5},
        %{"garbage" => true}
      ])
    end

    assert {:ok, [first, second]} = MagicEden.listings("cc_vault", req_opts(plug))
    assert %Listing{mint: "mint_a", price_lamports: 1_500_000_000} = first
    assert %Listing{mint: "mint_b", name: "Charizard PSA 9"} = second
  end

  test "http errors map to tagged tuples" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end
    assert {:error, {:http, 500, _}} = MagicEden.listings("cc_vault", req_opts(plug))

    rate_limited = fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end
    assert {:error, :rate_limited} = MagicEden.floor("cc_vault", req_opts(rate_limited))
  end

  test "sol_price_usd parses coingecko payload" do
    plug = fn conn -> Req.Test.json(conn, %{"solana" => %{"usd" => 148.32}}) end
    assert {:ok, 148.32} = MagicEden.sol_price_usd(req_opts(plug))
  end
end
