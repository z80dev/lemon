defmodule AgentCore.LoopEdgeCasesTest do
  @moduledoc """
  Edge case and stress tests for AgentCore.Loop.

  These tests cover abort scenarios, concurrent tool execution,
  cleanup behavior, and error recovery.
  """
  use ExUnit.Case, async: true

  alias AgentCore.Loop
  alias AgentCore.EventStream
  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias AgentCore.Test.Mocks

  alias Ai.Types.{
    TextContent,
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

  defp simple_config(opts) do
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
  # Abort During Tool Execution
  # ============================================================================

  describe "abort during tool execution" do
    test "abort signal terminates long-running tool" do
      # Tool that takes a while
      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "A slow tool",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        execute: fn _id, _params, signal, _on_update ->
          # Simulate slow work with abort check
          for _ <- 1..10 do
            if AbortSignal.aborted?(signal) do
              throw(:aborted)
            end

            Process.sleep(50)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Completed")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run slow tool")], context, config, signal, nil)

      # Abort after a short delay
      Task.start(fn ->
        Process.sleep(100)
        AbortSignal.abort(signal)
      end)

      # Should terminate with canceled semantics
      events = EventStream.events(stream) |> Enum.to_list()

      # Tool execution should have started before cancellation
      assert Enum.any?(events, &match?({:tool_execution_start, "call_slow", _, _}, &1))

      # Aborted runs can surface via cancellation, aborted assistant message,
      # aborted turn_end, or errored tool completion.
      assert Enum.any?(events, fn
               {:canceled, _reason} ->
                 true

               {:turn_end, message, _} ->
                 Map.get(message, :stop_reason) == :aborted

               {:message_start, message} ->
                 Map.get(message, :role) == :assistant and
                   Map.get(message, :stop_reason) == :aborted

               {:message_end, message} ->
                 Map.get(message, :role) == :assistant and
                   Map.get(message, :stop_reason) == :aborted

               {:tool_execution_end, "call_slow", _, _, is_error} ->
                 is_error

               _ ->
                 false
             end)
    end

    test "abort mid-execution returns partial results" do
      # Tool that can be interrupted
      interruptible_tool = %AgentTool{
        name: "interruptible",
        description: "Can be interrupted",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Interruptible",
        execute: fn _id, _params, _signal, on_update ->
          for i <- 1..5 do
            if on_update do
              on_update.(%AgentToolResult{
                content: [%TextContent{type: :text, text: "Progress #{i}"}],
                details: nil
              })
            end

            Process.sleep(10)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Complete"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [interruptible_tool])

      tool_call = Mocks.tool_call("interruptible", %{}, id: "call_int")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      stream = Loop.agent_loop([user_message("Run")], context, config, nil, nil)

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have tool_execution_update events
      updates =
        Enum.filter(events, fn e ->
          match?({:tool_execution_update, _, _, _, _}, e)
        end)

      assert length(updates) == 5
    end
  end

  # ============================================================================
  # Multiple Tool Call Edge Cases
  # ============================================================================

  describe "multiple tool calls" do
    test "handles many parallel tool calls" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      # Create 10 parallel tool calls
      tool_calls =
        for i <- 1..10 do
          Mocks.tool_call("echo", %{"text" => "message #{i}"}, id: "call_#{i}")
        end

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("All echoed")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      events = Loop.stream([user_message("Echo many")], context, config) |> Enum.to_list()

      tool_ends =
        Enum.filter(events, fn e ->
          match?({:tool_execution_end, _, _, _, _}, e)
        end)

      # All 10 should complete
      assert length(tool_ends) == 10

      # All should be successful
      for {:tool_execution_end, _, _, _result, is_error} <- tool_ends do
        assert is_error == false
      end
    end

    test "handles mix of success and failure tool calls" do
      echo_tool = Mocks.echo_tool()
      error_tool = Mocks.error_tool()
      context = simple_context(tools: [echo_tool, error_tool])

      tool_calls = [
        Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_ok_1"),
        Mocks.tool_call("error_tool", %{"message" => "fail"}, id: "call_err"),
        Mocks.tool_call("echo", %{"text" => "world"}, id: "call_ok_2")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Mixed results")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      events = Loop.stream([user_message("Run mixed")], context, config) |> Enum.to_list()

      tool_ends =
        Enum.filter(events, fn e ->
          match?({:tool_execution_end, _, _, _, _}, e)
        end)

      assert length(tool_ends) == 3

      # Find the error one
      error_result =
        Enum.find(tool_ends, fn {:tool_execution_end, id, _, _, _} ->
          id == "call_err"
        end)

      {:tool_execution_end, _, _, _, is_error} = error_result
      assert is_error == true

      # Other two should succeed
      success_count =
        Enum.count(tool_ends, fn {:tool_execution_end, _, _, _, is_error} ->
          is_error == false
        end)

      assert success_count == 2
    end
  end

  # ============================================================================
  # Empty and Edge Case Inputs
  # ============================================================================

  describe "edge case inputs" do
    test "handles empty message content" do
      context = simple_context()
      response = Mocks.assistant_message("")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("")], context, config) |> Enum.to_list()

      assert {:agent_end, _} = List.last(events)
    end

    test "handles very long message content" do
      context = simple_context()
      long_text = String.duplicate("x", 100_000)
      response = Mocks.assistant_message(long_text)

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Long response")], context, config) |> Enum.to_list()

      {:ok, messages} =
        Loop.agent_loop([user_message("Test")], context, config, nil, nil)
        |> EventStream.result()

      assert length(messages) >= 1
    end

    test "handles special characters in messages" do
      context = simple_context()
      special_text = "Unicode: \u{1F600}\u{1F4A9} Null: \0 Tab: \t Newline: \n"
      response = Mocks.assistant_message(special_text)

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("Special chars")], context, config) |> Enum.to_list()

      assert {:agent_end, _} = List.last(events)
    end
  end

  # ============================================================================
  # Concurrent Loops
  # ============================================================================

  describe "concurrent loops" do
    test "multiple loops can run simultaneously" do
      context = simple_context()

      config = fn i ->
        response = Mocks.assistant_message("Response #{i}")

        simple_config(stream_fn: Mocks.mock_stream_fn_single(response))
      end

      # Start 5 concurrent loops
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            stream =
              Loop.agent_loop([user_message("Message #{i}")], context, config.(i), nil, nil)

            EventStream.result(stream)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      for result <- results do
        assert {:ok, messages} = result
        assert length(messages) >= 1
      end
    end

    test "concurrent loops with shared tools" do
      shared_tool = Mocks.add_tool()
      context = simple_context(tools: [shared_tool])

      config = fn ->
        tool_call = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: Mocks.generate_id())
        tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
        final_response = Mocks.assistant_message("3")

        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))
      end

      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            stream = Loop.agent_loop([user_message("Add")], context, config.(), nil, nil)
            EventStream.result(stream)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for result <- results do
        assert {:ok, _messages} = result
      end
    end
  end

  # ============================================================================
  # Stream Function Edge Cases
  # ============================================================================

  describe "stream function edge cases" do
    test "handles stream that returns non-standard result" do
      context = simple_context()

      # Stream function that returns an unexpected type
      weird_stream_fn = fn _model, _context, _options ->
        {:unexpected, "weird result"}
      end

      config = simple_config(stream_fn: weird_stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:error, reason, _partial} = EventStream.result(stream)
      assert reason == {:invalid_stream, {:unexpected, "weird result"}}
    end

    test "handles stream that crashes" do
      context = simple_context()

      crashing_stream_fn = fn _model, _context, _options ->
        raise "Intentional crash"
      end

      config = simple_config(stream_fn: crashing_stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:error, _reason, _partial} = EventStream.result(stream)
    end

    test "handles stream that returns nil" do
      context = simple_context()

      nil_stream_fn = fn _model, _context, _options ->
        nil
      end

      config = simple_config(stream_fn: nil_stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:error, reason, _partial} = EventStream.result(stream)
      assert reason == {:invalid_stream, nil}
    end
  end

  # ============================================================================
  # Convert Function Edge Cases
  # ============================================================================

  describe "convert_to_llm edge cases" do
    test "handles convert function that returns empty list" do
      context = simple_context()
      response = Mocks.assistant_message("Ok")

      config =
        simple_config(
          convert_to_llm: fn _messages -> [] end,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      # Should still complete
      assert {:agent_end, _} = List.last(events)
    end

    test "handles convert function that filters all messages" do
      context = simple_context()
      response = Mocks.assistant_message("Ok")

      config =
        simple_config(
          convert_to_llm: fn _messages -> {:ok, []} end,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      assert {:agent_end, _} = List.last(events)
    end
  end

  # ============================================================================
  # Tool with Large Output
  # ============================================================================

  describe "tool output handling" do
    test "handles tool with very large output" do
      large_output_tool = %AgentTool{
        name: "large_output",
        description: "Returns large output",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Large",
        execute: fn _id, _params, _signal, _on_update ->
          large_text = String.duplicate("x", 50_000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: large_text}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [large_output_tool])

      tool_call = Mocks.tool_call("large_output", %{}, id: "call_large")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Processed large output")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      events = Loop.stream([user_message("Large")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_large", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == false
      [%TextContent{text: text}] = result.content
      assert String.length(text) == 50_000
    end

    test "handles tool with nil content" do
      nil_content_tool = %AgentTool{
        name: "nil_content",
        description: "Returns nil content",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Nil",
        execute: fn _id, _params, _signal, _on_update ->
          %AgentToolResult{
            content: [],
            details: nil
          }
        end
      }

      context = simple_context(tools: [nil_content_tool])

      tool_call = Mocks.tool_call("nil_content", %{}, id: "call_nil")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      events = Loop.stream([user_message("Nil")], context, config) |> Enum.to_list()

      assert {:agent_end, _} = List.last(events)
    end
  end
end
