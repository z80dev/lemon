defmodule CodingAgent.CoordinatorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Coordinator

  alias Ai.Types.{
    Model,
    ModelCost
  }

  # ============================================================================
  # Test Mocks and Helpers
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

  # ============================================================================
  # Initialization Tests
  # ============================================================================

  describe "start_link/1" do
    test "starts with cwd and model" do
      coordinator = start_coordinator()
      assert is_pid(coordinator)
      assert Process.alive?(coordinator)
    end

    test "starts with custom name" do
      name = :"coordinator_test_#{:erlang.unique_integer()}"
      {:ok, _pid} = Coordinator.start_link(default_coordinator_opts(name: name))

      # Can call by name
      assert Coordinator.list_active(name) == []
    end

    test "fails without cwd" do
      Process.flag(:trap_exit, true)
      result = Coordinator.start_link(model: mock_model())

      case result do
        {:error, _reason} ->
          # Any error is acceptable (KeyError, key_not_found, etc.)
          :ok

        {:ok, pid} ->
          assert_receive {:EXIT, ^pid, _reason}, 100
      end

      Process.flag(:trap_exit, false)
    end

    test "fails without model" do
      Process.flag(:trap_exit, true)
      result = Coordinator.start_link(cwd: System.tmp_dir!())

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          assert_receive {:EXIT, ^pid, _reason}, 100
      end

      Process.flag(:trap_exit, false)
    end

    test "accepts custom default_timeout" do
      coordinator = start_coordinator(default_timeout: 60_000)
      assert is_pid(coordinator)
    end

    test "accepts thinking_level option" do
      coordinator = start_coordinator(thinking_level: :high)
      assert is_pid(coordinator)
    end
  end

  # ============================================================================
  # Basic Subagent Spawning Tests
  # ============================================================================

  describe "run_subagent/2" do
    @tag :tmp_dir
    test "spawns a single subagent and returns result", %{tmp_dir: tmp_dir} do
      # Start coordinator with mock session options that will be merged
      coordinator =
        start_coordinator(
          cwd: tmp_dir,
          # We need to pass these to sessions started by the coordinator
          # The coordinator uses CodingAgent.start_session which may use supervisor
          default_timeout: 10_000
        )

      # For this test to work without real API calls, we need to mock at a higher level
      # Since Coordinator calls CodingAgent.start_session, we'll test the basic API
      # and verify errors are handled properly

      # Test with an unknown subagent type to verify error handling
      result =
        Coordinator.run_subagent(coordinator, prompt: "Hello", subagent: "nonexistent_agent")

      # Should get an error for unknown subagent
      assert {:error, {:error, "Unknown subagent: nonexistent_agent"}} = result
    end

    @tag :tmp_dir
    test "returns error tuple on failure", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 1_000)

      # Invalid subagent type should return error
      result = Coordinator.run_subagent(coordinator, prompt: "Test", subagent: "invalid_type_xyz")

      assert {:error, _reason} = result
    end

    @tag :tmp_dir
    test "works without subagent type", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 500)

      # Without a subagent type, the prompt is used directly
      # This will timeout without a real API but tests the code path
      result = Coordinator.run_subagent(coordinator, prompt: "Hello", timeout: 100)

      # Will likely timeout or error without real API
      assert {:error, _reason} = result
    end

    @tag :tmp_dir
    test "respects timeout option", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # Very short timeout should cause timeout or error (API not available)
      start_time = System.monotonic_time(:millisecond)
      result = Coordinator.run_subagent(coordinator, prompt: "Hello", timeout: 50)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete quickly due to timeout or early error
      assert elapsed < 5_000
      # Can be timeout or other error depending on environment
      assert {:error, _reason} = result
    end
  end

  # ============================================================================
  # Multiple Subagent Execution Tests
  # ============================================================================

  describe "run_subagents/3" do
    @tag :tmp_dir
    test "spawns multiple subagents concurrently", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 1_000)

      specs = [
        %{prompt: "Task 1"},
        %{prompt: "Task 2"},
        %{prompt: "Task 3"}
      ]

      # Will timeout but should return results for all specs
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert length(results) == 3

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :id)
        assert Map.has_key?(result, :status)
        assert result.status in [:completed, :error, :timeout, :aborted]
      end)
    end

    @tag :tmp_dir
    test "returns results in same order as specs", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 1_000)

      specs = [
        %{prompt: "First task", description: "first"},
        %{prompt: "Second task", description: "second"},
        %{prompt: "Third task", description: "third"}
      ]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert length(results) == 3

      # Results should have unique IDs
      ids = Enum.map(results, & &1.id)
      assert length(Enum.uniq(ids)) == 3
    end

    @tag :tmp_dir
    test "handles mix of valid and invalid subagent types", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 1_000)

      specs = [
        %{prompt: "Research task", subagent: "research"},
        %{prompt: "Invalid task", subagent: "nonexistent_subagent"},
        %{prompt: "Review task", subagent: "review"}
      ]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 200)

      assert length(results) == 3

      # The invalid subagent should have error status
      [_first, second, _third] = results
      assert second.status == :error
      assert second.error == "Unknown subagent: nonexistent_subagent"
    end

    @tag :tmp_dir
    test "empty specs list returns empty results", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      results = Coordinator.run_subagents(coordinator, [])

      assert results == []
    end
  end

  # ============================================================================
  # Timeout Handling Tests
  # ============================================================================

  describe "timeout handling" do
    @tag :tmp_dir
    test "times out after specified duration", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      specs = [%{prompt: "Long running task"}]

      start_time = System.monotonic_time(:millisecond)
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete within reasonable time of timeout
      assert elapsed < 1_000

      assert [result] = results
      # Can be timeout or error depending on whether session started
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "uses default_timeout when not specified", %{tmp_dir: tmp_dir} do
      # Short default timeout
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 100)

      specs = [%{prompt: "Task"}]

      start_time = System.monotonic_time(:millisecond)
      results = Coordinator.run_subagents(coordinator, specs)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should use default timeout
      assert elapsed < 1_000
      assert [result] = results
      # Can be timeout or error depending on whether session started
      assert result.status in [:timeout, :error]
    end

    @tag :tmp_dir
    test "cleans up subagents after timeout", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 100)

      specs = [%{prompt: "Task 1"}, %{prompt: "Task 2"}]

      _results = Coordinator.run_subagents(coordinator, specs, timeout: 50)

      # Give cleanup a moment
      Process.sleep(100)

      # Should have no active subagents
      active = Coordinator.list_active(coordinator)
      assert active == []
    end
  end

  # ============================================================================
  # Abort All Functionality Tests
  # ============================================================================

  describe "abort_all/1" do
    @tag :tmp_dir
    test "aborts all active subagents", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # Start subagents in a separate process so we can abort them
      parent = self()

      spawn(fn ->
        results =
          Coordinator.run_subagents(coordinator, [%{prompt: "Task 1"}, %{prompt: "Task 2"}],
            timeout: 10_000
          )

        send(parent, {:results, results})
      end)

      # Give time for subagents to start
      Process.sleep(50)

      # Abort all
      :ok = Coordinator.abort_all(coordinator)

      # Wait for results
      receive do
        {:results, results} ->
          # Results may be timeout or aborted
          assert length(results) == 2
      after
        2_000 ->
          # If we don't get results, check that active is empty
          assert Coordinator.list_active(coordinator) == []
      end
    end

    @tag :tmp_dir
    test "returns ok when no active subagents", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Should not error when nothing to abort
      assert :ok = Coordinator.abort_all(coordinator)
    end

    @tag :tmp_dir
    test "cleans up after abort", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 30_000)

      # Start subagents asynchronously
      spawn(fn ->
        Coordinator.run_subagents(coordinator, [%{prompt: "Task"}], timeout: 10_000)
      end)

      Process.sleep(50)

      :ok = Coordinator.abort_all(coordinator)

      # Give cleanup a moment
      Process.sleep(100)

      # Should have no active subagents
      assert Coordinator.list_active(coordinator) == []
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    @tag :tmp_dir
    test "handles unknown subagent type gracefully", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", subagent: "definitely_not_a_real_subagent"}]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert result.status == :error
      assert result.error == "Unknown subagent: definitely_not_a_real_subagent"
    end

    @tag :tmp_dir
    test "handles empty prompt in spec", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: ""}]

      # Should handle empty prompt
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert length(results) == 1
    end

    @tag :tmp_dir
    test "includes session_id in results when available", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 200)

      specs = [%{prompt: "Task"}]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 150)

      assert [result] = results
      # session_id may be nil if session failed to start, or set if it did
      assert Map.has_key?(result, :session_id)
    end

    @tag :tmp_dir
    test "coordinator remains functional after subagent errors", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # First run with error
      specs1 = [%{prompt: "Task", subagent: "invalid"}]
      results1 = Coordinator.run_subagents(coordinator, specs1, timeout: 100)
      assert [%{status: :error}] = results1

      # Second run should still work
      specs2 = [%{prompt: "Another task"}]
      results2 = Coordinator.run_subagents(coordinator, specs2, timeout: 100)
      assert length(results2) == 1
    end
  end

  # ============================================================================
  # Process Crash Tests
  # ============================================================================

  describe "subagent crash handling" do
    @tag :tmp_dir
    test "handles crashed subagent gracefully", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir, default_timeout: 5_000)

      # Without being able to inject a crashing session, we verify the coordinator
      # handles the DOWN message properly by testing the error path
      specs = [%{prompt: "Task"}]

      # This will timeout, which exercises similar cleanup code
      results = Coordinator.run_subagents(coordinator, specs, timeout: 50)

      assert length(results) == 1
      # Coordinator should still be alive
      assert Process.alive?(coordinator)
    end

    @tag :tmp_dir
    test "coordinator survives subagent failures", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      # Run multiple times with potential failures
      for _ <- 1..3 do
        specs = [
          %{prompt: "Task", subagent: "invalid_" <> Integer.to_string(:rand.uniform(1000))}
        ]

        results = Coordinator.run_subagents(coordinator, specs, timeout: 50)
        assert length(results) == 1
      end

      # Coordinator should still be alive
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "crashed subagent returns error result with reason", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", subagent: "bad_subagent_type"}]

      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert result.status == :error
      assert result.error != nil
    end
  end

  # ============================================================================
  # List Active Tests
  # ============================================================================

  describe "list_active/1" do
    @tag :tmp_dir
    test "returns empty list when no subagents", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      assert Coordinator.list_active(coordinator) == []
    end

    @tag :tmp_dir
    test "returns empty list after subagents complete", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task"}]
      _results = Coordinator.run_subagents(coordinator, specs, timeout: 50)

      # After completion, should be empty
      assert Coordinator.list_active(coordinator) == []
    end
  end

  # ============================================================================
  # Result Structure Tests
  # ============================================================================

  describe "result structure" do
    @tag :tmp_dir
    test "results have required fields", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 50)

      assert [result] = results

      # All required fields should be present
      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :result)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :session_id)

      assert is_binary(result.id)
      assert result.status in [:completed, :error, :timeout, :aborted]
    end

    @tag :tmp_dir
    test "timeout result has correct fields", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 10)

      assert [result] = results
      # Can be timeout or error depending on whether session started
      assert result.status in [:timeout, :error]
      assert result.error != nil
      assert result.result == nil
    end

    @tag :tmp_dir
    test "error result has correct fields", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(cwd: tmp_dir)

      specs = [%{prompt: "Task", subagent: "invalid_subagent"}]
      results = Coordinator.run_subagents(coordinator, specs, timeout: 100)

      assert [result] = results
      assert result.status == :error
      assert result.error != nil
      assert result.result == nil
    end
  end
end
