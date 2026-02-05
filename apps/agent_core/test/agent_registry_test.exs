defmodule AgentCore.AgentRegistryTest do
  @moduledoc """
  Comprehensive tests for AgentCore.AgentRegistry module.

  Tests cover:
  - Agent registration (with and without metadata)
  - Agent lookup (with and without metadata)
  - Agent deregistration
  - Concurrent access scenarios
  - Error handling for missing agents
  - Listing and counting functions
  """

  use ExUnit.Case, async: false

  alias AgentCore.AgentRegistry

  # Helper to generate unique session IDs for test isolation
  defp unique_session_id do
    "session_#{System.unique_integer([:positive, :monotonic])}"
  end

  # ============================================================================
  # Agent Registration Tests
  # ============================================================================

  describe "register/1" do
    test "successfully registers the current process with a key" do
      key = {unique_session_id(), :main, 0}

      assert :ok = AgentRegistry.register(key)
      assert {:ok, pid} = AgentRegistry.lookup(key)
      assert pid == self()
    end

    test "registers different roles for the same session" do
      session_id = unique_session_id()
      roles = [:main, :research, :implement, :review]
      current_pid = self()

      for {role, index} <- Enum.with_index(roles) do
        # Each role registration happens from the same process but with different keys
        key = {session_id, role, index}
        assert :ok = AgentRegistry.register(key)
      end

      # Verify all registrations
      for {role, index} <- Enum.with_index(roles) do
        key = {session_id, role, index}
        assert {:ok, ^current_pid} = AgentRegistry.lookup(key)
      end
    end

    test "registers multiple indices for the same role" do
      session_id = unique_session_id()
      role = :worker

      for index <- 0..4 do
        key = {session_id, role, index}
        assert :ok = AgentRegistry.register(key)
      end

      # Verify all registrations
      for index <- 0..4 do
        key = {session_id, role, index}
        assert {:ok, _pid} = AgentRegistry.lookup(key)
      end
    end

    test "returns error when same process tries to register duplicate key" do
      key = {unique_session_id(), :main, 0}

      assert :ok = AgentRegistry.register(key)
      # Same process trying to register same key again
      assert {:error, {:already_registered, pid}} = AgentRegistry.register(key)
      assert pid == self()
    end

    test "returns error when different process tries to register existing key" do
      key = {unique_session_id(), :main, 0}
      parent = self()

      assert :ok = AgentRegistry.register(key)

      spawn(fn ->
        result = AgentRegistry.register(key)
        send(parent, {:result, result})
      end)

      assert_receive {:result, {:error, {:already_registered, pid}}}
      assert pid == self()
    end
  end

  describe "register/2 with metadata" do
    test "registers with metadata and retrieves it" do
      key = {unique_session_id(), :research, 0}
      metadata = %{model: "claude-3-opus", temperature: 0.7}

      assert :ok = AgentRegistry.register(key, metadata)
      assert {:ok, pid, ^metadata} = AgentRegistry.lookup_with_metadata(key)
      assert pid == self()
    end

    test "registers with complex metadata" do
      key = {unique_session_id(), :agent, 0}
      metadata = %{
        model: "claude-3-opus",
        config: %{
          temperature: 0.7,
          max_tokens: 4096
        },
        tags: [:primary, :production],
        created_at: System.system_time(:millisecond)
      }

      assert :ok = AgentRegistry.register(key, metadata)
      assert {:ok, _pid, ^metadata} = AgentRegistry.lookup_with_metadata(key)
    end

    test "registers with nil metadata" do
      key = {unique_session_id(), :main, 0}

      assert :ok = AgentRegistry.register(key, nil)
      assert {:ok, _pid, nil} = AgentRegistry.lookup_with_metadata(key)
    end

    test "different agents can have different metadata" do
      session_id = unique_session_id()
      parent = self()

      # Register main agent with metadata from current process
      main_key = {session_id, :main, 0}
      main_metadata = %{role: :main, priority: :high}
      assert :ok = AgentRegistry.register(main_key, main_metadata)

      # Register research agent from a spawned process
      research_key = {session_id, :research, 0}
      research_metadata = %{role: :research, priority: :normal}

      pid = spawn(fn ->
        :ok = AgentRegistry.register(research_key, research_metadata)
        send(parent, :registered)
        receive do
          :done -> :ok
        end
      end)

      assert_receive :registered

      # Verify both have their correct metadata
      assert {:ok, _, ^main_metadata} = AgentRegistry.lookup_with_metadata(main_key)
      assert {:ok, ^pid, ^research_metadata} = AgentRegistry.lookup_with_metadata(research_key)

      send(pid, :done)
    end
  end

  # ============================================================================
  # Agent Lookup Tests
  # ============================================================================

  describe "lookup/1" do
    test "returns {:ok, pid} for registered key" do
      key = {unique_session_id(), :main, 0}
      :ok = AgentRegistry.register(key)

      assert {:ok, pid} = AgentRegistry.lookup(key)
      assert pid == self()
    end

    test "returns :error for unregistered key" do
      key = {"nonexistent_session_#{System.unique_integer()}", :unknown, 99}

      assert :error = AgentRegistry.lookup(key)
    end

    test "returns :error after process that registered terminates" do
      key = {unique_session_id(), :main, 0}
      parent = self()

      pid = spawn(fn ->
        :ok = AgentRegistry.register(key)
        send(parent, :registered)
        receive do
          :exit -> :ok
        end
      end)

      assert_receive :registered
      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      # Terminate the process
      send(pid, :exit)
      # Give the registry time to clean up
      Process.sleep(50)

      assert :error = AgentRegistry.lookup(key)
    end

    test "returns correct pid when multiple sessions exist" do
      session1 = unique_session_id()
      session2 = unique_session_id()
      parent = self()

      # Register in session1 from current process
      key1 = {session1, :main, 0}
      :ok = AgentRegistry.register(key1)

      # Register in session2 from another process
      key2 = {session2, :main, 0}
      pid2 = spawn(fn ->
        :ok = AgentRegistry.register(key2)
        send(parent, :registered)
        receive do
          :done -> :ok
        end
      end)

      assert_receive :registered

      assert {:ok, self_pid} = AgentRegistry.lookup(key1)
      assert self_pid == self()

      assert {:ok, other_pid} = AgentRegistry.lookup(key2)
      assert other_pid == pid2

      send(pid2, :done)
    end
  end

  describe "lookup_with_metadata/1" do
    test "returns {:ok, pid, metadata} for registered key with metadata" do
      key = {unique_session_id(), :agent, 0}
      metadata = %{test: true}
      :ok = AgentRegistry.register(key, metadata)

      assert {:ok, pid, ^metadata} = AgentRegistry.lookup_with_metadata(key)
      assert pid == self()
    end

    test "returns {:ok, pid, nil} for registered key without explicit metadata" do
      key = {unique_session_id(), :agent, 0}
      :ok = AgentRegistry.register(key)

      assert {:ok, pid, nil} = AgentRegistry.lookup_with_metadata(key)
      assert pid == self()
    end

    test "returns :error for unregistered key" do
      key = {"nonexistent_#{System.unique_integer()}", :unknown, 0}

      assert :error = AgentRegistry.lookup_with_metadata(key)
    end
  end

  # ============================================================================
  # Agent Deregistration Tests
  # ============================================================================

  describe "unregister/1" do
    test "successfully unregisters a key" do
      key = {unique_session_id(), :main, 0}
      :ok = AgentRegistry.register(key)

      assert {:ok, _pid} = AgentRegistry.lookup(key)

      :ok = AgentRegistry.unregister(key)

      assert :error = AgentRegistry.lookup(key)
    end

    test "unregistering allows re-registration by same process" do
      key = {unique_session_id(), :main, 0}

      :ok = AgentRegistry.register(key)
      :ok = AgentRegistry.unregister(key)
      :ok = AgentRegistry.register(key)

      assert {:ok, pid} = AgentRegistry.lookup(key)
      assert pid == self()
    end

    test "unregistering allows re-registration by different process" do
      key = {unique_session_id(), :main, 0}
      parent = self()

      :ok = AgentRegistry.register(key)
      :ok = AgentRegistry.unregister(key)

      spawn(fn ->
        result = AgentRegistry.register(key)
        send(parent, {:result, result, self()})
        receive do
          :done -> :ok
        end
      end)

      assert_receive {:result, :ok, new_pid}
      assert {:ok, ^new_pid} = AgentRegistry.lookup(key)
    end

    test "unregistering non-existent key is safe (returns :ok)" do
      key = {"nonexistent_#{System.unique_integer()}", :ghost, 0}

      # Should not raise, just return :ok
      assert :ok = AgentRegistry.unregister(key)
    end

    test "unregistering key registered by another process is safe (no effect)" do
      key = {unique_session_id(), :main, 0}
      parent = self()

      # Register from another process
      pid = spawn(fn ->
        :ok = AgentRegistry.register(key)
        send(parent, :registered)
        receive do
          :done -> :ok
        end
      end)

      assert_receive :registered
      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      # Try to unregister from this process (should have no effect)
      :ok = AgentRegistry.unregister(key)

      # Key should still be registered to the other process
      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      send(pid, :done)
    end

    test "multiple unregister calls are idempotent" do
      key = {unique_session_id(), :main, 0}
      :ok = AgentRegistry.register(key)

      :ok = AgentRegistry.unregister(key)
      :ok = AgentRegistry.unregister(key)
      :ok = AgentRegistry.unregister(key)

      assert :error = AgentRegistry.lookup(key)
    end
  end

  # ============================================================================
  # Concurrent Access Tests
  # ============================================================================

  describe "concurrent access" do
    test "multiple processes can register different keys concurrently" do
      session_id = unique_session_id()
      parent = self()
      num_processes = 20

      pids = for i <- 0..(num_processes - 1) do
        spawn(fn ->
          key = {session_id, :worker, i}
          result = AgentRegistry.register(key)
          send(parent, {:registered, i, result, self()})
          receive do
            :done -> :ok
          end
        end)
      end

      # Collect all results
      results = for _ <- 0..(num_processes - 1) do
        receive do
          {:registered, i, result, pid} -> {i, result, pid}
        after
          5000 -> flunk("Timeout waiting for registration")
        end
      end

      # All should succeed
      for {i, result, pid} <- results do
        assert result == :ok, "Registration #{i} failed: #{inspect(result)}"
        key = {session_id, :worker, i}
        assert {:ok, ^pid} = AgentRegistry.lookup(key)
      end

      # Cleanup
      for pid <- pids, do: send(pid, :done)
    end

    test "concurrent lookups return consistent results" do
      session_id = unique_session_id()
      key = {session_id, :main, 0}
      parent = self()
      :ok = AgentRegistry.register(key)
      expected_pid = self()

      # Spawn multiple processes doing lookups
      for _ <- 1..50 do
        spawn(fn ->
          result = AgentRegistry.lookup(key)
          send(parent, {:lookup_result, result})
        end)
      end

      # All should return the same pid
      for _ <- 1..50 do
        receive do
          {:lookup_result, result} ->
            assert result == {:ok, expected_pid}
        after
          5000 -> flunk("Timeout waiting for lookup result")
        end
      end
    end

    test "race condition: multiple processes try to register same key" do
      key = {unique_session_id(), :contested, 0}
      parent = self()
      num_processes = 10

      # Start all processes at approximately the same time
      for _ <- 1..num_processes do
        spawn(fn ->
          result = AgentRegistry.register(key)
          send(parent, {:result, result, self()})
          receive do
            :done -> :ok
          end
        end)
      end

      # Collect results
      results = for _ <- 1..num_processes do
        receive do
          {:result, result, pid} -> {result, pid}
        after
          5000 -> flunk("Timeout")
        end
      end

      # Exactly one should succeed
      successful = Enum.filter(results, fn {result, _pid} -> result == :ok end)
      failed = Enum.filter(results, fn {result, _pid} -> match?({:error, _}, result) end)

      assert length(successful) == 1, "Expected exactly 1 success, got #{length(successful)}"
      assert length(failed) == num_processes - 1

      # The winner's pid should match what lookup returns
      [{:ok, winner_pid}] = Enum.map(successful, fn {_result, pid} -> {:ok, pid} end)
      assert {:ok, ^winner_pid} = AgentRegistry.lookup(key)
    end

    test "registration and deregistration interleaving" do
      session_id = unique_session_id()
      parent = self()

      # Process A registers, then unregisters
      spawn(fn ->
        key = {session_id, :main, 0}
        :ok = AgentRegistry.register(key)
        send(parent, {:a_registered, self()})
        receive do
          :unregister ->
            :ok = AgentRegistry.unregister(key)
            send(parent, :a_unregistered)
        end
        receive do
          :done -> :ok
        end
      end)

      assert_receive {:a_registered, pid_a}
      assert {:ok, ^pid_a} = AgentRegistry.lookup({session_id, :main, 0})

      # Tell A to unregister
      send(pid_a, :unregister)
      assert_receive :a_unregistered

      # Now B can register the same key
      spawn(fn ->
        key = {session_id, :main, 0}
        result = AgentRegistry.register(key)
        send(parent, {:b_result, result, self()})
        receive do
          :done -> :ok
        end
      end)

      assert_receive {:b_result, :ok, pid_b}
      assert {:ok, ^pid_b} = AgentRegistry.lookup({session_id, :main, 0})
    end
  end

  # ============================================================================
  # Error Handling for Missing Agents Tests
  # ============================================================================

  describe "error handling for missing agents" do
    test "lookup returns :error for never-registered key" do
      key = {"never_registered_#{System.unique_integer()}", :phantom, 0}
      assert :error = AgentRegistry.lookup(key)
    end

    test "lookup_with_metadata returns :error for never-registered key" do
      key = {"never_registered_#{System.unique_integer()}", :phantom, 0}
      assert :error = AgentRegistry.lookup_with_metadata(key)
    end

    test "lookup returns :error after process crash" do
      key = {unique_session_id(), :crasher, 0}
      parent = self()

      pid = spawn(fn ->
        :ok = AgentRegistry.register(key)
        send(parent, :registered)
        # Crash intentionally
        receive do
          :crash -> exit(:crash)
        end
      end)

      assert_receive :registered
      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      # Make the process crash
      send(pid, :crash)
      Process.sleep(50)

      assert :error = AgentRegistry.lookup(key)
    end

    test "lookup returns :error after normal process exit" do
      key = {unique_session_id(), :normal_exit, 0}
      parent = self()

      spawn(fn ->
        :ok = AgentRegistry.register(key)
        send(parent, :registered)
        # Normal exit
      end)

      assert_receive :registered
      Process.sleep(50)

      assert :error = AgentRegistry.lookup(key)
    end
  end

  # ============================================================================
  # Listing and Counting Tests
  # ============================================================================

  describe "list/0" do
    test "returns empty list when no agents registered" do
      # Note: Other tests might have agents registered, so we can't assert empty
      # Instead, we verify the structure of results
      result = AgentRegistry.list()
      assert is_list(result)
    end

    test "returns registered agents with their keys and pids" do
      session_id = unique_session_id()
      key = {session_id, :test_list, 0}
      :ok = AgentRegistry.register(key)

      results = AgentRegistry.list()

      # Find our registration
      our_entry = Enum.find(results, fn {k, _pid} -> k == key end)
      assert our_entry != nil
      {^key, pid} = our_entry
      assert pid == self()
    end
  end

  describe "list_by_session/1" do
    test "returns empty list for non-existent session" do
      session_id = "nonexistent_session_#{System.unique_integer()}"
      assert [] = AgentRegistry.list_by_session(session_id)
    end

    test "returns all agents for a session" do
      session_id = unique_session_id()
      parent = self()

      # Register multiple agents from different processes
      pids = for {role, _i} <- Enum.with_index([:main, :research, :implement]) do
        spawn(fn ->
          key = {session_id, role, 0}
          :ok = AgentRegistry.register(key)
          send(parent, {:registered, role, self()})
          receive do
            :done -> :ok
          end
        end)
      end

      # Wait for all registrations
      registered = for _ <- 1..3 do
        receive do
          {:registered, role, pid} -> {role, pid}
        after
          5000 -> flunk("Timeout")
        end
      end

      agents = AgentRegistry.list_by_session(session_id)
      assert length(agents) == 3

      # Verify each agent is in the list
      for {role, expected_pid} <- registered do
        entry = Enum.find(agents, fn {r, _index, _pid} -> r == role end)
        assert entry != nil, "Expected to find role #{role}"
        {^role, 0, pid} = entry
        assert pid == expected_pid
      end

      # Cleanup
      for pid <- pids, do: send(pid, :done)
    end

    test "does not return agents from other sessions" do
      session1 = unique_session_id()
      session2 = unique_session_id()

      :ok = AgentRegistry.register({session1, :main, 0})

      parent = self()
      pid2 = spawn(fn ->
        :ok = AgentRegistry.register({session2, :main, 0})
        send(parent, :registered)
        receive do
          :done -> :ok
        end
      end)

      assert_receive :registered

      agents1 = AgentRegistry.list_by_session(session1)
      agents2 = AgentRegistry.list_by_session(session2)

      # session1 should only have one agent (self)
      assert length(agents1) == 1
      [{:main, 0, pid1}] = agents1
      assert pid1 == self()

      # session2 should only have one agent (pid2)
      assert length(agents2) == 1
      [{:main, 0, ^pid2}] = agents2

      send(pid2, :done)
    end
  end

  describe "list_by_role/1" do
    test "returns empty list for non-existent role" do
      assert [] = AgentRegistry.list_by_role(:nonexistent_role_xyz)
    end

    test "returns all agents with specific role across sessions" do
      session1 = unique_session_id()
      session2 = unique_session_id()
      role = :special_test_role
      parent = self()

      # Register same role in two different sessions
      :ok = AgentRegistry.register({session1, role, 0})

      pid2 = spawn(fn ->
        :ok = AgentRegistry.register({session2, role, 0})
        send(parent, :registered)
        receive do
          :done -> :ok
        end
      end)

      assert_receive :registered

      agents = AgentRegistry.list_by_role(role)

      # Should have at least 2 (there might be more from other tests)
      assert length(agents) >= 2

      # Find our registrations
      entry1 = Enum.find(agents, fn {sid, _idx, _pid} -> sid == session1 end)
      entry2 = Enum.find(agents, fn {sid, _idx, _pid} -> sid == session2 end)

      assert entry1 != nil
      assert entry2 != nil

      {^session1, 0, self_pid} = entry1
      assert self_pid == self()

      {^session2, 0, ^pid2} = entry2

      send(pid2, :done)
    end
  end

  describe "count/0" do
    test "returns the number of registered agents" do
      session_id = unique_session_id()
      :ok = AgentRegistry.register({session_id, :counter_test, 0})

      assert AgentRegistry.count_by_session(session_id) == 1
      assert is_integer(AgentRegistry.count())

      :ok = AgentRegistry.unregister({session_id, :counter_test, 0})

      assert AgentRegistry.count_by_session(session_id) == 0
    end

    test "count increases with each registration" do
      session_id = unique_session_id()

      for i <- 0..4 do
        :ok = AgentRegistry.register({session_id, :sequential, i})
        assert AgentRegistry.count_by_session(session_id) == i + 1
      end
    end
  end

  describe "count_by_session/1" do
    test "returns 0 for non-existent session" do
      assert 0 = AgentRegistry.count_by_session("nonexistent_#{System.unique_integer()}")
    end

    test "returns correct count for session" do
      session_id = unique_session_id()
      parent = self()

      pids = for role <- [:main, :research, :implement] do
        spawn(fn ->
          :ok = AgentRegistry.register({session_id, role, 0})
          send(parent, :registered)
          receive do
            :done -> :ok
          end
        end)
      end

      for _ <- 1..3, do: assert_receive(:registered)

      assert AgentRegistry.count_by_session(session_id) == 3

      # Cleanup
      for pid <- pids, do: send(pid, :done)
    end
  end

  # ============================================================================
  # Via Tuple Tests
  # ============================================================================

  describe "via/1" do
    test "returns a valid via tuple" do
      key = {unique_session_id(), :main, 0}

      via = AgentRegistry.via(key)

      assert {:via, Registry, {AgentCore.AgentRegistry, ^key}} = via
    end

    test "via tuple can be used for GenServer registration" do
      key = {unique_session_id(), :genserver_test, 0}
      via = AgentRegistry.via(key)

      # Start a simple Agent (not AgentCore.Agent, just Elixir's Agent)
      {:ok, pid} = Agent.start_link(fn -> :initial_state end, name: via)

      # Should be findable via registry
      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      # Cleanup
      Agent.stop(pid)
    end
  end

  describe "registry_name/0" do
    test "returns the registry module name" do
      assert AgentRegistry.registry_name() == AgentCore.AgentRegistry
    end
  end

  # ============================================================================
  # Edge Cases and Boundary Tests
  # ============================================================================

  describe "edge cases" do
    test "handles empty string session_id" do
      key = {"", :main, 0}
      :ok = AgentRegistry.register(key)

      assert {:ok, pid} = AgentRegistry.lookup(key)
      assert pid == self()

      :ok = AgentRegistry.unregister(key)
    end

    test "handles very long session_id" do
      long_session_id = String.duplicate("a", 10_000)
      key = {long_session_id, :main, 0}

      :ok = AgentRegistry.register(key)
      assert {:ok, _pid} = AgentRegistry.lookup(key)

      :ok = AgentRegistry.unregister(key)
    end

    test "handles special characters in session_id" do
      special_session_id = "session-with_special.chars:and/slashes?query=1&more=2"
      key = {special_session_id, :main, 0}

      :ok = AgentRegistry.register(key)
      assert {:ok, _pid} = AgentRegistry.lookup(key)

      :ok = AgentRegistry.unregister(key)
    end

    test "handles large index values" do
      key = {unique_session_id(), :main, 999_999_999}

      :ok = AgentRegistry.register(key)
      assert {:ok, _pid} = AgentRegistry.lookup(key)

      :ok = AgentRegistry.unregister(key)
    end

    test "handles atom roles with special characters" do
      key = {unique_session_id(), :"role@with.dots", 0}

      :ok = AgentRegistry.register(key)
      assert {:ok, _pid} = AgentRegistry.lookup(key)

      :ok = AgentRegistry.unregister(key)
    end
  end

  # ============================================================================
  # Process Lifecycle Tests
  # ============================================================================

  describe "process lifecycle" do
    test "registration is automatically cleaned up when process terminates" do
      key = {unique_session_id(), :lifecycle, 0}
      parent = self()

      pid = spawn(fn ->
        :ok = AgentRegistry.register(key)
        send(parent, :registered)
        receive do
          :exit -> :ok
        end
      end)

      assert_receive :registered
      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      # Monitor and terminate
      ref = Process.monitor(pid)
      send(pid, :exit)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # Give registry time to clean up
      Process.sleep(50)

      assert :error = AgentRegistry.lookup(key)
    end

    test "linked process termination cleans up registration" do
      key = {unique_session_id(), :linked, 0}
      parent = self()

      # Spawn a process that registers, then links to a child that will die
      pid = spawn(fn ->
        Process.flag(:trap_exit, false)
        :ok = AgentRegistry.register(key)
        send(parent, {:registered, self()})

        child = spawn_link(fn ->
          receive do
            :die -> exit(:intentional)
          end
        end)

        send(parent, {:child, child})

        # This process will die when child dies (due to link)
        receive do
          :never -> :ok
        end
      end)

      assert_receive {:registered, ^pid}
      assert_receive {:child, child_pid}

      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      # Kill the child, which will take down the parent
      ref = Process.monitor(pid)
      send(child_pid, :die)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}
      assert reason in [:intentional, :noproc]

      Process.sleep(50)

      assert :error = AgentRegistry.lookup(key)
    end
  end
end
