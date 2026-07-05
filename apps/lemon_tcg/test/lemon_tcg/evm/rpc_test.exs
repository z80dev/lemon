defmodule LemonTcg.Evm.RpcTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Evm.Rpc

  defp rpc_plug do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => method} = Jason.decode!(body)

      result =
        case method do
          "eth_chainId" -> "0x89"
          "eth_getTransactionCount" -> "0x5"
          "eth_maxPriorityFeePerGas" -> "0x77359400"
          "eth_getBlockByNumber" -> %{"baseFeePerGas" => "0x3b9aca00"}
          "eth_estimateGas" -> "0x186a0"
          "eth_sendRawTransaction" -> "0xdeadbeefhash"
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => result})
    end
  end

  defp opts, do: [rpc_url: "https://rpc.test", req_options: [plug: rpc_plug(), retry: false]]

  test "prepare_eip1559 fills nonce, chain id, fees, and padded gas" do
    tx = %{to: :binary.copy(<<0x11>>, 20), value: 100, data: <<0xAB>>}

    assert {:ok, prepared} =
             Rpc.prepare_eip1559(:polygon, "0xfrom", tx, opts())

    assert prepared.chain_id == 137
    assert prepared.nonce == 5
    assert prepared.max_priority_fee_per_gas == 2_000_000_000
    # base_fee 1 gwei * 2 + priority 2 gwei = 4 gwei
    assert prepared.max_fee_per_gas == 4_000_000_000
    # estimate 100000 + 20% pad
    assert prepared.gas == 120_000
  end

  test "send_raw_transaction returns the tx hash" do
    assert {:ok, "0xdeadbeefhash"} =
             Rpc.send_raw_transaction(:polygon, "0x02abcd", opts())
  end

  test "rpc errors surface as tagged tuples" do
    plug = fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"message" => "nope"}})
    end

    assert {:error, {:rpc_error, %{"message" => "nope"}}} =
             Rpc.chain_id(:polygon, rpc_url: "https://rpc.test", req_options: [plug: plug])
  end
end
