defmodule LemonTcg.MarketData.Sources.OpenSeaTest do
  use ExUnit.Case, async: true

  alias LemonTcg.MarketData.Sources.OpenSea
  alias LemonTcg.MarketData.{Floor, Listing}

  defp req_opts(fun) do
    [req_options: [plug: fun, retry: false], opensea_api_key: "test-key"]
  end

  test "stats parse into a USDC floor" do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      assert conn.request_path =~ "/collections/courtyard-nft/stats"

      Req.Test.json(conn, %{
        "total" => %{"floor_price" => 4.99, "floor_price_symbol" => "USDC"}
      })
    end

    assert {:ok, %Floor{} = floor} = OpenSea.floor("courtyard-nft", req_opts(plug))
    assert floor.currency == "USDC"
    assert floor.floor == 4.99
    assert floor.floor_usd == 4.99
    assert floor.chain == :evm
  end

  test "listings parse Seaport orders into contract:token_id listings" do
    plug = fn conn ->
      Req.Test.json(conn, %{
        "listings" => [
          %{
            "order_hash" => "0xhash",
            "chain" => "matic",
            "price" => %{
              "current" => %{"currency" => "USDC", "decimals" => 6, "value" => "5115000"}
            },
            "protocol_data" => %{
              "parameters" => %{
                "offerer" => "0xseller",
                "offer" => [
                  %{"token" => "0xcontract", "identifierOrCriteria" => "9876"}
                ]
              }
            }
          },
          %{"malformed" => true}
        ]
      })
    end

    assert {:ok, [listing]} = OpenSea.listings("courtyard-nft", req_opts(plug))

    assert %Listing{
             venue: "opensea",
             chain: :polygon,
             mint: "0xcontract:9876",
             currency: "USDC",
             price_usd: 5.12,
             seller: "0xseller"
           } = listing

    assert_in_delta listing.price, 5.115, 0.0001
  end

  test "self-provisions a key when none is configured" do
    plug = fn conn ->
      case conn.request_path do
        "/api/v2/auth/keys" ->
          assert conn.method == "POST"
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"api_key" => "minted-key"})

        path ->
          assert path =~ "/stats"
          assert Plug.Conn.get_req_header(conn, "x-api-key") == ["minted-key"]
          Req.Test.json(conn, %{"total" => %{"floor_price" => 1.0}})
      end
    end

    opts = [
      req_options: [plug: plug, retry: false],
      opensea_base_url: "https://opensea.test/api/v2"
    ]

    assert {:ok, %Floor{floor: 1.0}} = OpenSea.floor("some-slug", opts)
  end

  test "unauthorized surfaces cleanly" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end
    assert {:error, :opensea_unauthorized} = OpenSea.floor("courtyard-nft", req_opts(plug))
  end
end
