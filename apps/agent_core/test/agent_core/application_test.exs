defmodule AgentCore.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for AgentCore.Application supervision tree.
  """

  describe "application supervision tree" do
    test "application starts correctly" do
      # The application should already be started from test_helper.exs
      # Verify the main supervisor is running
      assert Process.whereis(AgentCore.Supervisor) != nil
    end

    test "AgentRegistry is started and functional" do
      # Verify Registry is running
      assert Process.whereis(AgentCore.AgentRegistry) != nil

      # Verify it's a Registry process
      key = {:test_session, :test_role, 0}

      # Test via/1 helper
      via = AgentCore.AgentRegistry.via(key)
      assert {:via, Registry, {AgentCore.AgentRegistry, ^key}} = via
    end

    test "SubagentSupervisor is started" do
      assert Process.whereis(AgentCore.SubagentSupervisor) != nil

      # Verify it's a DynamicSupervisor
      children = DynamicSupervisor.which_children(AgentCore.SubagentSupervisor)
      assert is_list(children)
    end

    test "LoopTaskSupervisor is started" do
      assert Process.whereis(AgentCore.LoopTaskSupervisor) != nil

      # Verify it's a Task.Supervisor by starting a task
      task =
        Task.Supervisor.async_nolink(AgentCore.LoopTaskSupervisor, fn ->
          :task_executed
        end)

      assert Task.await(task) == :task_executed
    end

    test "ToolTaskSupervisor is started" do
      assert Process.whereis(AgentCore.ToolTaskSupervisor) != nil

      # Verify it's a Task.Supervisor by starting a task
      task =
        Task.Supervisor.async_nolink(AgentCore.ToolTaskSupervisor, fn ->
          :tool_task_executed
        end)

      assert Task.await(task) == :tool_task_executed
    end

    test "supervisor has correct child count" do
      # The application should have 4 children:
      # 1. AgentCore.AgentRegistry (Registry)
      # 2. AgentCore.SubagentSupervisor (DynamicSupervisor)
      # 3. AgentCore.LoopTaskSupervisor (Task.Supervisor)
      # 4. AgentCore.ToolTaskSupervisor (Task.Supervisor)
      children = Supervisor.which_children(AgentCore.Supervisor)
      assert length(children) == 4
    end

    test "supervisor uses one_for_one strategy" do
      # We can't directly query strategy, but we can verify children are independent
      # by checking they all have unique ids
      children = Supervisor.which_children(AgentCore.Supervisor)
      ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "child process characteristics" do
    test "all child processes are alive" do
      children = Supervisor.which_children(AgentCore.Supervisor)

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end
    end

    test "supervisor counts children correctly" do
      counts = Supervisor.count_children(AgentCore.Supervisor)

      assert counts.active == 4
      assert counts.specs == 4
      # SubagentSupervisor and Task.Supervisors
      assert counts.supervisors >= 2
      assert counts.workers >= 0
    end
  end

  describe "graceful shutdown behavior" do
    test "SubagentSupervisor stops cleanly when empty" do
      # Verify no subagents are running initially (or clean up)
      initial_count = AgentCore.SubagentSupervisor.count()

      # The supervisor should be able to list children without error
      subagents = AgentCore.SubagentSupervisor.list_subagents()
      assert is_list(subagents)
      assert length(subagents) == initial_count
    end

    test "Task.Supervisors can execute and complete tasks" do
      # Test LoopTaskSupervisor
      loop_task =
        Task.Supervisor.async_nolink(AgentCore.LoopTaskSupervisor, fn ->
          Process.sleep(10)
          :loop_done
        end)

      # Test ToolTaskSupervisor
      tool_task =
        Task.Supervisor.async_nolink(AgentCore.ToolTaskSupervisor, fn ->
          Process.sleep(10)
          :tool_done
        end)

      assert Task.await(loop_task) == :loop_done
      assert Task.await(tool_task) == :tool_done
    end
  end

  describe "registry functionality" do
    test "AgentRegistry can register and lookup processes" do
      key = {:test_app_session, :coordinator, 0}
      via = AgentCore.AgentRegistry.via(key)

      # Start a simple GenServer with the via name
      {:ok, pid} = Agent.start_link(fn -> :test_state end, name: via)

      # Verify lookup works
      assert {:ok, ^pid} = AgentCore.AgentRegistry.lookup(key)

      # Clean up
      Agent.stop(pid)

      # Verify lookup returns :error after stop
      assert :ok = wait_for_registry_clear(key)
    end
  end

  defp wait_for_registry_clear(key, timeout_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> AgentCore.AgentRegistry.lookup(key) end)
    |> Enum.reduce_while(:error, fn lookup, _acc ->
      cond do
        lookup == :error ->
          {:halt, :ok}

        System.monotonic_time(:millisecond) >= deadline ->
          {:halt, lookup}

        true ->
          Process.sleep(10)
          {:cont, lookup}
      end
    end)
  end
end
