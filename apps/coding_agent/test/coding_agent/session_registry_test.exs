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

      # The registry processes the termination asynchronously
      assert wait_until(fn -> SessionRegistry.lookup(session_id) == :error end, 2_000)
    end
  end

  describe "list_ids/0" do
    test "updates when sessions are added and removed" do
      session_id = "dynamic_test_#{:rand.uniform(100_000)}"

      # Add session
      via = SessionRegistry.via(session_id)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)

      assert session_id in SessionRegistry.list_ids()

      # Remove session
      Agent.stop(pid)

      assert wait_until(fn -> session_id not in SessionRegistry.list_ids() end, 5_000)
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
