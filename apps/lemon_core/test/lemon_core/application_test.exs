defmodule LemonCore.ApplicationTest do
  @moduledoc """
  Tests for LemonCore.Application.

  These tests verify that the application starts correctly with all children
  and that the supervision tree has the expected structure.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Store

  setup do
    assert {:ok, _} = Application.ensure_all_started(:lemon_core)
    :ok
  end

  defp wait_for_pid(name, previous_pid, attempts \\ 20)

  defp wait_for_pid(_name, _previous_pid, 0), do: nil

  defp wait_for_pid(name, previous_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous_pid ->
        if Process.alive?(pid) do
          pid
        else
          Process.sleep(50)
          wait_for_pid(name, previous_pid, attempts - 1)
        end

      _ ->
        Process.sleep(50)
        wait_for_pid(name, previous_pid, attempts - 1)
    end
  end

  describe "application startup" do
    test "application is started" do
      assert {:ok, _} = Application.ensure_all_started(:lemon_core)

      assert Application.started_applications()
             |> Enum.any?(fn {app, _, _} -> app == :lemon_core end)
    end

    test "supervisor uses one_for_one strategy" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      assert supervisor_pid != nil

      # Get supervisor state - it's a tuple, not a map
      state = :sys.get_state(supervisor_pid)

      # The state is a tuple where the third element is the strategy
      assert elem(state, 2) == :one_for_one
    end
  end

  describe "supervisor children specification" do
    test "supervisor has exactly the expected children" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      children = Supervisor.which_children(supervisor_pid)

      expected = [
        LemonCore.RuntimeCache,
        LemonCore.Dedupe.Supervisor,
        if(LemonCore.Bus.pubsub?(), do: Phoenix.PubSub.Supervisor, else: LemonCore.Bus.Registry),
        LemonCore.Drain,
        LemonCore.ACPClientBridge,
        LemonCore.NodeRegistry,
        LemonCore.ConfigCache,
        LemonCore.Store,
        LemonCore.SessionActivity,
        LemonCore.Secrets.Usage,
        LemonCore.UsageLedger,
        LemonCore.ExecApprovalExpiry,
        LemonCore.Secrets.SourceTaskSupervisor,
        LemonCore.Secrets.SourceCache,
        LemonCore.ConfigReloader,
        LemonCore.ConfigReloader.Watcher,
        LemonCore.RuntimeLatch
      ]

      expected =
        if Code.ensure_loaded?(Exqlite.Sqlite3),
          do: [LemonCore.RunHistoryStore | expected],
          else: expected

      assert children |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(expected)
    end

    test "named core cache tables belong to supervised services" do
      root_children = Supervisor.which_children(LemonCore.Supervisor)

      for owner <- [LemonCore.RuntimeCache, LemonCore.Drain, LemonCore.ConfigCache] do
        pid = Process.whereis(owner)
        assert is_pid(pid)
        assert Enum.any?(root_children, fn {_, child, _, _} -> child == pid end)
      end

      assert :ets.info(LemonCore.RuntimeCache, :owner) == Process.whereis(LemonCore.RuntimeCache)
      assert :ets.info(LemonCore.Drain, :owner) == Process.whereis(LemonCore.Drain)
      assert :ets.info(:lemon_core_config_cache, :owner) == Process.whereis(LemonCore.ConfigCache)

      generations = LemonCore.NodeRegistry.Generations
      assert :ets.info(generations, :owner) == Process.whereis(generations)

      assert Enum.any?(Supervisor.which_children(LemonCore.NodeRegistry), fn
               {^generations, pid, :worker, _} -> pid == Process.whereis(generations)
               _ -> false
             end)

      for {_domain, table} <- LemonCore.Store.ReadCache.tables(Store) do
        assert :ets.info(table, :owner) == Process.whereis(Store)
      end
    end
  end

  describe "child restart behavior" do
    test "supervisor restarts crashed Store child" do
      # Get the original Store pid
      original_pid = Process.whereis(LemonCore.Store)
      assert original_pid != nil

      # Kill the Store process
      Process.exit(original_pid, :kill)

      # Verify Store was restarted
      new_pid = wait_for_pid(LemonCore.Store, original_pid)
      assert new_pid != nil
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
    end
  end

  describe "integration" do
    test "all children can communicate via PubSub" do
      # Subscribe to a test topic
      test_topic = "test:application:#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(LemonCore.PubSub, test_topic)

      # Broadcast a message
      message = {:test_message, self(), System.unique_integer([:positive])}
      Phoenix.PubSub.broadcast(LemonCore.PubSub, test_topic, message)

      # Verify we receive the message
      assert_receive ^message, 1000
    end

    test "Store can store and retrieve data after application start" do
      test_key = "application_test:#{System.unique_integer([:positive])}"
      test_value = %{data: "test_value", timestamp: System.system_time(:millisecond)}

      # Store data
      :ok = Store.put(:runs, test_key, test_value)

      # Retrieve data
      retrieved = Store.get(:runs, test_key)
      assert retrieved == test_value

      # Clean up
      Store.delete(:runs, test_key)
    end
  end
end
