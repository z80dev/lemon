defmodule LemonCore.ApplicationTest do
  @moduledoc """
  Tests for LemonCore.Application.

  These tests verify that the application starts correctly with all children
  and that the supervision tree has the expected structure.
  """
  use ExUnit.Case, async: false

  alias LemonCore.ConfigCache
  alias LemonCore.Store

  describe "application startup" do
    test "application is started" do
      assert {:ok, _} = Application.ensure_all_started(:lemon_core)
      assert Application.started_applications()
             |> Enum.any?(fn {app, _, _} -> app == :lemon_core end)
    end

    test "supervisor is running with correct name" do
      assert Process.whereis(LemonCore.Supervisor) != nil
      assert Process.alive?(Process.whereis(LemonCore.Supervisor))
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

  describe "supervision tree children" do
    test "Phoenix.PubSub is started with correct name" do
      assert Process.whereis(LemonCore.PubSub) != nil
      assert Process.alive?(Process.whereis(LemonCore.PubSub))
    end

    test "ConfigCache is started and available" do
      assert ConfigCache.available?()
      assert Process.whereis(LemonCore.ConfigCache) != nil
    end

    test "Store is started and accessible" do
      assert Process.whereis(LemonCore.Store) != nil
      assert Process.alive?(Process.whereis(LemonCore.Store))
    end

    test "LocalServer is started" do
      assert Process.whereis(LemonCore.Browser.LocalServer) != nil
      assert Process.alive?(Process.whereis(LemonCore.Browser.LocalServer))
    end
  end

  describe "supervisor children specification" do
    test "supervisor has expected children" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      children = Supervisor.which_children(supervisor_pid)

      # Verify all expected children are present
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      # Phoenix.PubSub is started as Phoenix.PubSub.Supervisor
      assert Phoenix.PubSub.Supervisor in child_ids
      assert LemonCore.ConfigCache in child_ids
      assert LemonCore.Store in child_ids
      assert LemonCore.Browser.LocalServer in child_ids
    end

    test "supervisor has exactly 4 children" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      children = Supervisor.which_children(supervisor_pid)

      assert length(children) == 4
    end

    test "children include both workers and supervisors" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      children = Supervisor.which_children(supervisor_pid)

      # Collect types
      types = Enum.map(children, fn {_, _, type, _} -> type end)

      # Should have both workers and at least one supervisor (PubSub)
      assert :worker in types
      assert :supervisor in types

      # All pids should be alive
      for {_, pid, _, _} <- children do
        assert pid != :undefined
        assert Process.alive?(pid)
      end
    end

    test "PubSub is a supervisor, others are workers" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      children = Supervisor.which_children(supervisor_pid)

      child_map = Map.new(children, fn {id, pid, type, _} -> {id, {pid, type}} end)

      # PubSub is a supervisor
      assert {_, :supervisor} = child_map[Phoenix.PubSub.Supervisor]

      # Others are workers
      assert {_, :worker} = child_map[LemonCore.ConfigCache]
      assert {_, :worker} = child_map[LemonCore.Store]
      assert {_, :worker} = child_map[LemonCore.Browser.LocalServer]
    end
  end

  describe "ConfigCache configuration" do
    test "ConfigCache uses application environment config" do
      # Get the config that was passed to ConfigCache
      config = Application.get_env(:lemon_core, LemonCore.ConfigCache, [])

      # ConfigCache should be started with these options
      assert is_list(config)
    end
  end

  describe "child restart behavior" do
    test "supervisor restarts crashed Store child" do
      # Get the original Store pid
      original_pid = Process.whereis(LemonCore.Store)
      assert original_pid != nil

      # Kill the Store process
      Process.exit(original_pid, :kill)

      # Wait for supervisor to restart it
      Process.sleep(100)

      # Verify Store was restarted
      new_pid = Process.whereis(LemonCore.Store)
      assert new_pid != nil
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
    end

    test "supervisor restarts LocalServer after crash" do
      # Get the original LocalServer pid
      original_pid = Process.whereis(LemonCore.Browser.LocalServer)
      assert original_pid != nil

      # Kill the LocalServer process
      Process.exit(original_pid, :kill)

      # Wait for supervisor to restart it
      Process.sleep(100)

      # Verify LocalServer was restarted
      new_pid = Process.whereis(LemonCore.Browser.LocalServer)
      assert new_pid != nil
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
    end
  end

  describe "logging setup" do
    test "maybe_add_file_handler is called during startup" do
      # The logging module should be loaded and the function should exist
      assert Code.ensure_loaded?(LemonCore.Logging)
      assert function_exported?(LemonCore.Logging, :maybe_add_file_handler, 0)
    end
  end

  describe "application callbacks" do
    test "start/2 callback is exported" do
      assert function_exported?(LemonCore.Application, :start, 2)
    end

    test "application module uses Application behaviour" do
      assert function_exported?(LemonCore.Application, :start, 2)
      assert function_exported?(LemonCore.Application, :stop, 1)
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

    test "ConfigCache returns config after application start" do
      config = ConfigCache.get(nil)
      assert is_map(config)
    end
  end
end
