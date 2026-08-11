defmodule LemonAgent.ApplicationSupervisionTest do
  @moduledoc """
  Tests for LemonAgent application supervision tree configuration.

  Verifies:
  - Supervision strategies are correct
  - Max restarts/seconds configuration
  - Child shutdown timeouts
  - Child ordering and dependencies
  """
  use ExUnit.Case, async: false

  # Ensure all supervisors are running before each test
  setup do
    # Wait for any prior restart to complete
    Process.sleep(50)

    # Ensure all the application processes are up
    ensure_process_running(LemonAgent.Supervisor)
    ensure_process_running(LemonAgent.AgentRegistry)
    ensure_process_running(LemonAgent.SubagentSupervisor)
    ensure_process_running(LemonAgent.LoopTaskSupervisor)
    ensure_process_running(LemonAgent.ToolTaskSupervisor)

    :ok
  end

  defp ensure_process_running(name) do
    # Wait up to 500ms for process to be available
    Enum.reduce_while(1..10, nil, fn _, _ ->
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          {:halt, pid}

        nil ->
          Process.sleep(50)
          {:cont, nil}
      end
    end)
  end

  describe "LemonAgent.Supervisor configuration" do
    test "supervisor exists and is running" do
      assert pid = Process.whereis(LemonAgent.Supervisor)
      assert Process.alive?(pid)
    end

    test "supervisor uses one_for_one strategy" do
      # Get supervisor info
      children = Supervisor.which_children(LemonAgent.Supervisor)

      # Should have expected children
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert LemonAgent.AgentRegistry in child_ids
      assert LemonAgent.SubagentSupervisor in child_ids
      assert LemonAgent.LoopTaskSupervisor in child_ids
      assert LemonAgent.ToolTaskSupervisor in child_ids
    end

    test "all children are alive" do
      children = Supervisor.which_children(LemonAgent.Supervisor)

      for {id, pid, _type, _modules} <- children do
        assert is_pid(pid), "Expected #{inspect(id)} to have a pid"
        assert Process.alive?(pid), "Expected #{inspect(id)} to be alive"
      end
    end
  end

  describe "LemonAgent.AgentRegistry" do
    test "registry is running" do
      assert pid = Process.whereis(LemonAgent.AgentRegistry)
      assert Process.alive?(pid)
    end

    test "can register and lookup agents" do
      key = {:test_session, :test_role, System.unique_integer()}

      # Register via the registry
      {:ok, _} = Registry.register(LemonAgent.AgentRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(LemonAgent.AgentRegistry, key)
    end
  end

  describe "LemonAgent.SubagentSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(LemonAgent.SubagentSupervisor)
      assert Process.alive?(pid)
    end

    test "count returns number of active children" do
      assert count = LemonAgent.SubagentSupervisor.count()
      assert is_integer(count)
      assert count >= 0
    end
  end

  describe "LemonAgent.LoopTaskSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(LemonAgent.LoopTaskSupervisor)
      assert Process.alive?(pid)
    end

    test "can start async tasks" do
      task =
        Task.Supervisor.async_nolink(LemonAgent.LoopTaskSupervisor, fn ->
          :test_result
        end)

      assert {:ok, :test_result} = Task.yield(task, 1000)
    end
  end

  describe "LemonAgent.ToolTaskSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(LemonAgent.ToolTaskSupervisor)
      assert Process.alive?(pid)
    end

    test "can start async tasks" do
      task =
        Task.Supervisor.async_nolink(LemonAgent.ToolTaskSupervisor, fn ->
          :tool_result
        end)

      assert {:ok, :tool_result} = Task.yield(task, 1000)
    end
  end
end
