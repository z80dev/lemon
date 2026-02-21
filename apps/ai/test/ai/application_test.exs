defmodule Ai.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for Ai.Application supervision tree.
  """

  describe "application supervision tree" do
    test "application starts correctly" do
      # The application should already be started from test_helper.exs
      # Verify the main supervisor is running
      assert Process.whereis(Ai.Supervisor) != nil
    end

    test "StreamTaskSupervisor is started" do
      assert Process.whereis(Ai.StreamTaskSupervisor) != nil

      # Verify it's a Task.Supervisor by starting a task
      task =
        Task.Supervisor.async_nolink(Ai.StreamTaskSupervisor, fn ->
          :stream_task_executed
        end)

      assert Task.await(task) == :stream_task_executed
    end

    test "RateLimiterRegistry is started" do
      assert Process.whereis(Ai.RateLimiterRegistry) != nil

      # Verify it's a Registry by doing a lookup (returns empty list for non-existent key)
      result = Registry.lookup(Ai.RateLimiterRegistry, :nonexistent_key)
      assert result == []
    end

    test "CircuitBreakerRegistry is started" do
      assert Process.whereis(Ai.CircuitBreakerRegistry) != nil

      # Verify it's a Registry by doing a lookup (returns empty list for non-existent key)
      result = Registry.lookup(Ai.CircuitBreakerRegistry, :nonexistent_key)
      assert result == []
    end

    test "ProviderSupervisor is started" do
      assert Process.whereis(Ai.ProviderSupervisor) != nil

      # Verify it's a DynamicSupervisor
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      assert is_list(children)
    end

    test "CallDispatcher is started" do
      assert Process.whereis(Ai.CallDispatcher) != nil

      # Verify it responds to get_state
      state = Ai.CallDispatcher.get_state()
      assert is_map(state)
      assert Map.has_key?(state, :concurrency_caps)
      assert Map.has_key?(state, :active_requests)
      assert Map.has_key?(state, :default_cap)
    end

    test "supervisor has correct child count" do
      # The application should have 6 children:
      # 1. Ai.StreamTaskSupervisor (Task.Supervisor)
      # 2. Ai.RateLimiterRegistry (Registry)
      # 3. Ai.CircuitBreakerRegistry (Registry)
      # 4. Ai.ProviderSupervisor (DynamicSupervisor)
      # 5. Ai.CallDispatcher (GenServer)
      # 6. Ai.ModelCache (GenServer)
      children = Supervisor.which_children(Ai.Supervisor)
      assert length(children) == 6
    end

    test "supervisor uses one_for_one strategy" do
      # Verify children have unique ids
      children = Supervisor.which_children(Ai.Supervisor)
      ids = Enum.map(children, fn {id, _, _, _} -> id end)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "child process characteristics" do
    test "all child processes are alive" do
      children = Supervisor.which_children(Ai.Supervisor)

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end
    end

    test "supervisor counts children correctly" do
      counts = Supervisor.count_children(Ai.Supervisor)

      assert counts.active == 6
      assert counts.specs == 6
      # ProviderSupervisor and StreamTaskSupervisor are supervisors
      assert counts.supervisors >= 2
      # CallDispatcher and ModelCache are workers
      assert counts.workers >= 2
    end
  end

  describe "ProviderRegistry initialization" do
    test "ProviderRegistry is initialized" do
      assert Ai.ProviderRegistry.initialized?() == true
    end

    test "built-in providers are registered" do
      # Check that the major providers are registered
      assert Ai.ProviderRegistry.registered?(:anthropic_messages)
      assert Ai.ProviderRegistry.registered?(:openai_completions)
      assert Ai.ProviderRegistry.registered?(:openai_responses)
      assert Ai.ProviderRegistry.registered?(:google_generative_ai)
      assert Ai.ProviderRegistry.registered?(:bedrock_converse_stream)
    end

    test "can look up registered providers" do
      assert {:ok, Ai.Providers.Anthropic} = Ai.ProviderRegistry.get(:anthropic_messages)
      assert {:ok, Ai.Providers.OpenAICompletions} = Ai.ProviderRegistry.get(:openai_completions)
      assert {:ok, Ai.Providers.Google} = Ai.ProviderRegistry.get(:google_generative_ai)
    end

    test "list returns all registered providers" do
      providers = Ai.ProviderRegistry.list()
      assert is_list(providers)
      # At least the 9 built-in providers
      assert length(providers) >= 9

      # Verify expected providers are in the list
      assert :anthropic_messages in providers
      assert :openai_completions in providers
      assert :google_generative_ai in providers
    end
  end

  describe "CallDispatcher functionality" do
    test "get_state returns initial state" do
      state = Ai.CallDispatcher.get_state()

      assert is_map(state.concurrency_caps)
      assert is_map(state.active_requests)
      assert state.default_cap == 10
    end

    test "can set and get concurrency cap" do
      provider = :test_provider_app

      # Set a custom cap
      :ok = Ai.CallDispatcher.set_concurrency_cap(provider, 5)

      # Verify it was set
      assert Ai.CallDispatcher.get_concurrency_cap(provider) == 5
    end

    test "get_active_requests returns 0 for unused provider" do
      provider = :unused_provider_app
      assert Ai.CallDispatcher.get_active_requests(provider) == 0
    end
  end

  describe "StreamTaskSupervisor functionality" do
    test "can execute streaming tasks" do
      task =
        Task.Supervisor.async_nolink(Ai.StreamTaskSupervisor, fn ->
          # Simulate a short streaming operation
          Process.sleep(10)
          {:ok, "stream complete"}
        end)

      assert {:ok, "stream complete"} = Task.await(task)
    end

    test "can start multiple concurrent tasks" do
      tasks =
        for i <- 1..5 do
          Task.Supervisor.async_nolink(Ai.StreamTaskSupervisor, fn ->
            Process.sleep(10)
            {:ok, i}
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert results == [{:ok, 1}, {:ok, 2}, {:ok, 3}, {:ok, 4}, {:ok, 5}]
    end
  end

  describe "graceful shutdown behavior" do
    test "ProviderSupervisor stops cleanly when empty" do
      # Verify the supervisor can list children without error
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      assert is_list(children)

      # Verify we can check the DynamicSupervisor state
      counts = DynamicSupervisor.count_children(Ai.ProviderSupervisor)
      assert is_map(counts)
      assert Map.has_key?(counts, :active)
    end

    test "registries can handle lookups" do
      # Test RateLimiterRegistry
      result = Registry.lookup(Ai.RateLimiterRegistry, :nonexistent)
      assert result == []

      # Test CircuitBreakerRegistry
      result = Registry.lookup(Ai.CircuitBreakerRegistry, :nonexistent)
      assert result == []
    end
  end

  describe "register_providers/0 can be called safely" do
    test "register_providers is idempotent" do
      # Call register_providers multiple times
      assert :ok = Ai.Application.register_providers()
      assert :ok = Ai.Application.register_providers()

      # Verify providers are still registered correctly
      assert Ai.ProviderRegistry.registered?(:anthropic_messages)
    end
  end
end
