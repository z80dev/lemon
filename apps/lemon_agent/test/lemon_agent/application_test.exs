defmodule LemonAgent.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for LemonAgent.Application supervision tree.
  """

  describe "application supervision tree" do
    test "application starts correctly" do
      # The application should already be started from test_helper.exs
      # Verify the main supervisor is running
      assert Process.whereis(LemonAgent.Supervisor) != nil
    end

    test "AgentRegistry is started and functional" do
      # Verify Registry is running
      assert Process.whereis(LemonAgent.AgentRegistry) != nil

      # Verify it's a Registry process
      key = {:test_session, :test_role, 0}

      # Test via/1 helper
      via = LemonAgent.AgentRegistry.via(key)
      assert {:via, Registry, {LemonAgent.AgentRegistry, ^key}} = via
    end

    test "SubagentSupervisor is started" do
      assert Process.whereis(LemonAgent.SubagentSupervisor) != nil

      # Verify it's a DynamicSupervisor
      children = DynamicSupervisor.which_children(LemonAgent.SubagentSupervisor)
      assert is_list(children)
    end

    test "LoopTaskSupervisor is started" do
      assert Process.whereis(LemonAgent.LoopTaskSupervisor) != nil

      # Verify it's a Task.Supervisor by starting a task
      task =
        Task.Supervisor.async_nolink(LemonAgent.LoopTaskSupervisor, fn ->
          :task_executed
        end)

      assert Task.await(task) == :task_executed
    end

    test "ToolTaskSupervisor is started" do
      assert Process.whereis(LemonAgent.ToolTaskSupervisor) != nil

      # Verify it's a Task.Supervisor by starting a task
      task =
        Task.Supervisor.async_nolink(LemonAgent.ToolTaskSupervisor, fn ->
          :tool_task_executed
        end)

      assert Task.await(task) == :tool_task_executed
    end

    test "supervisor has correct child count" do
      # The application should have 6 children:
      # 1. LemonAgent.AbortSignal.TableOwner
      # 2. LemonAgent.AgentRegistry (Registry)
      # 3. LemonAgent.SubagentSupervisor (DynamicSupervisor)
      # 4. LemonAgent.LoopTaskSupervisor (Task.Supervisor)
      # 5. LemonAgent.ToolTaskSupervisor (Task.Supervisor)
      # 6. LemonAgent.ModelRuntime.ProviderPoolRotator (GenServer)
      children = Supervisor.which_children(LemonAgent.Supervisor)
      assert length(children) == 6
    end

    test "supervisor uses one_for_one strategy" do
      # We can't directly query strategy, but we can verify children are independent
      # by checking they all have unique ids
      children = Supervisor.which_children(LemonAgent.Supervisor)
      ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "child process characteristics" do
    test "all child processes are alive" do
      children = Supervisor.which_children(LemonAgent.Supervisor)

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end
    end

    test "supervisor counts children correctly" do
      counts = Supervisor.count_children(LemonAgent.Supervisor)

      assert counts.active == 6
      assert counts.specs == 6
      # SubagentSupervisor and Task.Supervisors
      assert counts.supervisors >= 2
      assert counts.workers >= 0
    end
  end

  describe "graceful shutdown behavior" do
    test "SubagentSupervisor stops cleanly when empty" do
      # Verify no subagents are running initially (or clean up)
      initial_count = LemonAgent.SubagentSupervisor.count()

      # The supervisor should be able to list children without error
      subagents = LemonAgent.SubagentSupervisor.list_subagents()
      assert is_list(subagents)
      assert length(subagents) == initial_count
    end

    test "Task.Supervisors can execute and complete tasks" do
      # Test LoopTaskSupervisor
      loop_task =
        Task.Supervisor.async_nolink(LemonAgent.LoopTaskSupervisor, fn ->
          Process.sleep(10)
          :loop_done
        end)

      # Test ToolTaskSupervisor
      tool_task =
        Task.Supervisor.async_nolink(LemonAgent.ToolTaskSupervisor, fn ->
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
      via = LemonAgent.AgentRegistry.via(key)

      # Start a simple GenServer with the via name
      {:ok, pid} = Agent.start_link(fn -> :test_state end, name: via)

      # Verify lookup works
      assert {:ok, ^pid} = LemonAgent.AgentRegistry.lookup(key)

      # Clean up
      Agent.stop(pid)

      # Verify lookup returns :error after stop
      assert :ok = wait_for_registry_clear(key)
    end
  end

  defp wait_for_registry_clear(key, timeout_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> LemonAgent.AgentRegistry.lookup(key) end)
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
