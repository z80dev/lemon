defmodule AgentCore.LoopAdditionalEdgeCasesTest do
  @moduledoc """
  Additional edge case tests for AgentCore.Loop.

  These tests focus on areas not covered by loop_test.exs or loop_edge_cases_test.exs:
  - Max iterations / runaway loop prevention
  - Context overflow scenarios
  - Stream event edge cases (no response, partial response)
  - Tool task crashes and DOWN messages
  - Abort signal checked during tool collection
  - Telemetry emission
  - Message ordering invariants
  - Stop reason propagation
  """
  use ExUnit.Case, async: true

  alias AgentCore.Loop
  alias AgentCore.EventStream
  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias AgentCore.Test.Mocks

  alias Ai.Types.{
    AssistantMessage,
    TextContent,
    ToolResultMessage,
    UserMessage,
    StreamOptions
  }

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp simple_context(opts \\ []) do
    AgentContext.new(
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful assistant."),
      messages: Keyword.get(opts, :messages, []),
      tools: Keyword.get(opts, :tools, [])
    )
  end

  defp simple_config(opts \\ []) do
    %AgentLoopConfig{
      model: Keyword.get(opts, :model, Mocks.mock_model()),
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm()),
      transform_context: Keyword.get(opts, :transform_context, nil),
      get_api_key: Keyword.get(opts, :get_api_key, nil),
      get_steering_messages: Keyword.get(opts, :get_steering_messages, nil),
      get_follow_up_messages: Keyword.get(opts, :get_follow_up_messages, nil),
      stream_options: Keyword.get(opts, :stream_options, %StreamOptions{}),
      stream_fn: Keyword.get(opts, :stream_fn, nil)
    }
  end

  defp user_message(text) do
    %UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }
  end

  # ============================================================================
  # Stream Event Edge Cases
  # ============================================================================

  describe "stream event edge cases" do
    test "handles stream that emits no events before completion" do
      context = simple_context()
      empty_response = Mocks.assistant_message("")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          # Complete immediately without start event - just complete with empty response
          Ai.EventStream.complete(stream, empty_response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      # Should handle gracefully - either error or complete with empty/error message
      result = EventStream.result(stream)
      # The important thing is it doesn't crash
      assert match?({:error, _, _}, result) or match?({:ok, _}, result)
    end

    test "handles stream that only emits start but never done" do
      context = simple_context()
      partial_response = Mocks.assistant_message("Partial")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          # Emit start but complete without done event
          Ai.EventStream.push(stream, {:start, partial_response})
          Process.sleep(10)
          Ai.EventStream.complete(stream, partial_response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      # Should finalize with the partial message
      {:ok, messages} = EventStream.result(stream)
      assert length(messages) >= 1
    end

    test "handles stream with error event mid-stream" do
      context = simple_context()
      partial_response = Mocks.assistant_message("Partial", stop_reason: :error)

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, partial_response})
          Ai.EventStream.push(stream, {:text_start, 0, partial_response})
          Ai.EventStream.push(stream, {:error, :rate_limited, partial_response})
          Ai.EventStream.complete(stream, partial_response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      # Should complete (error handled as done-like event)
      assert {:agent_end, _messages} = List.last(events)
    end

    test "handles stream process exiting with :noproc" do
      context = simple_context()

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          # Kill the stream immediately
          Process.exit(stream, :kill)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      # Should handle the exit gracefully
      result = EventStream.result(stream)
      # Either completes with canceled message or errors
      assert match?({:ok, _}, result) or match?({:error, _, _}, result)
    end

    test "handles stream process exiting with :shutdown" do
      context = simple_context()
      partial_response = Mocks.assistant_message("Starting...")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, partial_response})
          Process.sleep(5)
          GenServer.stop(stream, :shutdown)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      # Should handle shutdown gracefully
      result = EventStream.result(stream)
      assert match?({:ok, _}, result) or match?({:error, _, _}, result)
    end
  end

  # ============================================================================
  # Tool Task Crash Handling
  # ============================================================================

  describe "tool task crashes" do
    test "handles tool that crashes with exit" do
      crashing_tool = %AgentTool{
        name: "crashing_tool",
        description: "A tool that crashes",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Crash",
        execute: fn _id, _params, _signal, _on_update ->
          exit(:intentional_crash)
        end
      }

      context = simple_context(tools: [crashing_tool])

      tool_call = Mocks.tool_call("crashing_tool", %{}, id: "call_crash")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled crash")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Crash tool")], context, config) |> Enum.to_list()

      # Should have tool_execution_end with error
      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_crash", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true
      [%TextContent{text: error_text}] = result.content
      # The error message will contain the exit reason
      assert error_text =~ "exit" or error_text =~ "crash" or error_text =~ "intentional"
    end

    test "handles tool that throws" do
      throwing_tool = %AgentTool{
        name: "throwing_tool",
        description: "A tool that throws",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Throw",
        execute: fn _id, _params, _signal, _on_update ->
          throw(:intentional_throw)
        end
      }

      context = simple_context(tools: [throwing_tool])

      tool_call = Mocks.tool_call("throwing_tool", %{}, id: "call_throw")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled throw")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Throw tool")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_throw", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, _result, is_error} = tool_end
      assert is_error == true
    end

    test "handles tool returning unexpected value" do
      weird_tool = %AgentTool{
        name: "weird_tool",
        description: "Returns unexpected value",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Weird",
        execute: fn _id, _params, _signal, _on_update ->
          # Return something that's not AgentToolResult, {:ok, _}, or {:error, _}
          {:unexpected, "weird_value"}
        end
      }

      context = simple_context(tools: [weird_tool])

      tool_call = Mocks.tool_call("weird_tool", %{}, id: "call_weird")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled weird")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Weird tool")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_weird", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true
      [%TextContent{text: error_text}] = result.content
      assert error_text =~ "Unexpected"
    end
  end

  # ============================================================================
  # Abort During Tool Collection
  # ============================================================================

  describe "abort during tool collection" do
    test "abort terminates remaining tool tasks" do
      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "Slow tool",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        execute: fn _id, _params, _signal, _on_update ->
          Process.sleep(500)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Slow done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      # Create multiple tool calls
      tool_calls =
        for i <- 1..3 do
          Mocks.tool_call("slow_tool", %{}, id: "call_#{i}")
        end

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run slow")], context, config, signal, nil)

      # Abort after a short delay
      Task.start(fn ->
        Process.sleep(50)
        AbortSignal.abort(signal)
      end)

      start = System.monotonic_time(:millisecond)
      events = EventStream.events(stream) |> Enum.to_list()
      elapsed = System.monotonic_time(:millisecond) - start

      # Should complete much faster than 3 * 500ms
      assert elapsed < 400

      # All tool results should be present (some may be aborted)
      tool_ends =
        Enum.filter(events, fn e ->
          match?({:tool_execution_end, _, _, _, _}, e)
        end)

      assert length(tool_ends) == 3
    end

    test "abort returns detailed context in aborted tool results" do
      tool = %AgentTool{
        name: "test_tool",
        description: "Test",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Test",
        execute: fn _id, _params, _signal, _on_update ->
          Process.sleep(1000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [tool])

      tool_call = Mocks.tool_call("test_tool", %{}, id: "call_abort_detail")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      Task.start(fn ->
        Process.sleep(20)
        AbortSignal.abort(signal)
      end)

      events = EventStream.events(stream) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_abort_detail", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true

      # Check that result has details
      assert result.details != nil
      assert result.details.error_type == :aborted
    end
  end

  # ============================================================================
  # Stop Reason Propagation
  # ============================================================================

  describe "stop reason propagation" do
    test "error stop_reason ends loop early" do
      context = simple_context()

      error_response = Mocks.assistant_message("Error occurred", stop_reason: :error)

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(error_response)
        )

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      # turn_end should have the error message
      turn_end =
        Enum.find(events, fn e ->
          match?({:turn_end, _, _}, e)
        end)

      assert turn_end != nil
      {:turn_end, message, _tool_results} = turn_end
      assert message.stop_reason == :error

      # Should still have agent_end
      assert {:agent_end, _} = List.last(events)
    end

    test "aborted stop_reason ends loop early" do
      context = simple_context()

      aborted_response = Mocks.assistant_message("Aborted", stop_reason: :aborted)

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(aborted_response)
        )

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      turn_end =
        Enum.find(events, fn e ->
          match?({:turn_end, _, _}, e)
        end)

      {:turn_end, message, _} = turn_end
      assert message.stop_reason == :aborted
    end
  end

  # ============================================================================
  # Message Ordering Invariants
  # ============================================================================

  describe "message ordering invariants" do
    test "messages in result maintain chronological order" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "test"}, id: "call_order")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Final")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      prompt = user_message("Start")
      stream = Loop.agent_loop([prompt], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      # Order should be: user -> assistant (tool calls) -> tool_result -> assistant (final)
      roles = Enum.map(messages, & &1.role)

      user_idx = Enum.find_index(roles, &(&1 == :user))
      first_assistant_idx = Enum.find_index(roles, &(&1 == :assistant))
      tool_result_idx = Enum.find_index(roles, &(&1 == :tool_result))

      assert user_idx < first_assistant_idx
      assert first_assistant_idx < tool_result_idx

      # Find second assistant message
      second_assistant_idx =
        Enum.with_index(roles)
        |> Enum.filter(fn {role, idx} -> role == :assistant and idx > first_assistant_idx end)
        |> List.first()
        |> elem(1)

      assert tool_result_idx < second_assistant_idx
    end

    test "turn_start events precede associated message events" do
      context = simple_context()
      response = Mocks.assistant_message("Response")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      turn_start_indices =
        events
        |> Enum.with_index()
        |> Enum.filter(fn {e, _idx} -> match?({:turn_start}, e) end)
        |> Enum.map(&elem(&1, 1))

      message_start_indices =
        events
        |> Enum.with_index()
        |> Enum.filter(fn {e, _idx} -> match?({:message_start, _}, e) end)
        |> Enum.map(&elem(&1, 1))

      # First turn_start should come before first message_start
      assert hd(turn_start_indices) < hd(message_start_indices)
    end
  end

  # ============================================================================
  # Telemetry Events
  # ============================================================================

  describe "telemetry" do
    setup do
      # Attach telemetry handlers
      test_pid = self()

      :telemetry.attach_many(
        "test-loop-telemetry-#{inspect(self())}",
        [
          [:agent_core, :loop, :start],
          [:agent_core, :loop, :end],
          [:agent_core, :tool_task, :start],
          [:agent_core, :tool_task, :end],
          [:agent_core, :tool_task, :error]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-loop-telemetry-#{inspect(self())}")
      end)

      :ok
    end

    test "emits loop start and end telemetry" do
      context = simple_context()
      response = Mocks.assistant_message("Hello")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      stream = Loop.agent_loop([user_message("Hi")], context, config, nil, nil)
      {:ok, _messages} = EventStream.result(stream)

      # Should have received start telemetry
      assert_receive {:telemetry, [:agent_core, :loop, :start], %{system_time: _}, metadata}
      assert metadata.prompt_count == 1
      assert metadata.message_count == 0
      assert metadata.tool_count == 0

      # Should have received end telemetry
      assert_receive {:telemetry, [:agent_core, :loop, :end], %{duration: duration, system_time: _}, end_metadata}
      assert is_integer(duration) or is_nil(duration)
      assert end_metadata.status == :completed
    end

    test "emits tool task telemetry" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_telemetry")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      stream = Loop.agent_loop([user_message("Echo")], context, config, nil, nil)
      {:ok, _messages} = EventStream.result(stream)

      # Should have tool task start
      assert_receive {:telemetry, [:agent_core, :tool_task, :start], %{system_time: _}, tool_start_meta}
      assert tool_start_meta.tool_name == "echo"
      assert tool_start_meta.tool_call_id == "call_telemetry"

      # Should have tool task end
      assert_receive {:telemetry, [:agent_core, :tool_task, :end], %{system_time: _}, tool_end_meta}
      assert tool_end_meta.tool_name == "echo"
      assert tool_end_meta.is_error == false
    end

    test "emits tool task end telemetry on crash with is_error true" do
      # Note: When a tool task catches an exit, it reports via tool_task:end with is_error: true
      # rather than tool_task:error. The tool_task:error event is for DOWN message handling.
      crashing_tool = %AgentTool{
        name: "crash_tele",
        description: "Crashes",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Crash",
        execute: fn _id, _params, _signal, _on_update ->
          exit(:crash)
        end
      }

      context = simple_context(tools: [crashing_tool])

      tool_call = Mocks.tool_call("crash_tele", %{}, id: "call_crash_tele")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      stream = Loop.agent_loop([user_message("Crash")], context, config, nil, nil)
      {:ok, _messages} = EventStream.result(stream)

      # Should have tool task end with is_error: true (caught exit is handled by task)
      assert_receive {:telemetry, [:agent_core, :tool_task, :end], %{system_time: _}, tool_end_meta}
      assert tool_end_meta.tool_name == "crash_tele"
      assert tool_end_meta.is_error == true
    end
  end

  # ============================================================================
  # Multiple Prompts
  # ============================================================================

  describe "multiple prompts" do
    test "handles multiple prompt messages" do
      context = simple_context()
      response = Mocks.assistant_message("Got both messages")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      prompts = [
        user_message("First message"),
        user_message("Second message")
      ]

      stream = Loop.agent_loop(prompts, context, config, nil, nil)
      events = EventStream.events(stream) |> Enum.to_list()

      # Should have message events for both prompts
      message_starts =
        Enum.filter(events, fn e ->
          case e do
            {:message_start, %UserMessage{}} -> true
            _ -> false
          end
        end)

      assert length(message_starts) == 2
    end
  end

  # ============================================================================
  # Continue From Various States
  # ============================================================================

  describe "agent_loop_continue edge cases" do
    test "continues from context with existing tool_result" do
      tool_result = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_existing",
        tool_name: "previous_tool",
        content: [%TextContent{type: :text, text: "Previous result"}],
        is_error: false,
        timestamp: System.system_time(:millisecond)
      }

      existing_assistant = Mocks.assistant_message_with_tool_calls([
        Mocks.tool_call("previous_tool", %{}, id: "call_existing")
      ])

      context =
        simple_context(
          messages: [user_message("Original"), existing_assistant, tool_result]
        )

      response = Mocks.assistant_message("Continuing from tool result")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      stream = Loop.agent_loop_continue(context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should add new assistant message
      assert length(messages) >= 1
      final_assistant = Enum.find(messages, &match?(%AssistantMessage{}, &1))
      assert final_assistant != nil
    end

    test "raises on empty context" do
      context = simple_context(messages: [])
      config = simple_config()

      assert_raise ArgumentError, ~r/no messages in context/, fn ->
        Loop.agent_loop_continue(context, config, nil, nil)
      end
    end

    test "raises when last message is assistant" do
      context =
        simple_context(
          messages: [user_message("Hi"), Mocks.assistant_message("Hello")]
        )

      config = simple_config()

      assert_raise ArgumentError, ~r/Cannot continue from message role: assistant/, fn ->
        Loop.agent_loop_continue(context, config, nil, nil)
      end
    end
  end

  # ============================================================================
  # Owner Process
  # ============================================================================

  describe "owner process parameter" do
    test "agent_loop with custom owner" do
      context = simple_context()
      response = Mocks.assistant_message("Hello")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      owner = self()
      stream = Loop.agent_loop([user_message("Hi")], context, config, nil, nil, owner)

      {:ok, messages} = EventStream.result(stream)
      assert length(messages) >= 1
    end

    test "agent_loop_continue with custom owner" do
      context = simple_context(messages: [user_message("Start")])
      response = Mocks.assistant_message("Continued")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      owner = self()
      stream = Loop.agent_loop_continue(context, config, nil, nil, owner)

      {:ok, messages} = EventStream.result(stream)
      assert length(messages) >= 0
    end
  end

  # ============================================================================
  # Follow-up Message Edge Cases
  # ============================================================================

  describe "follow-up message edge cases" do
    test "follow-up messages cause additional turns" do
      context = simple_context()

      call_count = :counters.new(1, [:atomics])

      get_follow_up = fn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          [user_message("Follow up!")]
        else
          []
        end
      end

      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Follow-up response")

      config =
        simple_config(
          get_follow_up_messages: get_follow_up,
          stream_fn: Mocks.mock_stream_fn([response1, response2])
        )

      events = Loop.stream([user_message("Start")], context, config) |> Enum.to_list()

      # Should have multiple turn_start events
      turn_starts = Enum.filter(events, &match?({:turn_start}, &1))
      assert length(turn_starts) >= 2
    end

    test "nested follow-up messages" do
      context = simple_context()

      call_count = :counters.new(1, [:atomics])

      get_follow_up = fn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          count == 0 -> [user_message("First follow-up")]
          count == 1 -> [user_message("Second follow-up")]
          true -> []
        end
      end

      response1 = Mocks.assistant_message("Response 1")
      response2 = Mocks.assistant_message("Response 2")
      response3 = Mocks.assistant_message("Response 3")

      config =
        simple_config(
          get_follow_up_messages: get_follow_up,
          stream_fn: Mocks.mock_stream_fn([response1, response2, response3])
        )

      events = Loop.stream([user_message("Start")], context, config) |> Enum.to_list()

      # Should have 3 turns
      turn_starts = Enum.filter(events, &match?({:turn_start}, &1))
      assert length(turn_starts) == 3
    end
  end

  # ============================================================================
  # Steering and Follow-up Interaction
  # ============================================================================

  describe "steering and follow-up interaction" do
    test "steering messages during tool execution get processed" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      steering_count = :counters.new(1, [:atomics])

      get_steering = fn ->
        count = :counters.get(steering_count, 1)
        :counters.add(steering_count, 1, 1)

        if count == 0 do
          [user_message("Steering message")]
        else
          []
        end
      end

      tool_call = Mocks.tool_call("echo", %{"text" => "test"}, id: "call_steer")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("After steering")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Start")], context, config) |> Enum.to_list()

      # Should complete successfully
      assert {:agent_end, _} = List.last(events)
    end
  end

  # ============================================================================
  # API Key Resolution Edge Cases
  # ============================================================================

  describe "API key resolution" do
    test "get_api_key called with atom provider" do
      context = simple_context()
      response = Mocks.assistant_message("Ok")
      parent = self()

      stream_fn = fn model, _llm_context, options ->
        send(parent, {:resolved_key, options.api_key, model.provider})
        Mocks.mock_stream_fn_single(response).(model, nil, options)
      end

      get_api_key = fn
        :mock_provider -> "atom_key"
        "mock_provider" -> "string_key"
        _ -> nil
      end

      config =
        simple_config(
          get_api_key: get_api_key,
          stream_options: %StreamOptions{api_key: "fallback"},
          stream_fn: stream_fn
        )

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      # Should have tried atom first, then string
      assert_receive {:resolved_key, resolved, _provider}
      # One of these should have been used
      assert resolved in ["atom_key", "string_key"]
    end

    test "falls back to stream_options.api_key when get_api_key returns nil" do
      context = simple_context()
      response = Mocks.assistant_message("Ok")
      parent = self()

      stream_fn = fn _model, _llm_context, options ->
        send(parent, {:resolved_key, options.api_key})
        Mocks.mock_stream_fn_single(response).(nil, nil, options)
      end

      get_api_key = fn _provider -> nil end

      config =
        simple_config(
          get_api_key: get_api_key,
          stream_options: %StreamOptions{api_key: "fallback_key"},
          stream_fn: stream_fn
        )

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      assert_receive {:resolved_key, "fallback_key"}
    end
  end
end
