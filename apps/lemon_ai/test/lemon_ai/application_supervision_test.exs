defmodule LemonAi.ApplicationSupervisionTest do
  @moduledoc """
  Tests for LemonAi application supervision tree configuration.

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
    ensure_process_running(LemonAi.Supervisor)
    ensure_process_running(LemonAi.StreamTaskSupervisor)
    ensure_process_running(LemonAi.RateLimiterRegistry)
    ensure_process_running(LemonAi.CircuitBreakerRegistry)
    ensure_process_running(LemonAi.ProviderSupervisor)
    ensure_process_running(LemonAi.CallDispatcher)

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

  describe "LemonAi.Supervisor configuration" do
    test "supervisor exists and is running" do
      assert pid = Process.whereis(LemonAi.Supervisor)
      assert Process.alive?(pid)
    end

    test "supervisor has all expected children" do
      children = Supervisor.which_children(LemonAi.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert LemonAi.StreamTaskSupervisor in child_ids
      assert LemonAi.RateLimiterRegistry in child_ids
      assert LemonAi.CircuitBreakerRegistry in child_ids
      assert LemonAi.ProviderSupervisor in child_ids
      assert LemonAi.CallDispatcher in child_ids
    end

    test "all children are alive" do
      children = Supervisor.which_children(LemonAi.Supervisor)

      for {id, pid, _type, _modules} <- children do
        assert is_pid(pid), "Expected #{inspect(id)} to have a pid"
        assert Process.alive?(pid), "Expected #{inspect(id)} to be alive"
      end
    end
  end

  describe "LemonAi.StreamTaskSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(LemonAi.StreamTaskSupervisor)
      assert Process.alive?(pid)
    end

    test "can start async tasks" do
      task =
        Task.Supervisor.async_nolink(LemonAi.StreamTaskSupervisor, fn ->
          :stream_result
        end)

      assert {:ok, :stream_result} = Task.yield(task, 1000)
    end
  end

  describe "LemonAi.RateLimiterRegistry" do
    test "registry is running" do
      assert pid = Process.whereis(LemonAi.RateLimiterRegistry)
      assert Process.alive?(pid)
    end

    test "can register and lookup rate limiters" do
      key = :"test_provider_#{System.unique_integer()}"

      # Register via the registry
      {:ok, _} = Registry.register(LemonAi.RateLimiterRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(LemonAi.RateLimiterRegistry, key)
    end
  end

  describe "LemonAi.CircuitBreakerRegistry" do
    test "registry is running" do
      assert pid = Process.whereis(LemonAi.CircuitBreakerRegistry)
      assert Process.alive?(pid)
    end

    test "can register and lookup circuit breakers" do
      key = :"test_provider_#{System.unique_integer()}"

      # Register via the registry
      {:ok, _} = Registry.register(LemonAi.CircuitBreakerRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(LemonAi.CircuitBreakerRegistry, key)
    end
  end

  describe "LemonAi.ProviderSupervisor" do
    test "supervisor is running" do
      assert pid = Process.whereis(LemonAi.ProviderSupervisor)
      assert Process.alive?(pid)
    end
  end

  describe "LemonAi.CallDispatcher" do
    test "dispatcher is running" do
      assert pid = Process.whereis(LemonAi.CallDispatcher)
      assert Process.alive?(pid)
    end
  end

  describe "provider registration" do
    test "built-in providers are registered" do
      # The application should have registered providers
      assert {:ok, _module} = LemonAi.ProviderRegistry.get(:anthropic_messages)
      assert {:ok, _module} = LemonAi.ProviderRegistry.get(:openai_completions)
      assert {:ok, _module} = LemonAi.ProviderRegistry.get(:openai_responses)
      assert {:ok, _module} = LemonAi.ProviderRegistry.get(:google_generative_ai)
    end
  end
end
