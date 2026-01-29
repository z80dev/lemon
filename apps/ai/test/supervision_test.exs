defmodule Ai.SupervisionTest do
  @moduledoc """
  Tests for the supervision tree and task management.
  """

  use ExUnit.Case

  describe "application supervision tree" do
    test "Ai.StreamTaskSupervisor is running" do
      # The task supervisor should be started by the application
      assert Process.whereis(Ai.StreamTaskSupervisor) != nil
    end

    test "Ai.Supervisor is running" do
      assert Process.whereis(Ai.Supervisor) != nil
    end

    test "StreamTaskSupervisor can start tasks" do
      test_pid = self()
      ref = make_ref()

      {:ok, task_pid} =
        Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
          send(test_pid, {:task_ran, ref})
        end)

      assert is_pid(task_pid)
      assert_receive {:task_ran, ^ref}, 1000
    end

    test "StreamTaskSupervisor isolates task failures" do
      # Start a task that will crash
      {:ok, _task_pid} =
        Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
          raise "intentional crash"
        end)

      # Supervisor should still be alive
      Process.sleep(100)
      assert Process.whereis(Ai.StreamTaskSupervisor) != nil
    end

    test "multiple tasks can run concurrently" do
      test_pid = self()

      tasks =
        for i <- 1..10 do
          {:ok, pid} =
            Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
              Process.sleep(50)
              send(test_pid, {:task_done, i})
            end)

          {i, pid}
        end

      # All tasks should be running
      for {_i, pid} <- tasks do
        assert Process.alive?(pid)
      end

      # Wait for all to complete
      for i <- 1..10 do
        assert_receive {:task_done, ^i}, 5000
      end
    end
  end

  describe "provider registry initialization" do
    test "providers are registered on startup" do
      # These should be registered by Ai.Application.register_providers/0
      assert Ai.ProviderRegistry.registered?(:anthropic_messages)
      assert Ai.ProviderRegistry.registered?(:openai_responses)
      assert Ai.ProviderRegistry.registered?(:google_generative_ai)
    end

    test "can look up registered providers" do
      {:ok, anthropic} = Ai.ProviderRegistry.get(:anthropic_messages)
      assert anthropic == Ai.Providers.Anthropic

      {:ok, openai} = Ai.ProviderRegistry.get(:openai_responses)
      assert openai == Ai.Providers.OpenAIResponses
    end
  end
end
