defmodule LemonTcg.Execution.Venues.OpenSeaTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Execution.Fill
  alias LemonTcg.Execution.Venues.OpenSea, as: Venue
  alias LemonTcg.MarketData.Listing
  alias LemonTcg.Wallet.EvmKeypair

  @priv :binary.copy(<<0x46>>, 32)

  defp listing do
    %Listing{
      venue: "opensea",
      chain: :polygon,
      collection: "opensea:courtyard-nft",
      mint: "0xcontract:9876",
      name: "Courtyard card",
      price: 5.11,
      currency: "USDC",
      price_usd: 5.11,
      raw: %{
        "order_hash" => "0xhash",
        "chain" => "polygon",
        "protocol_address" => "0x0000000000000068f116a894984e2db1123eb395"
      }
    }
  end

  # One plug fronting both OpenSea (fulfillment) and the Eth RPC.
  defp combined_plug(rpc_result_fun) do
    fn conn ->
      case conn.request_path do
        "/api/v2/listings/fulfillment_data" ->
          Req.Test.json(conn, %{
            "fulfillment_data" => %{
              "transaction" => %{
                "to" => "0x0000000000000068f116a894984e2db1123eb395",
                "value" => 5_115_000,
                "data" => "0xdeadbeef"
              }
            }
          })

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"method" => method} = Jason.decode!(body)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => rpc_result_fun.(method)})
      end
    end
  end

  defp rpc_result("eth_chainId"), do: "0x89"
  defp rpc_result("eth_getTransactionCount"), do: "0x1"
  defp rpc_result("eth_maxPriorityFeePerGas"), do: "0x77359400"
  defp rpc_result("eth_getBlockByNumber"), do: %{"baseFeePerGas" => "0x3b9aca00"}
  defp rpc_result("eth_estimateGas"), do: "0x186a0"
  defp rpc_result("eth_sendRawTransaction"), do: "0xtxhash123"

  defp buy_opts(plug) do
    [
      wallet: {EvmKeypair, [private_key: @priv]},
      opensea_api_key: "trading-key",
      opensea_base_url: "https://os.test/api/v2",
      rpc_url: "https://rpc.test",
      req_options: [plug: plug, retry: false]
    ]
  end

  test "buy fetches fulfillment, builds+signs+broadcasts an EIP-1559 tx" do
    assert {:ok, %Fill{} = fill} =
             Venue.buy(listing(), buy_opts(combined_plug(&rpc_result/1)))

    assert fill.side == :buy
    assert fill.venue == "opensea"
    assert fill.price_usd == 5.11
    assert fill.txid == "0xtxhash123"
    assert fill.meta.chain == :polygon
  end

  test "buy fails closed without a configured wallet" do
    assert {:error, :wallet_not_configured} =
             Venue.buy(listing(), opensea_api_key: "k", opensea_base_url: "https://os.test/api/v2")
  end

  test "buy fails closed with a Solana-only wallet (no EVM address)" do
    assert {:error, :evm_wallet_required} =
             Venue.buy(listing(),
               wallet: {LemonTcg.Wallet.SolanaKeypair, [secret_key: :binary.copy(<<1>>, 64)]},
               opensea_api_key: "k",
               opensea_base_url: "https://os.test/api/v2"
             )
  end

  test "buy refuses structured fulfillment it cannot encode" do
    plug = fn conn ->
      Req.Test.json(conn, %{
        "fulfillment_data" => %{
          "transaction" => %{
            "to" => "0xabc",
            "function" => "fulfillBasicOrder_efficient_6GL6yc",
            "input_data" => %{"parameters" => %{}}
          }
        }
      })
    end

    assert {:error, {:opensea_fulfillment_shape_unsupported, _keys}} =
             Venue.buy(listing(), buy_opts(plug))
  end

  test "sell signs a caller-supplied Seaport order via EIP-712" do
    position = %{
      mint: "0xcontract:9876",
      collection: "opensea:courtyard-nft",
      name: "Courtyard card",
      cost_basis_usd: 5.0,
      acquired_at_ms: 0,
      venue: "opensea",
      meta: %{chain: :polygon}
    }

    order = %{
      hash: :binary.copy(<<0x7>>, 32),
      parameters: %{"offerer" => "0xme"},
      chain: "polygon",
      protocol_address: "0x0000000000000068f116a894984e2db1123eb395"
    }

    plug = fn conn ->
      assert conn.request_path =~ "/orders/polygon/seaport/listings"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      # 65-byte signature => 0x + 130 hex chars.
      assert String.length(decoded["signature"]) == 132
      Req.Test.json(conn, %{"order" => %{"order_hash" => "0xnew"}})
    end

    opts = [
      wallet: {EvmKeypair, [private_key: @priv]},
      opensea_api_key: "trading-key",
      opensea_base_url: "https://os.test/api/v2",
      seaport_order: order,
      list_price_usd: 12.5,
      req_options: [plug: plug, retry: false]
    ]

    assert {:ok, %Fill{side: :sell} = fill} = Venue.sell(position, opts)
    assert fill.price_usd == 12.5
  end

  test "sell fails closed without a pre-built order" do
    position = %{mint: "m", collection: "c", name: nil, venue: "opensea", meta: %{}}
    assert {:error, :seaport_order_required} = Venue.sell(position, list_price_usd: 10.0)
  end
end
