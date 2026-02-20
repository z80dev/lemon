defmodule MarketIntel.Ingestion.OnChainTest do
  use ExUnit.Case
  alias MarketIntel.Ingestion.OnChain

  describe "module structure" do
    test "exports expected functions" do
      assert function_exported?(OnChain, :start_link, 1)
      assert function_exported?(OnChain, :fetch, 0)
      assert function_exported?(OnChain, :get_network_stats, 0)
      assert function_exported?(OnChain, :get_large_transfers, 0)
    end

    test "is a GenServer" do
      assert Process.whereis(OnChain) != nil
    end
  end
end
