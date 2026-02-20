defmodule CodingAgent.Tools.TodoStoreOwnerTest do
  @moduledoc """
  Tests for the TodoStoreOwner module.

  TodoStoreOwner is a GenServer that owns the ETS table used by TodoStore.
  It ensures the table persists even when client processes exit.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Tools.TodoStoreOwner

  @table :coding_agent_todos

  setup do
    # Generate a unique name for each test to avoid conflicts
    test_name = :"todo_store_owner_#{System.unique_integer([:positive])}"

    %{test_name: test_name}
  end

  # ============================================================================
  # start_link/1 Tests
  # ============================================================================

  describe "start_link/1" do
    test "starts server successfully", %{test_name: test_name} do
      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)
      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "accepts custom name option", %{test_name: test_name} do
      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      # Should be registered under the custom name
      assert Process.whereis(test_name) == pid

      GenServer.stop(pid)
    end

    test "returns already_started error when name is taken", %{test_name: test_name} do
      assert {:ok, pid1} = TodoStoreOwner.start_link(name: test_name)
      assert {:error, {:already_started, pid2}} = TodoStoreOwner.start_link(name: test_name)

      # Should return the same pid
      assert pid1 == pid2

      GenServer.stop(pid1)
    end
  end

  # ============================================================================
  # init/1 Tests
  # ============================================================================

  describe "init/1" do
    test "creates the ETS table on startup", %{test_name: test_name} do
      # Clean up table if it exists from previous tests/app
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert :ets.whereis(@table) == :undefined

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      # Table should exist after starting
      assert :ets.whereis(@table) != :undefined

      GenServer.stop(pid)
    end

    test "does not recreate table if it already exists", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      # Create the table first
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      assert :ets.whereis(@table) != :undefined

      # Starting the server should not fail
      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)
      assert Process.alive?(pid)

      # Table should still exist
      assert :ets.whereis(@table) != :undefined

      GenServer.stop(pid)
    end

    test "creates table as named table", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      info = :ets.info(@table)
      assert info[:named_table] == true

      GenServer.stop(pid)
    end

    test "creates table as public", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      info = :ets.info(@table)
      assert info[:protection] == :public

      GenServer.stop(pid)
    end

    test "creates table as set", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      info = :ets.info(@table)
      assert info[:type] == :set

      GenServer.stop(pid)
    end

    test "enables read_concurrency", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      info = :ets.info(@table)
      assert info[:read_concurrency] == true

      GenServer.stop(pid)
    end

    test "enables write_concurrency", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      info = :ets.info(@table)
      assert info[:write_concurrency] == true

      GenServer.stop(pid)
    end
  end

  # ============================================================================
  # Server Lifecycle Tests
  # ============================================================================

  describe "server lifecycle" do
    test "ETS table survives client process exits", %{test_name: test_name} do
      # Clean up first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      assert {:ok, pid} = TodoStoreOwner.start_link(name: test_name)

      # Simulate a client process that uses the table
      client =
        Task.async(fn ->
          :ets.insert(@table, {"test_key", "test_value"})
          :ok
        end)

      assert Task.await(client) == :ok

      # Table should still exist and have the data
      assert :ets.whereis(@table) != :undefined
      assert :ets.lookup(@table, "test_key") == [{"test_key", "test_value"}]

      GenServer.stop(pid)
    end
  end
end
