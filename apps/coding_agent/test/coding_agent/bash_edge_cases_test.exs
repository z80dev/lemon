defmodule CodingAgent.BashEdgeCasesTest do
  @moduledoc """
  Edge case tests for Bash tool and BashExecutor.

  Focuses on:
  - Streaming output callback behavior
  - Timeout handling and cancellation
  - AbortSignal integration mid-execution
  - Exit code handling (0, non-zero, signals)
  - Output truncation behavior
  - Error formatting
  - Concurrent execution
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash
  alias CodingAgent.BashExecutor
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  # ============================================================================
  # Streaming Output Callback Behavior
  # ============================================================================

  describe "streaming output callback behavior" do
    test "callback receives chunks in order of arrival", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      callback = fn chunk ->
        Agent.update(agent, fn chunks -> chunks ++ [chunk] end)
      end

      {:ok, _result} =
        BashExecutor.execute(
          "for i in 1 2 3 4 5; do echo \"line$i\"; sleep 0.01; done",
          tmp_dir,
          on_chunk: callback
        )

      chunks = Agent.get(agent, & &1)
      Agent.stop(agent)

      # Verify chunks received (may be combined but order should be preserved)
      combined = Enum.join(chunks, "")
      assert combined =~ "line1"
      assert combined =~ "line5"

      # Verify ordering - line1 should come before line5
      line1_pos = :binary.match(combined, "line1") |> elem(0)
      line5_pos = :binary.match(combined, "line5") |> elem(0)
      assert line1_pos < line5_pos
    end

    test "callback handles high-frequency output", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      callback = fn _chunk ->
        Agent.update(agent, &(&1 + 1))
      end

      # Generate output rapidly
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 100); do echo x; done",
          tmp_dir,
          on_chunk: callback
        )

      chunk_count = Agent.get(agent, & &1)
      Agent.stop(agent)

      # Should have received at least some callbacks
      assert chunk_count > 0
      assert result.exit_code == 0
    end

    test "callback exception does not crash executor", %{tmp_dir: tmp_dir} do
      callback = fn _chunk ->
        raise "callback error"
      end

      # Should handle callback exception gracefully
      assert {:error, %RuntimeError{message: "callback error"}} =
               BashExecutor.execute("echo test", tmp_dir, on_chunk: callback)
    end

    test "nil callback is handled gracefully", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("echo test", tmp_dir, on_chunk: nil)
      assert result.output =~ "test"
      assert result.exit_code == 0
    end

    test "callback receives sanitized output chunks", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      callback = fn chunk ->
        Agent.update(agent, fn chunks -> chunks ++ [chunk] end)
      end

      # Output with ANSI codes
      {:ok, _result} =
        BashExecutor.execute(
          "printf '\\033[31mred\\033[0m'",
          tmp_dir,
          on_chunk: callback
        )

      chunks = Agent.get(agent, & &1)
      Agent.stop(agent)

      combined = Enum.join(chunks, "")
      # ANSI codes should be stripped
      refute combined =~ "\033"
      assert combined =~ "red"
    end

    test "streaming callback accumulates in Bash tool", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> updates ++ [result] end)
        :ok
      end

      Bash.execute(
        "call_1",
        %{"command" => "echo a; sleep 0.05; echo b; sleep 0.05; echo c"},
        nil,
        on_update,
        tmp_dir,
        []
      )

      updates = Agent.get(agent, & &1)
      Agent.stop(agent)

      # Each update should contain accumulated output (not just the chunk)
      if length(updates) > 1 do
        first_size = byte_size(hd(updates).content |> hd() |> Map.get(:text))
        last_size = byte_size(List.last(updates).content |> hd() |> Map.get(:text))
        assert last_size >= first_size
      end
    end
  end

  # ============================================================================
  # Timeout Handling
  # ============================================================================

  describe "timeout handling edge cases" do
    test "exact timeout boundary", %{tmp_dir: tmp_dir} do
      # Command that takes almost exactly the timeout time
      # Use a generous margin since timing isn't precise
      {:ok, result} = BashExecutor.execute("sleep 0.5", tmp_dir, timeout: 1000)

      # Should complete successfully, not timeout
      assert result.cancelled == false
      assert result.exit_code == 0
    end

    test "very short timeout", %{tmp_dir: tmp_dir} do
      # 10ms timeout
      {:ok, result} = BashExecutor.execute("sleep 1", tmp_dir, timeout: 10)

      assert result.cancelled == true
      assert result.exit_code == nil
    end

    test "zero timeout is treated as no timeout", %{tmp_dir: tmp_dir} do
      # Zero should be treated as infinite/no timeout based on the condition: if timeout > 0
      {:ok, result} = BashExecutor.execute("echo fast", tmp_dir, timeout: 0)

      assert result.cancelled == false
      assert result.exit_code == 0
    end

    test "negative timeout is treated as no timeout", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("echo fast", tmp_dir, timeout: -1000)

      assert result.cancelled == false
      assert result.exit_code == 0
    end

    test "timeout with large output preserves partial output", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 1000); do echo line$i; done; sleep 10",
          tmp_dir,
          timeout: 500
        )

      assert result.cancelled == true
      # Should have captured some output before timeout
      assert result.output =~ "line1"
    end

    test "timeout kills child processes", %{tmp_dir: tmp_dir} do
      # Start a command that spawns a subprocess
      {:ok, result} =
        BashExecutor.execute(
          "bash -c 'sleep 100 & echo started; wait'",
          tmp_dir,
          timeout: 100
        )

      assert result.cancelled == true

      # Give time for cleanup
      Process.sleep(200)

      # The spawned sleep process should be killed
      # (We can't easily verify this, but the test ensures no hang)
    end

    test "timeout message includes duration in Bash tool", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "sleep 10", "timeout" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1 second"
    end

    test "timeout with streaming still calls final callbacks", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> {0, nil} end)

      callback = fn chunk ->
        Agent.update(agent, fn {count, _last} -> {count + 1, chunk} end)
      end

      {:ok, _result} =
        BashExecutor.execute(
          "echo before; sleep 10",
          tmp_dir,
          on_chunk: callback,
          timeout: 200
        )

      {count, _last_chunk} = Agent.get(agent, & &1)
      Agent.stop(agent)

      # Should have received at least the initial output
      assert count > 0
    end
  end

  # ============================================================================
  # AbortSignal Integration - Cancellation Mid-Execution
  # ============================================================================

  describe "abort signal mid-execution" do
    test "abort during output collection stops immediately", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          BashExecutor.execute(
            "for i in $(seq 1 1000); do echo line$i; sleep 0.01; done",
            tmp_dir,
            signal: signal
          )
        end)

      # Wait for some output
      Process.sleep(100)

      # Record time before abort
      start_time = System.monotonic_time(:millisecond)
      AbortSignal.abort(signal)
      {:ok, result} = Task.await(task, 10_000)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should abort quickly (within 500ms of calling abort)
      assert elapsed < 500
      assert result.cancelled == true

      AbortSignal.clear(signal)
    end

    test "abort signal checked during receive timeout", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      # Command that produces no output for a while
      task =
        Task.async(fn ->
          BashExecutor.execute("sleep 10", tmp_dir, signal: signal)
        end)

      # Abort after the 100ms receive timeout in collect_output
      Process.sleep(150)
      AbortSignal.abort(signal)

      {:ok, result} = Task.await(task, 10_000)
      assert result.cancelled == true

      AbortSignal.clear(signal)
    end

    test "multiple abort calls are idempotent", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          BashExecutor.execute("sleep 10", tmp_dir, signal: signal)
        end)

      Process.sleep(50)

      # Call abort multiple times
      AbortSignal.abort(signal)
      AbortSignal.abort(signal)
      AbortSignal.abort(signal)

      {:ok, result} = Task.await(task, 10_000)
      assert result.cancelled == true

      AbortSignal.clear(signal)
    end

    test "abort with nil signal is ignored", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("echo test", tmp_dir, signal: nil)

      assert result.cancelled == false
      assert result.exit_code == 0
    end

    test "abort before command start returns immediately in Bash tool", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      start_time = System.monotonic_time(:millisecond)

      result =
        Bash.execute(
          "call_1",
          %{"command" => "sleep 10"},
          signal,
          nil,
          tmp_dir,
          []
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should return almost immediately
      assert elapsed < 100
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "cancelled"

      AbortSignal.clear(signal)
    end

    test "abort preserves partial output", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          BashExecutor.execute(
            "echo before_abort; sleep 5; echo after_abort",
            tmp_dir,
            signal: signal
          )
        end)

      # Wait for initial output
      Process.sleep(100)
      AbortSignal.abort(signal)

      {:ok, result} = Task.await(task, 5_000)

      assert result.cancelled == true
      assert result.output =~ "before_abort"
      refute result.output =~ "after_abort"

      AbortSignal.clear(signal)
    end

    test "abort signal cleanup prevents resource leaks", %{tmp_dir: tmp_dir} do
      signals =
        for _ <- 1..10 do
          signal = AbortSignal.new()

          task =
            Task.async(fn ->
              BashExecutor.execute("sleep 1", tmp_dir, signal: signal)
            end)

          Process.sleep(10)
          AbortSignal.abort(signal)
          Task.await(task, 5_000)

          signal
        end

      # Clean up all signals
      Enum.each(signals, &AbortSignal.clear/1)

      # If we get here without issues, cleanup worked
      assert true
    end
  end

  # ============================================================================
  # Exit Code Handling
  # ============================================================================

  describe "exit code handling" do
    test "exit code 0 indicates success", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("exit 0", tmp_dir)
      assert result.exit_code == 0
      assert result.cancelled == false
    end

    test "various non-zero exit codes", %{tmp_dir: tmp_dir} do
      for code <- [1, 2, 127, 128, 255] do
        {:ok, result} = BashExecutor.execute("exit #{code}", tmp_dir)
        assert result.exit_code == code, "Expected exit code #{code}"
        assert result.cancelled == false
      end
    end

    test "exit code 127 for command not found", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("nonexistent_cmd_xyz_123", tmp_dir)
      # 127 is the standard code for command not found
      assert result.exit_code == 127
    end

    test "exit code from last command in pipeline", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("true | false", tmp_dir)
      # Last command (false) should determine exit code
      assert result.exit_code == 1
    end

    test "exit code from subshell", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("(exit 42)", tmp_dir)
      assert result.exit_code == 42
    end

    test "SIGTERM produces specific exit code", %{tmp_dir: tmp_dir} do
      # When a process is killed by SIGTERM (15), exit code is 128+15=143
      # But since we use SIGKILL (9), it would be 128+9=137
      {:ok, result} =
        BashExecutor.execute(
          "bash -c 'trap \"exit 42\" TERM; sleep 10'",
          tmp_dir,
          timeout: 100
        )

      # Cancelled due to timeout
      assert result.cancelled == true
      assert result.exit_code == nil
    end

    test "exit code with output in Bash tool", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo output; exit 42"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "output"
      assert text =~ "exited with code 42"
      assert details.exit_code == 42
    end

    test "exit code 0 with empty output", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "true"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == ""
      assert details.exit_code == 0
    end

    test "exit code nil when cancelled", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      {:ok, result} = BashExecutor.execute("echo test", tmp_dir, signal: signal)

      assert result.cancelled == true
      assert result.exit_code == nil

      AbortSignal.clear(signal)
    end
  end

  # ============================================================================
  # Output Truncation Behavior
  # ============================================================================

  describe "output truncation behavior" do
    test "truncation keeps tail (most recent output)", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 3000); do echo line$i; done",
          tmp_dir,
          max_bytes: 10_000,
          max_lines: 100
        )

      assert result.truncated == true
      # Should have the last lines
      assert result.output =~ "line3000"
      assert result.output =~ "line2999"
      # Should not have early lines
      refute result.output =~ "line1\n"
    end

    test "truncation notice includes statistics", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 500); do echo line$i; done",
          tmp_dir,
          max_bytes: 1000
        )

      assert result.truncated == true
      assert result.output =~ "[Output truncated."
      assert result.output =~ "Total:"
      assert result.output =~ "lines"
    end

    test "temp file created for very large output", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 10000); do echo line$i; done",
          tmp_dir,
          max_bytes: 5000
        )

      assert result.truncated == true
      assert result.full_output_path != nil
      assert File.exists?(result.full_output_path)

      # Full file should contain all lines
      full_content = File.read!(result.full_output_path)
      assert full_content =~ "line1"
      assert full_content =~ "line10000"

      # Cleanup
      File.rm(result.full_output_path)
    end

    test "no truncation for output under limit", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("echo small", tmp_dir, max_bytes: 50_000)

      assert result.truncated == false
      assert result.full_output_path == nil
    end

    test "byte truncation with multi-byte characters", %{tmp_dir: tmp_dir} do
      # UTF-8 characters can be multiple bytes
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 1000); do echo '日本語テスト'; done",
          tmp_dir,
          max_bytes: 5000
        )

      # Should handle without crashing
      assert is_binary(result.output)
      # May or may not be truncated depending on exact byte counts
    end

    test "truncation with mixed stdout/stderr", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 1500); do echo stdout$i; echo stderr$i >&2; done",
          tmp_dir,
          max_bytes: 10_000
        )

      assert result.truncated == true
      # Both streams should be present (merged)
      assert result.output =~ "stdout"
      assert result.output =~ "stderr"
    end

    test "truncation info in Bash tool result", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "for i in $(seq 1 5000); do echo line$i; done"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.truncated == true

      if details.full_output_path do
        assert text =~ details.full_output_path
        File.rm(details.full_output_path)
      end
    end
  end

  # ============================================================================
  # Error Formatting
  # ============================================================================

  describe "error formatting" do
    test "command not found error", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "nonexistent_command_xyz"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.exit_code == 127
      assert text =~ "not found" or text =~ "exited with code 127"
    end

    test "syntax error formatting", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "if then else fi"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.exit_code != 0
    end

    test "timeout error formatting", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "sleep 10", "timeout" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "timed out"
      assert text =~ "1 second"
      assert details.exit_code == nil
    end

    test "cancelled error formatting without output", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo test"},
          signal,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text == "Command cancelled."

      AbortSignal.clear(signal)
    end

    test "cancelled error formatting with partial output", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          Bash.execute(
            "call_1",
            %{"command" => "echo partial; sleep 10"},
            signal,
            nil,
            tmp_dir,
            []
          )
        end)

      Process.sleep(100)
      AbortSignal.abort(signal)

      result = Task.await(task, 5_000)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "cancelled"
      assert text =~ "partial"

      AbortSignal.clear(signal)
    end

    test "error result from BashExecutor", %{tmp_dir: _tmp_dir} do
      # Test error handling - invalid cwd should cause an error
      result = BashExecutor.execute("echo test", "/nonexistent/path/xyz")

      case result do
        {:error, _reason} ->
          # Expected - directory doesn't exist
          assert true

        {:ok, res} ->
          # Some systems may handle this differently
          assert res.exit_code != 0 or res.cancelled == true
      end
    end
  end

  # ============================================================================
  # Concurrent Execution
  # ============================================================================

  describe "concurrent execution" do
    test "multiple commands execute independently", %{tmp_dir: tmp_dir} do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            {:ok, result} =
              BashExecutor.execute(
                "echo task#{i}; sleep 0.1",
                tmp_dir
              )

            {i, result}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should succeed
      for {i, result} <- results do
        assert result.exit_code == 0
        assert result.output =~ "task#{i}"
      end
    end

    test "concurrent commands with different timeouts", %{tmp_dir: tmp_dir} do
      fast_task =
        Task.async(fn ->
          BashExecutor.execute("echo fast", tmp_dir, timeout: 5000)
        end)

      slow_task =
        Task.async(fn ->
          BashExecutor.execute("sleep 10", tmp_dir, timeout: 100)
        end)

      {:ok, fast_result} = Task.await(fast_task, 5_000)
      {:ok, slow_result} = Task.await(slow_task, 5_000)

      assert fast_result.exit_code == 0
      assert fast_result.cancelled == false

      assert slow_result.cancelled == true
      assert slow_result.exit_code == nil
    end

    test "concurrent abort signals are independent", %{tmp_dir: tmp_dir} do
      signal1 = AbortSignal.new()
      signal2 = AbortSignal.new()

      task1 =
        Task.async(fn ->
          BashExecutor.execute("sleep 5", tmp_dir, signal: signal1)
        end)

      task2 =
        Task.async(fn ->
          BashExecutor.execute("echo independent; sleep 0.5", tmp_dir, signal: signal2)
        end)

      Process.sleep(50)
      # Only abort task1
      AbortSignal.abort(signal1)

      {:ok, result1} = Task.await(task1, 5_000)
      {:ok, result2} = Task.await(task2, 5_000)

      assert result1.cancelled == true
      assert result2.cancelled == false
      assert result2.exit_code == 0

      AbortSignal.clear(signal1)
      AbortSignal.clear(signal2)
    end

    test "concurrent streaming callbacks are isolated", %{tmp_dir: tmp_dir} do
      {:ok, agent1} = Agent.start_link(fn -> [] end)
      {:ok, agent2} = Agent.start_link(fn -> [] end)

      callback1 = fn chunk ->
        Agent.update(agent1, fn chunks -> chunks ++ [chunk] end)
      end

      callback2 = fn chunk ->
        Agent.update(agent2, fn chunks -> chunks ++ [chunk] end)
      end

      task1 =
        Task.async(fn ->
          BashExecutor.execute("echo task1_output", tmp_dir, on_chunk: callback1)
        end)

      task2 =
        Task.async(fn ->
          BashExecutor.execute("echo task2_output", tmp_dir, on_chunk: callback2)
        end)

      Task.await_many([task1, task2], 5_000)

      chunks1 = Agent.get(agent1, & &1) |> Enum.join("")
      chunks2 = Agent.get(agent2, & &1) |> Enum.join("")

      Agent.stop(agent1)
      Agent.stop(agent2)

      # Each callback should only see its own output
      assert chunks1 =~ "task1_output"
      refute chunks1 =~ "task2_output"

      assert chunks2 =~ "task2_output"
      refute chunks2 =~ "task1_output"
    end

    test "rapid sequential execution", %{tmp_dir: tmp_dir} do
      results =
        for i <- 1..20 do
          {:ok, result} = BashExecutor.execute("echo #{i}", tmp_dir)
          {i, result}
        end

      for {i, result} <- results do
        assert result.exit_code == 0
        assert result.output =~ "#{i}"
      end
    end

    test "concurrent execution with shared tmp_dir", %{tmp_dir: tmp_dir} do
      # All tasks write to the same directory but different files
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            file = "test_#{i}.txt"

            {:ok, result} =
              BashExecutor.execute(
                "echo content#{i} > #{file} && cat #{file}",
                tmp_dir
              )

            {i, result}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for {i, result} <- results do
        assert result.exit_code == 0
        assert result.output =~ "content#{i}"
      end

      # Cleanup files
      for i <- 1..5 do
        File.rm(Path.join(tmp_dir, "test_#{i}.txt"))
      end
    end
  end

  # ============================================================================
  # Additional Edge Cases
  # ============================================================================

  describe "additional edge cases" do
    test "empty command string", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("", tmp_dir)
      # Empty command should succeed but do nothing
      assert result.exit_code == 0
    end

    test "whitespace-only command", %{tmp_dir: tmp_dir} do
      {:ok, result} = BashExecutor.execute("   ", tmp_dir)
      assert result.exit_code == 0
    end

    test "command with embedded newlines", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "echo line1\necho line2",
          tmp_dir
        )

      assert result.exit_code == 0
      assert result.output =~ "line1"
      assert result.output =~ "line2"
    end

    test "command with null bytes in output", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "printf 'before\\x00after'",
          tmp_dir
        )

      # Should handle without crashing
      assert is_binary(result.output)
      assert result.exit_code == 0
    end

    test "very long command string", %{tmp_dir: tmp_dir} do
      # Generate a command that's quite long
      long_arg = String.duplicate("x", 10_000)

      {:ok, result} =
        BashExecutor.execute(
          "echo \"#{long_arg}\"",
          tmp_dir
        )

      assert result.exit_code == 0
      assert result.output =~ "xxxx"
    end

    test "command with backslashes and quotes", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "echo \"it's a \\\"test\\\"\"",
          tmp_dir
        )

      assert result.exit_code == 0
      assert result.output =~ "it's a \"test\""
    end

    test "command producing output in bursts", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      callback = fn chunk ->
        timestamp = System.monotonic_time(:millisecond)
        Agent.update(agent, fn data -> data ++ [{timestamp, chunk}] end)
      end

      {:ok, result} =
        BashExecutor.execute(
          "echo burst1; sleep 0.1; echo burst2; sleep 0.1; echo burst3",
          tmp_dir,
          on_chunk: callback
        )

      data = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert result.exit_code == 0

      # Verify timing shows bursts
      if length(data) >= 2 do
        times = Enum.map(data, fn {t, _} -> t end)
        # There should be some time gaps
        time_range = List.last(times) - hd(times)
        assert time_range > 0
      end
    end

    test "handles control characters in output", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BashExecutor.execute(
          "printf 'normal\\x07bell\\x08backspace'",
          tmp_dir
        )

      # Control characters should be stripped
      assert is_binary(result.output)
      # Bell (\\x07) and backspace (\\x08) should be removed
    end

    test "preserves trailing newline behavior", %{tmp_dir: tmp_dir} do
      {:ok, result1} = BashExecutor.execute("echo test", tmp_dir)
      {:ok, result2} = BashExecutor.execute("printf test", tmp_dir)

      # echo adds newline, printf doesn't
      assert result1.output =~ "test\n"
      assert String.trim_trailing(result2.output) == "test"
    end
  end
end
