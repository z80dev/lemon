defmodule MarketIntel.Ingestion.DexScreenerTest do
  use ExUnit.Case
  alias MarketIntel.Ingestion.DexScreener

  describe "module structure" do
    test "exports expected functions" do
      assert function_exported?(DexScreener, :start_link, 1)
      assert function_exported?(DexScreener, :fetch, 0)
      assert function_exported?(DexScreener, :get_tracked_token_data, 0)
    end

    test "is a GenServer" do
      assert Process.whereis(DexScreener) != nil
    end
  end
end
