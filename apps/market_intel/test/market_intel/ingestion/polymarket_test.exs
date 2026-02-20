defmodule MarketIntel.Ingestion.PolymarketTest do
  use ExUnit.Case
  alias MarketIntel.Ingestion.Polymarket

  describe "module structure" do
    test "exports expected functions" do
      assert function_exported?(Polymarket, :start_link, 1)
      assert function_exported?(Polymarket, :fetch, 0)
      assert function_exported?(Polymarket, :get_trending, 0)
    end

    test "is a GenServer" do
      assert Process.whereis(Polymarket) != nil
    end
  end
end
