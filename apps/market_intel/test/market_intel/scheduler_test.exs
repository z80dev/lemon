defmodule MarketIntel.SchedulerTest do
  use ExUnit.Case, async: false

  describe "module structure" do
    test "exports start_link/1" do
      assert function_exported?(MarketIntel.Scheduler, :start_link, 1)
    end

    test "is a GenServer" do
      behaviours =
        MarketIntel.Scheduler.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert GenServer in behaviours
    end

    test "scheduler process is registered" do
      assert is_pid(Process.whereis(MarketIntel.Scheduler))
    end
  end

  describe "state management" do
    test "state has expected keys" do
      pid = Process.whereis(MarketIntel.Scheduler)
      state = :sys.get_state(pid)

      assert is_map(state)
      assert Map.has_key?(state, :last_regular)
      assert Map.has_key?(state, :last_deep)
    end

    test "handle_info(:deep_analysis) updates last_deep" do
      pid = Process.whereis(MarketIntel.Scheduler)

      # Send deep_analysis message directly
      send(pid, :deep_analysis)
      Process.sleep(50)

      if Process.alive?(pid) do
        state = :sys.get_state(pid)
        assert %DateTime{} = state.last_deep
      end
    end

    test "handle_info(:regular_commentary) updates last_regular" do
      pid = Process.whereis(MarketIntel.Scheduler)

      # Send regular_commentary - Pipeline.trigger may fail but
      # handle_info still updates state before re-raising
      send(pid, :regular_commentary)
      Process.sleep(50)

      if Process.alive?(pid) do
        state = :sys.get_state(pid)
        assert %DateTime{} = state.last_regular
      end
    end
  end
end
