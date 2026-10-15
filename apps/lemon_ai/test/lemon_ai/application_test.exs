defmodule LemonAi.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for LemonAi.Application supervision tree.
  """

  describe "application supervision tree" do
    test "StreamTaskSupervisor is started" do
      assert Process.whereis(LemonAi.StreamTaskSupervisor) != nil

      # Verify it's a Task.Supervisor by starting a task
      task =
        Task.Supervisor.async_nolink(LemonAi.StreamTaskSupervisor, fn ->
          :stream_task_executed
        end)

      assert Task.await(task) == :stream_task_executed
    end
  end

  describe "ProviderRegistry initialization" do
    test "built-in providers are registered" do
      # Check that the major providers are registered
      assert LemonAi.ProviderRegistry.registered?(:anthropic_messages)
      assert LemonAi.ProviderRegistry.registered?(:openai_completions)
      assert LemonAi.ProviderRegistry.registered?(:openai_responses)
      assert LemonAi.ProviderRegistry.registered?(:google_generative_ai)
      assert LemonAi.ProviderRegistry.registered?(:bedrock_converse_stream)
    end

    test "can look up registered providers" do
      assert {:ok, LemonAi.Providers.Anthropic} =
               LemonAi.ProviderRegistry.get(:anthropic_messages)

      assert {:ok, LemonAi.Providers.OpenAICompletions} =
               LemonAi.ProviderRegistry.get(:openai_completions)

      assert {:ok, LemonAi.Providers.Google} = LemonAi.ProviderRegistry.get(:google_generative_ai)
    end

    test "list returns all registered providers" do
      providers = LemonAi.ProviderRegistry.list()
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
    test "can set and get concurrency cap" do
      provider = :test_provider_app

      # Set a custom cap
      :ok = LemonAi.CallDispatcher.set_concurrency_cap(provider, 5)

      # Verify it was set
      assert LemonAi.CallDispatcher.get_concurrency_cap(provider) == 5
    end

    test "get_active_requests returns 0 for unused provider" do
      provider = :unused_provider_app
      assert LemonAi.CallDispatcher.get_active_requests(provider) == 0
    end
  end

  describe "StreamTaskSupervisor functionality" do
    test "can execute streaming tasks" do
      task =
        Task.Supervisor.async_nolink(LemonAi.StreamTaskSupervisor, fn ->
          # Simulate a short streaming operation
          Process.sleep(10)
          {:ok, "stream complete"}
        end)

      assert {:ok, "stream complete"} = Task.await(task)
    end

    test "can start multiple concurrent tasks" do
      tasks =
        for i <- 1..5 do
          Task.Supervisor.async_nolink(LemonAi.StreamTaskSupervisor, fn ->
            Process.sleep(10)
            {:ok, i}
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert results == [{:ok, 1}, {:ok, 2}, {:ok, 3}, {:ok, 4}, {:ok, 5}]
    end
  end

  describe "register_providers/0 can be called safely" do
    test "register_providers is idempotent" do
      # Call register_providers multiple times
      assert :ok = LemonAi.Application.register_providers()
      assert :ok = LemonAi.Application.register_providers()

      # Verify providers are still registered correctly
      assert LemonAi.ProviderRegistry.registered?(:anthropic_messages)
    end
  end
end
