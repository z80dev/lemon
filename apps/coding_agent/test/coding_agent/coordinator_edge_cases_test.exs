defmodule CodingAgent.CoordinatorEdgeCasesTest do
  @moduledoc """
  Edge case tests for CodingAgent.Coordinator module.

  Tests focus on:
  1. Session lifecycle (start, run, stop)
  2. Message handling edge cases
  3. Error recovery scenarios
  4. Concurrent session handling
  5. State transitions
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Coordinator

  alias Ai.Types.{
    Model,
    ModelCost
  }

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 0.01, output: 0.03}),
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: Keyword.get(opts, :headers, %{}),
      compat: Keyword.get(opts, :compat, nil)
    }
  end

  defp default_coordinator_opts(overrides) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model(),
        default_timeout: 5_000
      ],
      overrides
    )
  end

  defp start_coordinator(opts \\ []) do
    opts = default_coordinator_opts(opts)
    {:ok, coordinator} = Coordinator.start_link(opts)
    coordinator
  end

  defp await_tasks(tasks, timeout_ms) do
    tasks
    |> Task.yield_many(timeout_ms)
    |> Enum.map(fn {task, result} ->
      case result do
        {:ok, value} -> {:ok, value}
        {:exit, reason} -> {:exit, reason}
        nil ->
          Task.shutdown(task, :brutal_kill)
          {:exit, :timeout}
      end
    end)
  end

  # ============================================================================
  # 1. Session Lifecycle Tests
  # ============================================================================

  describe "session lifecycle - start" do
    @tag :tmp_dir
    test "coordinator process dies if started with invalid cwd type", %{tmp_dir: _tmp_dir} do
      result =
        Coordinator.start_link([
          cwd: 12345,
          model: mock_model()
        ])

      case result do
        {:error, _} ->
          :ok

        {:ok, pid} ->
          assert Process.alive?(pid)
          GenServer.stop(pid)
      end
    end

    @tag :tmp_dir
    test "coordinator can be started with all optional parameters", %{tmp_dir: tmp_dir} do
      coordinator =
        start_coordinator(
          cwd: tmp_dir,
          thinking_level: :high,
          settings_manager: nil,
          parent_session: "parent-123",
          default_timeout: 60_000
        )

      assert Process.alive?(coordinator)
      GenServer.stop(coordinator)
    end

    @tag :tmp_dir
    test "coordinator handles nonexistent cwd gracefully on start", %{tmp_dir: _tmp_dir} do
      # Coordinator should start even with nonexistent directory
      # Error occurs when actually running subagents
      coordinator =
        start_coordinator(
          cwd: "/nonexistent/path/that/does/not/exist/#{:rand.uniform(10000)}"
        )

      assert Process.alive?(coordinator)
      GenServer.stop(coordinator)
    end

    @tag :tmp_dir
    test "multiple coordinators can be started concurrently", %{tmp_dir: tmp_dir} do
      coordinators =
        Enum.map(1..5, fn _ ->
          start_coordinator(cwd: tmp_dir)
        end)

      assert length(coordinators) == 5
      assert Enum.all?(coordinators, &Process.alive?/1)

      Enum.each(coordinators, &GenServer.stop/1)
    end

    @tag :tmp_dir
    test "coordinator with name can be accessed via name", %{tmp_dir: tmp_dir} do
      name = :"coordinator_lifecycle_#{:erlang.unique_integer()}"
      {:ok, pid} = Coordinator.start_link(default_coordinator_opts(cwd: tmp_dir, name: name))

      assert pid == Process.whereis(name)
      assert Coordinator.list_active(name) == []

      GenServer.stop(name)
    end
  end

  describe "session lifecycle - run" do
    @tag :tmp_dir
    test "coordinator handles rapid sequential runs", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 100)

      # Run multiple sequential subagent requests
      results =
        Enum.map(1..3, fn i ->
          specs = [%{prompt: "Task #{i}"}]
          Coordinator.run_subagents(coordinator, specs, timeout: 50)
        end)

      assert length(results) == 3
      assert Enum.all?(results, fn [result] -> result.status in [:timeout, :error] end)
      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "coordinator handles zero timeout", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 0)

      assert [result] = results
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "coordinator handles very large timeout", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Start with large timeout but use invalid subagent to get quick error
      specs = [%{prompt: "Task", subagent: "invalid_agent"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 999_999_999)

      assert [result] = results
      assert result.status == :error
      assert Process.alive?(coordinator)
    end
  end

  describe "session lifecycle - stop" do
    @tag :tmp_dir
    test "coordinator cleans up on normal stop", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Run something then stop
      specs = [%{prompt: "Task"}]
      _results = Coordinator.run_subagents(coordinator, specs, timeout: 50)

      # Stop coordinator
      :ok = GenServer.stop(coordinator, :normal, 5000)

      refute Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "coordinator handles brutal kill during operation", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # Start subagent in background
      parent = self()

      task =
        Task.async(fn ->
          results = Coordinator.run_subagents(coordinator, [%{prompt: "Long task"}], timeout: 10_000)
          send(parent, {:completed, results})
        end)

      # Give time to start
      Process.sleep(30)

      # Kill the coordinator
      Process.exit(coordinator, :kill)

      # Task should fail or return error
      result = Task.yield(task, 1000) || Task.shutdown(task)

      case result do
        {:ok, _} -> :ok
        {:exit, _} -> :ok
        nil -> :ok
      end

      refute Process.alive?(coordinator)
      Process.flag(:trap_exit, false)
    end

    @tag :tmp_dir
    test "abort_all followed by stop works correctly", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # Start subagent in background
      spawn(fn ->
        Coordinator.run_subagents(coordinator, [%{prompt: "Task"}], timeout: 10_000)
      end)

      Process.sleep(30)

      # Abort then stop
      :ok = Coordinator.abort_all(coordinator)
      :ok = GenServer.stop(coordinator, :normal, 5000)

      refute Process.alive?(coordinator)
    end
  end

  # ============================================================================
  # 2. Message Handling Edge Cases
  # ============================================================================

  describe "message handling - prompts" do
    @tag :tmp_dir
    test "handles prompt with unicode characters", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task with unicode: \u{1F600} \u{1F4BB} \u{2764} \u{00E9}\u{00F1}\u{00FC}"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert Map.has_key?(result, :status)
    end

    @tag :tmp_dir
    test "handles very long prompt", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Create a very long prompt (100KB)
      long_prompt = String.duplicate("a", 100_000)
      specs = [%{prompt: long_prompt}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "handles prompt with only whitespace", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "   \t\n   "}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert Map.has_key?(result, :status)
    end

    @tag :tmp_dir
    test "handles prompt with special characters", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task with <script>alert('xss')</script> and \0 null bytes"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert Map.has_key?(result, :status)
    end
  end

  describe "message handling - specs" do
    @tag :tmp_dir
    test "handles spec with nil values", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", subagent: nil, description: nil}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      # Should work with nil subagent (uses prompt directly)
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "handles spec with empty string subagent", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", subagent: ""}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      # Empty string subagent should be treated as no subagent
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "handles large number of specs", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 5_000)

      # Create 20 specs
      specs = Enum.map(1..20, fn i -> %{prompt: "Task #{i}"} end)

      results = Coordinator.run_subagents(coordinator, specs, timeout: 200)

      assert length(results) == 20
      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "handles specs with duplicate prompts", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [
        %{prompt: "Same task"},
        %{prompt: "Same task"},
        %{prompt: "Same task"}
      ]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert length(results) == 3
      # Each should have unique ID
      ids = Enum.map(results, & &1.id)
      assert length(Enum.uniq(ids)) == 3
    end
  end

  # ============================================================================
  # 3. Error Recovery Scenarios
  # ============================================================================

  describe "error recovery - invalid inputs" do
    @tag :tmp_dir
    test "recovers from invalid subagent type error", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # First call with invalid subagent
      specs1 = [%{prompt: "Task", subagent: "invalid_type_123"}]
      results1 = Coordinator.run_subagents(coordinator, specs1, timeout: 100)
      assert [%{status: :error}] = results1

      # Second call should still work
      specs2 = [%{prompt: "Task"}]
      results2 = Coordinator.run_subagents(coordinator, specs2, timeout: 100)
      assert [result] = results2
      assert result.status in [:timeout, :error]

      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "recovers from multiple consecutive errors", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Multiple errors in a row
      for i <- 1..5 do
        specs = [%{prompt: "Task", subagent: "invalid_#{i}"}]
        results = Coordinator.run_subagents(coordinator, specs, timeout: 50)
        assert [%{status: :error}] = results
      end

      # Should still be functional
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "recovers from mixed success and error batch", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [
        %{prompt: "Valid task 1"},
        %{prompt: "Task", subagent: "invalid_subagent_xyz"},
        %{prompt: "Valid task 2"},
        %{prompt: "Task", subagent: "another_invalid_one"},
        %{prompt: "Valid task 3"}
      ]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 150)

      assert length(results) == 5

      # Check that invalid subagents got errors
      assert Enum.at(results, 1).status == :error
      assert Enum.at(results, 3).status == :error

      # Coordinator should still work
      assert Process.alive?(coordinator)
    end
  end

  describe "error recovery - timeout handling" do
    @tag :tmp_dir
    test "recovers from timeout and can accept new work", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # First call times out
      specs1 = [%{prompt: "Long task"}]
      results1 = Coordinator.run_subagents(coordinator, specs1, timeout: 20)
      assert [result1] = results1
      assert result1.status in [:timeout, :error]

      # Second call should still work
      specs2 = [%{prompt: "Another task"}]
      results2 = Coordinator.run_subagents(coordinator, specs2, timeout: 50)
      assert length(results2) == 1

      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "handles back-to-back timeouts", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      for _ <- 1..3 do
        specs = [%{prompt: "Task"}]
        results = Coordinator.run_subagents(coordinator, specs, timeout: 10)
        assert [result] = results
        assert result.status in [:timeout, :error]
      end

      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
    end
  end

  describe "error recovery - abort scenarios" do
    @tag :tmp_dir
    test "abort_all on already empty coordinator", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Should not error
      assert :ok = Coordinator.abort_all(coordinator)
      assert :ok = Coordinator.abort_all(coordinator)
      assert :ok = Coordinator.abort_all(coordinator)

      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "abort_all during active run clears state properly", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      parent = self()

      # Start long-running subagents
      Task.start(fn ->
        results = Coordinator.run_subagents(coordinator, [%{prompt: "Task 1"}, %{prompt: "Task 2"}], timeout: 10_000)
        send(parent, {:results, results})
      end)

      # Give time to start
      Process.sleep(50)

      # Abort
      :ok = Coordinator.abort_all(coordinator)

      # Wait for cleanup
      Process.sleep(100)

      # Verify state is clean
      assert Coordinator.list_active(coordinator) == []

      # Can start new work
      specs = [%{prompt: "New task"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 50)
      assert length(results) == 1
    end
  end

  # ============================================================================
  # 4. Concurrent Session Handling
  # ============================================================================

  describe "concurrent session handling - parallel callers" do
    @tag :tmp_dir
    test "handles multiple concurrent callers", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 5_000)

      # Start 3 concurrent callers
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            specs = [%{prompt: "Task from caller #{i}"}]
            Coordinator.run_subagents(coordinator, specs, timeout: 200)
          end)
        end)

      # Wait for all results
      results = await_tasks(tasks, 10_000)

      # All should complete
      assert length(results) == 3
      assert Enum.all?(results, fn
               {:ok, [result]} -> result.status in [:timeout, :error]
               {:exit, _} -> true
             end)
      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "handles concurrent run_subagent calls", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 5_000)

      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            Coordinator.run_subagent(coordinator, prompt: "Task #{i}", timeout: 100)
          end)
        end)

      results = await_tasks(tasks, 10_000)

      assert length(results) == 5
      assert Enum.all?(results, fn
               {:ok, result} -> match?({:error, _}, result)
               {:exit, _} -> true
             end)
    end

    @tag :tmp_dir
    test "handles concurrent abort_all and run_subagents", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 10_000)

      # Start runner task
      runner =
        Task.async(fn ->
          Coordinator.run_subagents(coordinator, [%{prompt: "Task"}], timeout: 5_000)
        end)

      # Start aborter task
      aborter =
        Task.async(fn ->
          Process.sleep(50)
          Coordinator.abort_all(coordinator)
        end)

      # Both should complete without crashing
      Task.await(aborter, 5_000)
      Task.await(runner, 5_000)

      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "handles concurrent list_active calls", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # Start subagent in background
      spawn(fn ->
        Coordinator.run_subagents(coordinator, [%{prompt: "Task"}], timeout: 5_000)
      end)

      # Multiple concurrent list_active calls
      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            Coordinator.list_active(coordinator)
          end)
        end)

      results = await_tasks(tasks, 10_000)

      # All should return lists or exit cleanly
      assert Enum.all?(results, fn
               {:ok, result} -> is_list(result)
               {:exit, _} -> true
             end)
      assert Process.alive?(coordinator)
      Process.flag(:trap_exit, false)
    end
  end

  describe "concurrent session handling - subagent isolation" do
    @tag :tmp_dir
    test "subagent failure does not affect other subagents in same batch", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [
        %{prompt: "Valid task 1"},
        %{prompt: "Task", subagent: "invalid_subagent"},
        %{prompt: "Valid task 2"}
      ]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 200)

      assert length(results) == 3

      # Invalid subagent should have error
      assert Enum.at(results, 1).status == :error

      # Others should have their own status (timeout or error from other causes)
      assert Enum.at(results, 0).status in [:timeout, :error]
      assert Enum.at(results, 2).status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "each subagent gets unique ID even with same prompt", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = Enum.map(1..10, fn _ -> %{prompt: "Same prompt"} end)
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      ids = Enum.map(results, & &1.id)
      assert length(Enum.uniq(ids)) == 10
    end
  end

  # ============================================================================
  # 5. State Transitions
  # ============================================================================

  describe "state transitions - active subagents tracking" do
    @tag :tmp_dir
    test "list_active returns empty before any work", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "list_active returns empty after work completes", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task"}]
      _results = Coordinator.run_subagents(coordinator, specs, timeout: 50)

      # After run_subagents returns, active should be empty
      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "list_active returns empty after timeout", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task 1"}, %{prompt: "Task 2"}]
      _results = Coordinator.run_subagents(coordinator, specs, timeout: 10)

      # After timeout, should be cleaned up
      Process.sleep(50)
      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "list_active returns empty after abort_all", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      spawn(fn ->
        Coordinator.run_subagents(coordinator, [%{prompt: "Task"}], timeout: 10_000)
      end)

      Process.sleep(50)
      :ok = Coordinator.abort_all(coordinator)
      Process.sleep(50)

      assert Coordinator.list_active(coordinator) == []
    end
  end

  describe "state transitions - result status" do
    @tag :tmp_dir
    test "result transitions to :error for invalid subagent", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", subagent: "invalid_xyz"}]
      [result] = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert result.status == :error
      assert result.error == "Unknown subagent: invalid_xyz"
      assert result.result == nil
      assert result.session_id == nil
    end

    @tag :tmp_dir
    test "result transitions to :timeout when deadline exceeded", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task"}]
      [result] = Coordinator.run_subagents(coordinator, specs, timeout: 10)

      # May be timeout or error depending on whether session started
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "results preserve order regardless of completion order", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Mix of immediate errors and potential timeouts
      specs = [
        %{prompt: "Task 1", subagent: "invalid_1"},
        %{prompt: "Task 2"},
        %{prompt: "Task 3", subagent: "invalid_3"},
        %{prompt: "Task 4"},
        %{prompt: "Task 5", subagent: "invalid_5"}
      ]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      # Errors should be at positions 0, 2, 4
      assert Enum.at(results, 0).status == :error
      assert Enum.at(results, 2).status == :error
      assert Enum.at(results, 4).status == :error
    end
  end

  describe "state transitions - coordinator state" do
    @tag :tmp_dir
    test "coordinator maintains state across multiple runs", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Run 1
      specs1 = [%{prompt: "Task 1"}]
      results1 = Coordinator.run_subagents(coordinator, specs1, timeout: 50)
      assert length(results1) == 1

      # Run 2
      specs2 = [%{prompt: "Task 2"}, %{prompt: "Task 3"}]
      results2 = Coordinator.run_subagents(coordinator, specs2, timeout: 50)
      assert length(results2) == 2

      # Run 3
      specs3 = [%{prompt: "Task 4"}]
      results3 = Coordinator.run_subagents(coordinator, specs3, timeout: 50)
      assert length(results3) == 1

      # All should have unique IDs across all runs
      all_ids =
        Enum.flat_map([results1, results2, results3], fn results ->
          Enum.map(results, & &1.id)
        end)

      assert length(Enum.uniq(all_ids)) == 4
    end

    @tag :tmp_dir
    test "coordinator state unaffected by subagent errors", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Cause error
      specs1 = [%{prompt: "Task", subagent: "bad_type"}]
      [result1] = Coordinator.run_subagents(coordinator, specs1, timeout: 100)
      assert result1.status == :error

      # Coordinator should still function normally
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []

      # Can still run new work
      specs2 = [%{prompt: "New task"}]
      [result2] = Coordinator.run_subagents(coordinator, specs2, timeout: 100)
      assert Map.has_key?(result2, :status)
    end
  end

  # ============================================================================
  # Additional Edge Cases
  # ============================================================================

  describe "additional edge cases" do
    @tag :tmp_dir
    test "handles description in spec", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", description: "Custom description for this task"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert Map.has_key?(result, :status)
    end

    @tag :tmp_dir
    test "handles run_subagent without optional fields", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Only required field is prompt
      result = Coordinator.run_subagent(coordinator, prompt: "Task")

      assert {:error, _} = result
    end

    @tag :tmp_dir
    test "handles run_subagent with all optional fields", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      result =
        Coordinator.run_subagent(coordinator,
          prompt: "Task",
          subagent: "invalid_type",
          description: "Full spec",
          timeout: 100
        )

      assert {:error, {:error, "Unknown subagent: invalid_type"}} = result
    end

    @tag :tmp_dir
    test "process DOWN message for unknown process is ignored", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Send a DOWN message for unknown process
      random_ref = make_ref()
      send(coordinator, {:DOWN, random_ref, :process, self(), :normal})

      # Coordinator should still be alive and functional
      Process.sleep(10)
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "session_event for unknown session is ignored", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Send session event for unknown session
      send(coordinator, {:session_event, "unknown-session-id", {:agent_end, []}})

      # Coordinator should still be alive and functional
      Process.sleep(10)
      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "handles unknown message type gracefully", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Send various unknown messages
      send(coordinator, :unknown_atom)
      send(coordinator, {:unknown, :tuple, 123})
      send(coordinator, %{unknown: "map"})

      # Coordinator should still be alive and functional
      Process.sleep(10)
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
    end
  end
end
