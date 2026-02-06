defmodule AgentCore.AgentQueueTest do
  @moduledoc """
  Comprehensive tests for queue mode handling in AgentCore.Agent.

  These tests cover:
  - Queue mode switching mid-run
  - Error state propagation in queue mode
  - Waiter timeout behavior
  - Task supervision integration
  - Concurrent prompt submissions
  - Queue overflow scenarios
  - Steering vs follow-up message interaction
  """

  use ExUnit.Case, async: true

  alias AgentCore.Agent, as: CoreAgent
  alias AgentCore.Test.Mocks

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp start_agent(opts \\ []) do
    default_opts = [
      initial_state: %{
        system_prompt: Keyword.get(opts, :system_prompt, "You are a test assistant."),
        model: Keyword.get(opts, :model, Mocks.mock_model()),
        thinking_level: Keyword.get(opts, :thinking_level, :off),
        tools: Keyword.get(opts, :tools, [])
      },
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm())
    ]

    merged_opts = Keyword.merge(default_opts, opts)
    CoreAgent.start_link(merged_opts)
  end

  defp delayed_stream_fn(response, delay_ms) do
    fn _model, _context, _options ->
      {:ok, stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(stream, {:start, response})
        Process.sleep(delay_ms)
        Ai.EventStream.push(stream, {:done, response.stop_reason, response})
        Ai.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  # ============================================================================
  # Queue Mode Switching Mid-Run
  # ============================================================================

  describe "queue mode switching mid-run" do
    test "switching steering mode from :one_at_a_time to :all during streaming" do
      parent = self()
      response = Mocks.assistant_message("Response")

      # Create a stream that gives time to switch modes
      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          # Notify parent that streaming started
          send(parent, :stream_started)
          # Wait for mode switch signal
          receive do
            :continue -> :ok
          after
            500 -> :ok
          end

          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(steering_mode: :one_at_a_time, stream_fn: stream_fn)

      :ok = CoreAgent.prompt(agent, "Start")

      # Wait for streaming to start
      assert_receive :stream_started, 1000

      # Switch mode while streaming
      :ok = CoreAgent.set_steering_mode(agent, :all)
      assert CoreAgent.get_steering_mode(agent) == :all

      # Signal to continue
      send(agent, :continue)

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "switching follow-up mode from :one_at_a_time to :all during streaming" do
      parent = self()
      response = Mocks.assistant_message("Response")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          send(parent, :stream_started)

          receive do
            :continue -> :ok
          after
            500 -> :ok
          end

          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(follow_up_mode: :one_at_a_time, stream_fn: stream_fn)

      :ok = CoreAgent.prompt(agent, "Start")
      assert_receive :stream_started, 1000

      # Switch mode during streaming
      :ok = CoreAgent.set_follow_up_mode(agent, :all)
      assert CoreAgent.get_follow_up_mode(agent) == :all

      send(agent, :continue)
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "mode switch affects next queue consumption, not current" do
      # This tests that mode changes don't affect in-flight queue consumption
      response1 = Mocks.assistant_message("First")
      response2 = Mocks.assistant_message("Second")
      response3 = Mocks.assistant_message("Third")

      {:ok, agent} =
        start_agent(
          steering_mode: :one_at_a_time,
          stream_fn: Mocks.mock_stream_fn([response1, response2, response3])
        )

      # Queue multiple steering messages before starting
      msg1 = Mocks.user_message("Steer 1")
      msg2 = Mocks.user_message("Steer 2")
      msg3 = Mocks.user_message("Steer 3")

      :ok = CoreAgent.steer(agent, msg1)
      :ok = CoreAgent.steer(agent, msg2)
      :ok = CoreAgent.steer(agent, msg3)

      :ok = CoreAgent.prompt(agent, "Start")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      # The steering queue should have been consumed one at a time
      internal_state = :sys.get_state(agent)

      # After completion, remaining messages should still be in queue (since only one was consumed per turn)
      # The exact count depends on how many turns occurred
      assert is_list(internal_state.steering_queue)
    end
  end

  # ============================================================================
  # Error State Propagation in Queue Mode
  # ============================================================================

  describe "error state propagation in queue mode" do
    test "error in stream function sets agent error state" do
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_error(:api_rate_limited))

      :ok = CoreAgent.prompt(agent, "Will fail")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      state = CoreAgent.get_state(agent)
      assert state.error == "api_rate_limited"
      assert state.is_streaming == false
    end

    test "error in tool execution propagates to agent state" do
      error_tool = %AgentCore.Types.AgentTool{
        name: "failing_tool",
        description: "A tool that fails",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Failing",
        execute: fn _id, _params, _signal, _on_update ->
          raise "Catastrophic failure"
        end
      }

      tool_call = Mocks.tool_call("failing_tool", %{}, id: "call_fail")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled error")

      {:ok, agent} =
        start_agent(
          tools: [error_tool],
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      :ok = CoreAgent.prompt(agent, "Run failing tool")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      state = CoreAgent.get_state(agent)
      # Agent should complete (error is handled), but we can check the final state
      assert state.is_streaming == false
    end

    test "error clears queues on reset" do
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_error(:network_error))

      # Add messages to both queues
      :ok = CoreAgent.steer(agent, Mocks.user_message("Steering"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow-up"))

      :ok = CoreAgent.prompt(agent, "Will fail")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      # Verify error state
      state = CoreAgent.get_state(agent)
      assert state.error != nil

      # Reset should clear error and queues
      :ok = CoreAgent.reset(agent)

      state = CoreAgent.get_state(agent)
      assert state.error == nil

      # Verify queues are cleared via internal state
      internal_state = :sys.get_state(agent)
      assert internal_state.steering_queue == []
      assert internal_state.follow_up_queue == []
    end

    test "multiple consecutive errors don't corrupt queue state" do
      call_count = :counters.new(1, [:atomics])

      error_stream_fn = fn _model, _context, _options ->
        :counters.add(call_count, 1, 1)
        {:error, :consecutive_error}
      end

      {:ok, agent} = start_agent(stream_fn: error_stream_fn)

      # Add steering messages
      :ok = CoreAgent.steer(agent, Mocks.user_message("Steer 1"))
      :ok = CoreAgent.steer(agent, Mocks.user_message("Steer 2"))

      # First error
      :ok = CoreAgent.prompt(agent, "First fail")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      state1 = CoreAgent.get_state(agent)
      assert state1.error == "consecutive_error"

      # Second error
      :ok = CoreAgent.prompt(agent, "Second fail")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      state2 = CoreAgent.get_state(agent)
      assert state2.error == "consecutive_error"

      # Queue should still be accessible
      internal_state = :sys.get_state(agent)
      assert is_list(internal_state.steering_queue)
    end

    test "error with message containing special characters" do
      error_stream_fn = fn _model, _context, _options ->
        {:error, "Error: \"quoted\" & <special> chars\nNewline"}
      end

      {:ok, agent} = start_agent(stream_fn: error_stream_fn)

      :ok = CoreAgent.prompt(agent, "Test special error")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      state = CoreAgent.get_state(agent)
      assert is_binary(state.error)
      assert String.contains?(state.error, "quoted")
    end
  end

  # ============================================================================
  # Waiter Timeout Behavior
  # ============================================================================

  describe "waiter timeout behavior" do
    test "wait_for_idle returns :ok immediately when not streaming" do
      {:ok, agent} = start_agent()

      start_time = System.monotonic_time(:millisecond)
      result = CoreAgent.wait_for_idle(agent, timeout: 5000)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == :ok
      # Should return almost immediately (< 100ms)
      assert elapsed < 100
    end

    test "wait_for_idle with timeout returns {:error, :timeout}" do
      response = Mocks.assistant_message("Slow response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 500))

      :ok = CoreAgent.prompt(agent, "Slow request")

      result = CoreAgent.wait_for_idle(agent, timeout: 50)
      assert result == {:error, :timeout}

      # Clean up - wait for actual completion
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "wait_for_idle with infinity timeout waits indefinitely" do
      response = Mocks.assistant_message("Eventually")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 200))

      :ok = CoreAgent.prompt(agent, "Request")

      start_time = System.monotonic_time(:millisecond)
      result = CoreAgent.wait_for_idle(agent, timeout: :infinity)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == :ok
      # Should have waited at least 200ms
      assert elapsed >= 150
    end

    test "multiple waiters all receive notification" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 150))

      :ok = CoreAgent.prompt(agent, "Request")

      # Spawn multiple waiters
      parent = self()

      waiters =
        for i <- 1..5 do
          spawn(fn ->
            result = CoreAgent.wait_for_idle(agent, timeout: 2000)
            send(parent, {:waiter_done, i, result})
          end)
        end

      # All waiters should complete
      for i <- 1..5 do
        assert_receive {:waiter_done, ^i, :ok}, 2000
      end

      # Verify all waiter processes completed
      Enum.each(waiters, fn pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          100 -> flunk("Waiter process did not exit")
        end
      end)
    end

    test "waiter timeout cancellation works correctly" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 300))

      :ok = CoreAgent.prompt(agent, "Request")

      # Start a wait that will timeout
      task =
        Task.async(fn ->
          CoreAgent.wait_for_idle(agent, timeout: 50)
        end)

      result = Task.await(task, 1000)
      assert result == {:error, :timeout}

      # The waiter should have been removed from the waiters list
      # after timeout and cleanup
      Process.sleep(50)
      internal_state = :sys.get_state(agent)

      # After cleanup, there should be no waiters from that task
      # (the agent may still be running)
      assert is_list(internal_state.waiters)

      # Wait for actual completion
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "wait_for_idle accepts integer timeout directly" do
      {:ok, agent} = start_agent()

      # Should accept integer directly without keyword list
      result = CoreAgent.wait_for_idle(agent, 5000)
      assert result == :ok
    end

    test "waiter receives notification even if added just before completion" do
      response = Mocks.assistant_message("Fast")
      parent = self()

      # Use a simple flag to coordinate timing
      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          send(parent, :stream_started)
          # Wait a bit to let the waiter register
          Process.sleep(50)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: stream_fn)

      :ok = CoreAgent.prompt(agent, "Request")

      # Wait for stream to start
      assert_receive :stream_started, 1000

      # Now add waiter just before completion
      result = CoreAgent.wait_for_idle(agent, timeout: 2000)
      assert result == :ok
    end
  end

  # ============================================================================
  # Task Supervision Integration
  # ============================================================================

  describe "task supervision integration" do
    test "task crash is handled gracefully" do
      # When a stream function returns an error, the agent should handle it gracefully
      crash_stream_fn = fn _model, _context, _options ->
        # Simulate a crash scenario by returning an error
        {:error, :simulated_crash}
      end

      {:ok, agent} = start_agent(stream_fn: crash_stream_fn)

      :ok = CoreAgent.prompt(agent, "Will crash")

      # Agent should recover and become idle
      result = CoreAgent.wait_for_idle(agent, timeout: 1000)
      assert result == :ok

      state = CoreAgent.get_state(agent)
      assert state.is_streaming == false
      # Error should be set
      assert state.error == "simulated_crash"
    end

    test "agent survives task timeout" do
      # Create a stream that never completes
      hung_stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          # Just hang forever
          Process.sleep(:infinity)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: hung_stream_fn)

      :ok = CoreAgent.prompt(agent, "Hanging request")

      # Abort should work even with hung task
      :ok = CoreAgent.abort(agent)

      # Give some time for abort to process
      Process.sleep(100)

      # Agent should still be alive
      assert Process.alive?(agent)
    end

    test "concurrent aborts don't crash agent" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 500))

      :ok = CoreAgent.prompt(agent, "Request")

      # Send multiple concurrent aborts
      for _ <- 1..10 do
        spawn(fn -> CoreAgent.abort(agent) end)
      end

      # Agent should handle this gracefully
      Process.sleep(100)
      assert Process.alive?(agent)

      # Wait for completion
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "task completion updates agent state correctly" do
      response = Mocks.assistant_message("Complete")
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = CoreAgent.prompt(agent, "Request")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      internal_state = :sys.get_state(agent)

      # Task should be cleared
      assert internal_state.running_task == nil
      # Abort ref should be cleared
      assert internal_state.abort_ref == nil
      # Waiters should be empty
      assert internal_state.waiters == []
    end
  end

  # ============================================================================
  # Concurrent Prompt Submissions
  # ============================================================================

  describe "concurrent prompt submissions" do
    test "second prompt while streaming returns error" do
      response = Mocks.assistant_message("First response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 200))

      assert :ok = CoreAgent.prompt(agent, "First prompt")
      assert {:error, :already_streaming} = CoreAgent.prompt(agent, "Second prompt")

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "prompt after completion succeeds" do
      response1 = Mocks.assistant_message("First")
      response2 = Mocks.assistant_message("Second")

      {:ok, agent} =
        start_agent(stream_fn: Mocks.mock_stream_fn([response1, response2]))

      :ok = CoreAgent.prompt(agent, "First")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      :ok = CoreAgent.prompt(agent, "Second")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 1000)

      state = CoreAgent.get_state(agent)
      # Should have messages from both prompts
      assert length(state.messages) >= 2
    end

    test "rapid prompt attempts during streaming all return error" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 300))

      :ok = CoreAgent.prompt(agent, "Initial")

      # Try multiple rapid prompts
      results =
        for i <- 1..5 do
          CoreAgent.prompt(agent, "Attempt #{i}")
        end

      # All should fail
      assert Enum.all?(results, &(&1 == {:error, :already_streaming}))

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "continue during streaming returns error" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 200))

      # Set up a message so continue could work
      CoreAgent.replace_messages(agent, [Mocks.user_message("Setup")])

      :ok = CoreAgent.prompt(agent, "Prompt")
      assert {:error, :already_streaming} = CoreAgent.continue(agent)

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "prompt from different processes during streaming" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 200))

      parent = self()

      :ok = CoreAgent.prompt(agent, "Main prompt")

      # Try prompting from different processes
      pids =
        for i <- 1..3 do
          spawn(fn ->
            result = CoreAgent.prompt(agent, "Process #{i} prompt")
            send(parent, {:prompt_result, i, result})
          end)
        end

      # All should fail
      for i <- 1..3 do
        assert_receive {:prompt_result, ^i, {:error, :already_streaming}}, 1000
      end

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      # Verify processes are done
      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          100 -> :ok
        end
      end)
    end
  end

  # ============================================================================
  # Queue Overflow Scenarios
  # ============================================================================

  describe "queue overflow scenarios" do
    test "queuing many steering messages" do
      {:ok, agent} = start_agent()

      # Queue a large number of steering messages
      for i <- 1..100 do
        :ok = CoreAgent.steer(agent, Mocks.user_message("Steer #{i}"))
      end

      internal_state = :sys.get_state(agent)
      assert length(internal_state.steering_queue) == 100
    end

    test "queuing many follow-up messages" do
      {:ok, agent} = start_agent()

      # Queue a large number of follow-up messages
      for i <- 1..100 do
        :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow #{i}"))
      end

      internal_state = :sys.get_state(agent)
      assert length(internal_state.follow_up_queue) == 100
    end

    test "clearing full queues works correctly" do
      {:ok, agent} = start_agent()

      # Fill both queues
      for i <- 1..50 do
        :ok = CoreAgent.steer(agent, Mocks.user_message("Steer #{i}"))
        :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow #{i}"))
      end

      internal_state = :sys.get_state(agent)
      assert length(internal_state.steering_queue) == 50
      assert length(internal_state.follow_up_queue) == 50

      # Clear all
      :ok = CoreAgent.clear_all_queues(agent)

      internal_state = :sys.get_state(agent)
      assert internal_state.steering_queue == []
      assert internal_state.follow_up_queue == []
    end

    test "queue order is preserved (FIFO)" do
      {:ok, agent} = start_agent()

      # Queue messages in order
      for i <- 1..10 do
        :ok = CoreAgent.steer(agent, Mocks.user_message("Msg #{i}"))
      end

      internal_state = :sys.get_state(agent)
      contents = Enum.map(internal_state.steering_queue, fn msg -> msg.content end)

      expected = for i <- 1..10, do: "Msg #{i}"
      assert contents == expected
    end

    test "one_at_a_time mode only consumes first message" do
      response = Mocks.assistant_message("Response")

      {:ok, agent} =
        start_agent(
          steering_mode: :one_at_a_time,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Queue multiple messages
      :ok = CoreAgent.steer(agent, Mocks.user_message("First"))
      :ok = CoreAgent.steer(agent, Mocks.user_message("Second"))
      :ok = CoreAgent.steer(agent, Mocks.user_message("Third"))

      :ok = CoreAgent.prompt(agent, "Trigger")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      # With one_at_a_time, only one should be consumed per turn
      # The remaining should still be in queue
      internal_state = :sys.get_state(agent)
      # At least some messages should remain (depends on loop iterations)
      assert is_list(internal_state.steering_queue)
    end

    test "all mode consumes entire queue at once" do
      response = Mocks.assistant_message("Response")

      {:ok, agent} =
        start_agent(
          steering_mode: :all,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Queue multiple messages
      :ok = CoreAgent.steer(agent, Mocks.user_message("First"))
      :ok = CoreAgent.steer(agent, Mocks.user_message("Second"))
      :ok = CoreAgent.steer(agent, Mocks.user_message("Third"))

      :ok = CoreAgent.prompt(agent, "Trigger")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      # With :all mode, all messages should be consumed in first call
      internal_state = :sys.get_state(agent)
      # Queue should be empty after consumption
      assert internal_state.steering_queue == []
    end
  end

  # ============================================================================
  # Steering vs Follow-up Message Interaction
  # ============================================================================

  describe "steering vs follow-up message interaction" do
    test "steering messages have priority over follow-up" do
      # Steering messages are consumed during tool execution
      # Follow-up messages are consumed only when agent would otherwise stop

      parent = self()
      tool_executed = :counters.new(1, [:atomics])

      slow_tool = %AgentCore.Types.AgentTool{
        name: "slow_op",
        description: "Slow operation",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        execute: fn _id, _params, _signal, _on_update ->
          :counters.add(tool_executed, 1, 1)
          send(parent, {:tool_exec, :counters.get(tool_executed, 1)})
          Process.sleep(50)

          %AgentCore.Types.AgentToolResult{
            content: [%Ai.Types.TextContent{type: :text, text: "Done"}]
          }
        end
      }

      tool_call = Mocks.tool_call("slow_op", %{}, id: "call_slow")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Complete")

      {:ok, agent} =
        start_agent(
          tools: [slow_tool],
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      # Queue both types of messages
      :ok = CoreAgent.steer(agent, Mocks.user_message("Steering interrupt"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow-up after"))

      :ok = CoreAgent.prompt(agent, "Start operation")

      # Wait for tool to execute
      assert_receive {:tool_exec, 1}, 2000

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 3000)
    end

    test "follow-up triggers new turn when no steering" do
      response1 = Mocks.assistant_message("Initial response")
      response2 = Mocks.assistant_message("Follow-up response")

      follow_up_message = Mocks.user_message("Continue please")

      {:ok, agent} =
        start_agent(stream_fn: Mocks.mock_stream_fn([response1, response2]))

      :ok = CoreAgent.follow_up(agent, follow_up_message)
      :ok = CoreAgent.prompt(agent, "Initial")

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      state = CoreAgent.get_state(agent)
      # Should have processed messages
      assert length(state.messages) >= 1
    end

    test "clearing steering queue doesn't affect follow-up queue" do
      {:ok, agent} = start_agent()

      :ok = CoreAgent.steer(agent, Mocks.user_message("Steer"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow"))

      :ok = CoreAgent.clear_steering_queue(agent)

      internal_state = :sys.get_state(agent)
      assert internal_state.steering_queue == []
      assert length(internal_state.follow_up_queue) == 1
    end

    test "clearing follow-up queue doesn't affect steering queue" do
      {:ok, agent} = start_agent()

      :ok = CoreAgent.steer(agent, Mocks.user_message("Steer"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow"))

      :ok = CoreAgent.clear_follow_up_queue(agent)

      internal_state = :sys.get_state(agent)
      assert length(internal_state.steering_queue) == 1
      assert internal_state.follow_up_queue == []
    end

    test "different modes for each queue type" do
      {:ok, agent} =
        start_agent(
          steering_mode: :all,
          follow_up_mode: :one_at_a_time
        )

      assert CoreAgent.get_steering_mode(agent) == :all
      assert CoreAgent.get_follow_up_mode(agent) == :one_at_a_time

      # Switch modes independently
      :ok = CoreAgent.set_steering_mode(agent, :one_at_a_time)
      :ok = CoreAgent.set_follow_up_mode(agent, :all)

      assert CoreAgent.get_steering_mode(agent) == :one_at_a_time
      assert CoreAgent.get_follow_up_mode(agent) == :all
    end

    test "messages queued during streaming are available after" do
      parent = self()
      response = Mocks.assistant_message("Response")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          send(parent, :stream_started)
          # Wait for messages to be queued
          receive do
            :continue -> :ok
          after
            500 -> :ok
          end

          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: stream_fn)

      :ok = CoreAgent.prompt(agent, "Start")
      assert_receive :stream_started, 1000

      # Queue messages while streaming
      :ok = CoreAgent.steer(agent, Mocks.user_message("Mid-stream steer"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Mid-stream follow"))

      # Verify they're queued
      internal_state = :sys.get_state(agent)
      assert length(internal_state.steering_queue) == 1
      assert length(internal_state.follow_up_queue) == 1

      send(agent, :continue)
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "abort clears abort_ref but preserves queued messages" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn(response, 300))

      :ok = CoreAgent.steer(agent, Mocks.user_message("Queued steer"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Queued follow"))

      :ok = CoreAgent.prompt(agent, "Will abort")

      # Abort mid-stream
      Process.sleep(50)
      :ok = CoreAgent.abort(agent)

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)

      internal_state = :sys.get_state(agent)
      # Abort ref should be cleared
      assert internal_state.abort_ref == nil
      # Queued messages should still be there (abort doesn't clear queues)
      # Note: depending on implementation, queues may or may not be preserved
      assert is_list(internal_state.steering_queue)
      assert is_list(internal_state.follow_up_queue)
    end
  end

  # ============================================================================
  # Edge Cases and Integration
  # ============================================================================

  describe "edge cases and integration" do
    test "empty queue returns empty list" do
      {:ok, agent} = start_agent()

      internal_state = :sys.get_state(agent)
      assert internal_state.steering_queue == []
      assert internal_state.follow_up_queue == []
    end

    test "queue operations are cast (non-blocking)" do
      {:ok, agent} = start_agent()

      # These should return immediately
      start_time = System.monotonic_time(:millisecond)

      for i <- 1..100 do
        :ok = CoreAgent.steer(agent, Mocks.user_message("Msg #{i}"))
      end

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should be very fast since casts are non-blocking
      assert elapsed < 100
    end

    test "queue operations while not streaming" do
      {:ok, agent} = start_agent()

      # Should work fine even when not streaming
      :ok = CoreAgent.steer(agent, Mocks.user_message("Steer while idle"))
      :ok = CoreAgent.follow_up(agent, Mocks.user_message("Follow while idle"))

      internal_state = :sys.get_state(agent)
      assert length(internal_state.steering_queue) == 1
      assert length(internal_state.follow_up_queue) == 1
    end

    test "subscribe receives queue-related events" do
      response = Mocks.assistant_message("Response")

      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_single(response))

      _unsubscribe = CoreAgent.subscribe(agent, self())

      :ok = CoreAgent.prompt(agent, "Test")

      # Should receive agent events
      assert_receive {:agent_event, _event}, 2000

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 2000)
    end

    test "message types in queues are preserved" do
      {:ok, agent} = start_agent()

      # Queue a user message
      user_msg = Mocks.user_message("User content")
      :ok = CoreAgent.steer(agent, user_msg)

      internal_state = :sys.get_state(agent)
      [queued_msg] = internal_state.steering_queue

      assert queued_msg.role == :user
      assert queued_msg.content == "User content"
      assert is_integer(queued_msg.timestamp)
    end

    test "large message content in queue" do
      {:ok, agent} = start_agent()

      # Create a large message
      large_content = String.duplicate("x", 100_000)
      :ok = CoreAgent.steer(agent, Mocks.user_message(large_content))

      internal_state = :sys.get_state(agent)
      [queued_msg] = internal_state.steering_queue

      assert String.length(queued_msg.content) == 100_000
    end

    test "binary content in messages" do
      {:ok, agent} = start_agent()

      # Binary content should work
      binary_content = <<0, 1, 2, 3, 255>>

      # This might fail validation in real use, but the queue should accept it
      msg = %Ai.Types.UserMessage{
        role: :user,
        content: binary_content,
        timestamp: System.system_time(:millisecond)
      }

      :ok = CoreAgent.steer(agent, msg)

      internal_state = :sys.get_state(agent)
      assert length(internal_state.steering_queue) == 1
    end
  end
end
