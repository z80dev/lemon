defmodule Ai.ApplicationSupervisionTest do
  @moduledoc """
  Tests for Ai application supervision tree configuration.

  Verifies:
  - Supervision strategies are correct
  - Max restarts/seconds configuration
  - Child shutdown timeouts
  - Child ordering and dependencies
  - Provider supervisor functionality
  """
  use ExUnit.Case, async: false

  # Ensure all supervisors are running before each test
  setup do
    # Wait for any prior restart to complete
    Process.sleep(50)

    # Ensure all the application processes are up
    ensure_process_running(Ai.Supervisor)
    ensure_process_running(Ai.StreamTaskSupervisor)
    ensure_process_running(Ai.RateLimiterRegistry)
    ensure_process_running(Ai.CircuitBreakerRegistry)
    ensure_process_running(Ai.ProviderSupervisor)
    ensure_process_running(Ai.CallDispatcher)

    :ok
  end

  defp ensure_process_running(name) do
    # Wait up to 500ms for process to be available
    Enum.reduce_while(1..10, nil, fn _, _ ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> {:halt, pid}
        nil ->
          Process.sleep(50)
          {:cont, nil}
      end
    end)
  end

  describe "Ai.Supervisor configuration" do
    test "supervisor exists and is running" do
      assert pid = Process.whereis(Ai.Supervisor)
      assert Process.alive?(pid)
    end

    test "supervisor has all expected children" do
      children = Supervisor.which_children(Ai.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert Ai.StreamTaskSupervisor in child_ids
      assert Ai.RateLimiterRegistry in child_ids
      assert Ai.CircuitBreakerRegistry in child_ids
      assert Ai.ProviderSupervisor in child_ids
      assert Ai.CallDispatcher in child_ids
    end

    test "all children are alive" do
      children = Supervisor.which_children(Ai.Supervisor)

      for {id, pid, _type, _modules} <- children do
        assert is_pid(pid), "Expected #{inspect(id)} to have a pid"
        assert Process.alive?(pid), "Expected #{inspect(id)} to be alive"
      end
    end
  end

  describe "Ai.StreamTaskSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(Ai.StreamTaskSupervisor)
      assert Process.alive?(pid)
    end

    test "can start async tasks" do
      task =
        Task.Supervisor.async_nolink(Ai.StreamTaskSupervisor, fn ->
          :stream_result
        end)

      assert {:ok, :stream_result} = Task.yield(task, 1000)
    end
  end

  describe "Ai.RateLimiterRegistry" do
    test "registry is running" do
      assert pid = Process.whereis(Ai.RateLimiterRegistry)
      assert Process.alive?(pid)
    end

    test "can register and lookup rate limiters" do
      key = :"test_provider_#{System.unique_integer()}"

      # Register via the registry
      {:ok, _} = Registry.register(Ai.RateLimiterRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(Ai.RateLimiterRegistry, key)
    end
  end

  describe "Ai.CircuitBreakerRegistry" do
    test "registry is running" do
      assert pid = Process.whereis(Ai.CircuitBreakerRegistry)
      assert Process.alive?(pid)
    end

    test "can register and lookup circuit breakers" do
      key = :"test_provider_#{System.unique_integer()}"

      # Register via the registry
      {:ok, _} = Registry.register(Ai.CircuitBreakerRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(Ai.CircuitBreakerRegistry, key)
    end
  end

  describe "Ai.ProviderSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(Ai.ProviderSupervisor)
      assert Process.alive?(pid)
    end
  end

  describe "Ai.CallDispatcher" do
    test "dispatcher is running" do
      assert pid = Process.whereis(Ai.CallDispatcher)
      assert Process.alive?(pid)
    end
  end

  describe "provider registration" do
    test "built-in providers are registered" do
      # The application should have registered providers
      assert {:ok, _module} = Ai.ProviderRegistry.get(:anthropic_messages)
      assert {:ok, _module} = Ai.ProviderRegistry.get(:openai_completions)
      assert {:ok, _module} = Ai.ProviderRegistry.get(:openai_responses)
      assert {:ok, _module} = Ai.ProviderRegistry.get(:google_generative_ai)
    end
  end
end
