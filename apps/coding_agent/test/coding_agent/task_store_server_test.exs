defmodule CodingAgent.TaskStoreServerTest do
  @moduledoc """
  Tests for the TaskStoreServer module.
  
  TaskStoreServer is a GenServer that owns the TaskStore ETS table
  and manages DETS persistence.
  """
  
  use ExUnit.Case, async: false
  
  alias CodingAgent.TaskStoreServer
  
  setup do
    # Create a unique temporary directory for each test
    test_id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "task_store_server_test_#{test_id}")
    File.mkdir_p!(tmp_dir)
    
    dets_path = Path.join(tmp_dir, "test_tasks.dets")
    
    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)
    
    %{tmp_dir: tmp_dir, dets_path: dets_path}
  end
  
  # ============================================================================
  # start_link/1 Tests
  # ============================================================================
  
  describe "start_link/1" do
    test "starts server successfully", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      assert is_pid(pid)
      assert Process.alive?(pid)
      
      GenServer.stop(pid)
    end
    
    test "creates ETS table on startup", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # Table should exist
      table = TaskStoreServer.table_name()
      assert :ets.whereis(table) != :undefined
      
      GenServer.stop(pid)
    end
    
    test "initializes DETS on startup", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # DETS file should be created
      assert File.exists?(dets_path)
      
      GenServer.stop(pid)
    end
    
    test "handles already_started gracefully", %{dets_path: dets_path} do
      assert {:ok, pid1} = TaskStoreServer.start_link(dets_path: dets_path)
      assert {:ok, pid2} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # Should return the same pid
      assert pid1 == pid2
      
      GenServer.stop(pid1)
    end
    
    test "accepts custom name option", %{dets_path: dets_path} do
      name = :custom_task_store
      assert {:ok, pid} = TaskStoreServer.start_link(name: name, dets_path: dets_path)
      
      # Should be registered under the custom name
      assert Process.whereis(name) == pid
      
      GenServer.stop(pid)
    end
  end
  
  # ============================================================================
  # table_name/0 Tests
  # ============================================================================
  
  describe "table_name/0" do
    test "returns atom table name" do
      assert is_atom(TaskStoreServer.table_name())
    end
    
    test "returns consistent value" do
      name1 = TaskStoreServer.table_name()
      name2 = TaskStoreServer.table_name()
      assert name1 == name2
    end
  end
  
  # ============================================================================
  # ensure_table/1 Tests
  # ============================================================================
  
  describe "ensure_table/1" do
    test "returns :ok when table exists", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      assert :ok = TaskStoreServer.ensure_table(pid)
      
      GenServer.stop(pid)
    end
    
    test "table is a named set", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      info = :ets.info(table)
      
      assert info[:named_table] == true
      assert info[:type] == :set
      
      GenServer.stop(pid)
    end
  end
  
  # ============================================================================
  # cleanup/2 Tests
  # ============================================================================
  
  describe "cleanup/2" do
    test "removes expired tasks", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # Insert an old completed task directly
      table = TaskStoreServer.table_name()
      old_task = %{
        id: "old_task",
        status: :completed,
        completed_at: System.system_time(:second) - 100_000
      }
      :ets.insert(table, {"old_task", old_task, []})
      
      # Cleanup with short TTL should remove the task
      assert {:ok, deleted} = TaskStoreServer.cleanup(pid, 86_400)
      assert deleted == 1
      
      GenServer.stop(pid)
    end
    
    test "does not remove recent tasks", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      recent_task = %{
        id: "recent_task",
        status: :completed,
        completed_at: System.system_time(:second)
      }
      :ets.insert(table, {"recent_task", recent_task, []})
      
      # Cleanup should not remove recent task
      assert {:ok, 0} = TaskStoreServer.cleanup(pid, 86_400)
      
      # Task should still be in table
      assert :ets.lookup(table, "recent_task") != []
      
      GenServer.stop(pid)
    end
    
    test "does not remove running tasks", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      running_task = %{
        id: "running_task",
        status: :running,
        inserted_at: System.system_time(:second) - 100_000
      }
      :ets.insert(table, {"running_task", running_task, []})
      
      # Cleanup should not remove running task
      assert {:ok, 0} = TaskStoreServer.cleanup(pid, 86_400)
      
      GenServer.stop(pid)
    end
    
    test "returns 0 when no expired tasks", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      assert {:ok, 0} = TaskStoreServer.cleanup(pid)
      
      GenServer.stop(pid)
    end
  end
  
  # ============================================================================
  # clear/1 Tests
  # ============================================================================
  
  describe "clear/1" do
    test "removes all tasks from ETS", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      :ets.insert(table, {"task1", %{id: "task1"}, []})
      :ets.insert(table, {"task2", %{id: "task2"}, []})
      
      assert :ok = TaskStoreServer.clear(pid)
      
      assert :ets.tab2list(table) == []
      
      GenServer.stop(pid)
    end
    
    test "clears from DETS as well", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      :ets.insert(table, {"task1", %{id: "task1", status: :completed}, []})
      
      assert :ok = TaskStoreServer.clear(pid)
      
      # After restart, DETS should be empty too
      GenServer.stop(pid)
      
      assert {:ok, pid2} = TaskStoreServer.start_link(dets_path: dets_path)
      table2 = TaskStoreServer.table_name()
      assert :ets.tab2list(table2) == []
      
      GenServer.stop(pid2)
    end
    
    test "works on empty table", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      assert :ok = TaskStoreServer.clear(pid)
      
      GenServer.stop(pid)
    end
  end
  
  # ============================================================================
  # dets_status/1 Tests
  # ============================================================================
  
  describe "dets_status/1" do
    test "returns DETS status when initialized", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      result = TaskStoreServer.dets_status(pid)
      
      assert is_map(result)
      assert Map.has_key?(result, :info)
      assert Map.has_key?(result, :state)
      
      GenServer.stop(pid)
    end
  end
  
  # ============================================================================
  # Server Lifecycle Tests
  # ============================================================================
  
  describe "server lifecycle" do
    test "ETS table is created on server start", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      assert :ets.whereis(table) != :undefined
      
      GenServer.stop(pid)
    end
    
    test "DETS is closed on server stop", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # Let it initialize
      Process.sleep(100)
      
      GenServer.stop(pid)
      
      # DETS should be closed, but file should exist
      assert File.exists?(dets_path)
    end
  end
  
  # ============================================================================
  # Persistence Tests
  # ============================================================================
  
  describe "persistence" do
    test "DETS file is created on startup", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # DETS file should exist after startup
      assert File.exists?(dets_path)
      
      GenServer.stop(pid)
    end
    
    test "data can be inserted and retrieved", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      table = TaskStoreServer.table_name()
      :ets.insert(table, {"test_task", %{id: "test_task", status: :completed}, []})
      
      # Should be able to retrieve the data
      assert :ets.lookup(table, "test_task") != []
      
      GenServer.stop(pid)
    end
  end
  
  # ============================================================================
  # Concurrent Access Tests
  # ============================================================================
  
  describe "concurrent access" do
    test "handles concurrent reads", %{dets_path: dets_path} do
      assert {:ok, pid} = TaskStoreServer.start_link(dets_path: dets_path)
      
      # Spawn multiple processes that read
      tasks = for _ <- 1..10 do
        Task.async(fn ->
          TaskStoreServer.ensure_table(pid)
        end)
      end
      
      # All should succeed
      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))
      
      GenServer.stop(pid)
    end
  end
end
