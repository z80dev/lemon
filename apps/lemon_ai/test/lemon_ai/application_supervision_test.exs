defmodule LemonAi.ApplicationSupervisionTest do
  @moduledoc """
  Tests the application child set, task execution and registry operations.
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
    test "supervisor has all expected children" do
      children = Supervisor.which_children(LemonAi.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert LemonAi.StreamTaskSupervisor in child_ids
      assert LemonAi.RateLimiterRegistry in child_ids
      assert LemonAi.CircuitBreakerRegistry in child_ids
      assert LemonAi.ProviderSupervisor in child_ids
      assert LemonAi.CallDispatcher in child_ids
    end
  end

  describe "LemonAi.StreamTaskSupervisor" do
    test "can start async tasks" do
      task =
        Task.Supervisor.async_nolink(LemonAi.StreamTaskSupervisor, fn ->
          :stream_result
        end)

      assert {:ok, :stream_result} = Task.yield(task, 1000)
    end
  end

  describe "LemonAi.RateLimiterRegistry" do
    test "can register and lookup rate limiters" do
      key = :"test_provider_#{System.unique_integer()}"

      # Register via the registry
      {:ok, _} = Registry.register(LemonAi.RateLimiterRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(LemonAi.RateLimiterRegistry, key)
    end
  end

  describe "LemonAi.CircuitBreakerRegistry" do
    test "can register and lookup circuit breakers" do
      key = :"test_provider_#{System.unique_integer()}"

      # Register via the registry
      {:ok, _} = Registry.register(LemonAi.CircuitBreakerRegistry, key, %{test: true})

      # Lookup should work
      assert [{_pid, %{test: true}}] = Registry.lookup(LemonAi.CircuitBreakerRegistry, key)
    end
  end
end
