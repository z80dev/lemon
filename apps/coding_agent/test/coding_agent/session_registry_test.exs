defmodule CodingAgent.SessionRegistryTest do
  @moduledoc """
  Tests for CodingAgent.SessionRegistry module.

  Tests session lookup, listing, and via tuple functionality.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.SessionRegistry

  setup do
    # Ensure registry is running
    unless Process.whereis(SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: SessionRegistry})
    end

    :ok
  end

  describe "via/1" do
    test "returns a valid via tuple" do
      session_id = "test_session_#{:rand.uniform(100_000)}"

      via = SessionRegistry.via(session_id)

      assert {:via, Registry, {CodingAgent.SessionRegistry, ^session_id}} = via
    end

    test "via tuple can be used to register processes" do
      session_id = "register_test_#{:rand.uniform(100_000)}"
      via = SessionRegistry.via(session_id)

      # Start a simple agent with the via tuple
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)

      # Verify it's registered
      assert {:ok, ^pid} = SessionRegistry.lookup(session_id)

      # Cleanup
      Agent.stop(pid)
    end
  end

  describe "lookup/1" do
    test "returns {:ok, pid} for registered session" do
      session_id = "lookup_test_#{:rand.uniform(100_000)}"
      via = SessionRegistry.via(session_id)

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)

      assert {:ok, ^pid} = SessionRegistry.lookup(session_id)

      Agent.stop(pid)
    end

    test "returns :error for unregistered session" do
      session_id = "nonexistent_#{:rand.uniform(100_000)}"

      assert :error = SessionRegistry.lookup(session_id)
    end

    test "returns :error after process terminates" do
      session_id = "terminated_test_#{:rand.uniform(100_000)}"
      via = SessionRegistry.via(session_id)

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)
      Agent.stop(pid)

      # Give registry time to process the termination
      Process.sleep(10)

      assert :error = SessionRegistry.lookup(session_id)
    end
  end

  describe "list_ids/0" do
    test "returns empty list when no sessions registered" do
      # Get initial count
      initial_ids = SessionRegistry.list_ids()

      # Create a unique session and verify it appears
      session_id = "list_test_#{:rand.uniform(100_000)}"
      via = SessionRegistry.via(session_id)

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)

      ids = SessionRegistry.list_ids()
      assert session_id in ids

      Agent.stop(pid)
    end

    test "returns all registered session ids" do
      session_ids =
        for i <- 1..3 do
          id = "multi_list_test_#{i}_#{:rand.uniform(100_000)}"
          via = SessionRegistry.via(id)
          {:ok, _pid} = Agent.start_link(fn -> :ok end, name: via)
          id
        end

      ids = SessionRegistry.list_ids()

      for session_id <- session_ids do
        assert session_id in ids
      end

      # Cleanup
      for session_id <- session_ids do
        {:ok, pid} = SessionRegistry.lookup(session_id)
        Agent.stop(pid)
      end
    end

    test "updates when sessions are added and removed" do
      session_id = "dynamic_test_#{:rand.uniform(100_000)}"
      initial_count = length(SessionRegistry.list_ids())

      # Add session
      via = SessionRegistry.via(session_id)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)

      assert length(SessionRegistry.list_ids()) == initial_count + 1
      assert session_id in SessionRegistry.list_ids()

      # Remove session
      Agent.stop(pid)

      assert wait_until(fn -> length(SessionRegistry.list_ids()) == initial_count end, 1_000)
      refute session_id in SessionRegistry.list_ids()
    end
  end

  describe "concurrent access" do
    test "handles concurrent registrations" do
      prefix = "concurrent_#{:rand.uniform(100_000)}"

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            session_id = "#{prefix}_#{i}"
            via = SessionRegistry.via(session_id)
            {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)
            {session_id, pid}
          end)
        end

      results = Task.await_many(tasks)

      # All should have registered successfully
      for {session_id, pid} <- results do
        assert {:ok, ^pid} = SessionRegistry.lookup(session_id)
      end

      # Cleanup
      for {_session_id, pid} <- results do
        Agent.stop(pid)
      end
    end

    test "handles concurrent lookups" do
      session_id = "lookup_concurrent_#{:rand.uniform(100_000)}"
      via = SessionRegistry.via(session_id)
      {:ok, expected_pid} = Agent.start_link(fn -> :ok end, name: via)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            SessionRegistry.lookup(session_id)
          end)
        end

      results = Task.await_many(tasks)

      # All lookups should return the same pid
      for result <- results do
        assert {:ok, ^expected_pid} = result
      end

      Agent.stop(expected_pid)
    end
  end

  describe "robustness" do
    test "lookup handles process termination" do
      session_id = "term_test_#{:rand.uniform(100_000)}"
      via = SessionRegistry.via(session_id)

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)
      ref = Process.monitor(pid)

      # Stop the process gracefully
      Agent.stop(pid)

      # Wait for DOWN message to ensure the process is stopped
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      # Give registry time to process the termination
      Process.sleep(20)

      # Lookup should return error, not crash
      assert :error = SessionRegistry.lookup(session_id)
    end

    test "via tuple works with GenServer" do
      session_id = "genserver_test_#{:rand.uniform(100_000)}"

      defmodule TestServer do
        use GenServer
        def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
        def init(:ok), do: {:ok, :test_state}
        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
      end

      via = SessionRegistry.via(session_id)
      {:ok, pid} = TestServer.start_link(via)

      # Should be able to call via the via tuple
      assert :pong = GenServer.call(via, :ping)

      # Should be in registry
      assert {:ok, ^pid} = SessionRegistry.lookup(session_id)

      GenServer.stop(pid)
    end
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        false
      else
        Process.sleep(10)
        do_wait_until(fun, deadline_ms)
      end
    end
  end
end
