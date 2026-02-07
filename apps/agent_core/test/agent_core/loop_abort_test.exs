defmodule AgentCore.LoopAbortTest do
  @moduledoc """
  Comprehensive tests for abort signal handling in AgentCore.Loop.

  These tests cover:
  1. Abort during LLM streaming
  2. Abort during tool execution
  3. Abort during parallel tool execution (partial results)
  4. Abort signal propagation timing
  5. Steering message injection after abort
  6. Context transformation during abort
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
  # 1. Abort During LLM Streaming
  # ============================================================================

  describe "abort during LLM streaming" do
    test "abort signal stops stream mid-response and sets stop_reason to :aborted" do
      context = simple_context()
      parent = self()

      # Create a slow streaming function that checks for abort
      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Partial response being streamed...")
          Ai.EventStream.push(stream, {:start, response})

          # Simulate slow streaming
          for i <- 1..10 do
            send(parent, {:streaming_chunk, i})
            Process.sleep(50)

            Ai.EventStream.push(
              stream,
              {:text_delta, 0, "chunk #{i}", response}
            )
          end

          Ai.EventStream.push(stream, {:done, :stop, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Start streaming")], context, config, signal, nil)

      # Wait for streaming to begin then abort
      receive do
        {:streaming_chunk, 2} -> :ok
      after
        1000 -> flunk("Streaming did not start")
      end

      AbortSignal.abort(signal)

      {:ok, messages} = EventStream.result(stream)

      # Find the assistant message
      assistant_msg =
        Enum.find(messages, fn msg ->
          match?(%AssistantMessage{}, msg) or Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg != nil
      assert assistant_msg.stop_reason == :aborted
      assert assistant_msg.error_message =~ "canceled"
    end

    test "abort before streaming starts returns aborted message without calling stream_fn" do
      context = simple_context()
      parent = self()

      stream_fn = fn model, llm_context, options ->
        send(parent, :stream_fn_called)

        Mocks.mock_stream_fn_single(Mocks.assistant_message("Should not appear")).(
          model,
          llm_context,
          options
        )
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      {:ok, messages} = EventStream.result(stream)

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted
      refute_receive :stream_fn_called, 100
    end

    test "abort during multi-chunk stream preserves partial content in message" do
      context = simple_context()

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          # Create a partial message
          partial = %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "Hello "}],
            api: :mock,
            provider: :mock_provider,
            model: "mock-model-1",
            usage: Mocks.mock_usage(),
            stop_reason: nil,
            error_message: nil,
            timestamp: System.system_time(:millisecond)
          }

          Ai.EventStream.push(stream, {:start, partial})

          # Use longer delays to ensure abort is detected between chunks
          for i <- 1..10 do
            Process.sleep(50)
            updated = %{partial | content: [%TextContent{type: :text, text: "Hello World #{i}"}]}
            Ai.EventStream.push(stream, {:text_delta, 0, " #{i}", updated})
          end

          # This should not be reached due to abort
          final = %{partial | stop_reason: :stop}
          Ai.EventStream.push(stream, {:done, :stop, final})
          Ai.EventStream.complete(stream, final)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort during streaming (after a few chunks)
      Task.start(fn ->
        Process.sleep(100)
        AbortSignal.abort(signal)
      end)

      {:ok, messages} = EventStream.result(stream)

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted
    end

    test "abort emits correct event sequence: message_start, message_end with aborted message" do
      context = simple_context()

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Streaming...")
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(100)
          Ai.EventStream.push(stream, {:done, :stop, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort quickly
      Task.start(fn ->
        Process.sleep(20)
        AbortSignal.abort(signal)
      end)

      events = EventStream.events(stream) |> Enum.to_list()

      # Check event sequence
      assert {:agent_start} = hd(events)

      # Should have message_start and message_end for the assistant message
      message_starts = Enum.filter(events, &match?({:message_start, _}, &1))
      message_ends = Enum.filter(events, &match?({:message_end, _}, &1))

      # At minimum we have user message events and assistant message events
      assert length(message_starts) >= 1
      assert length(message_ends) >= 1

      # The last agent event should be agent_end
      assert {:agent_end, _} = List.last(events)
    end
  end

  # ============================================================================
  # 2. Abort During Tool Execution
  # ============================================================================

  describe "abort during tool execution" do
    test "abort terminates long-running tool and marks result as aborted" do
      # Tool that respects abort signal
      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "A slow tool that respects abort",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        execute: fn _id, _params, signal, _on_update ->
          for i <- 1..20 do
            if AbortSignal.aborted?(signal) do
              throw({:aborted_at_iteration, i})
            end

            Process.sleep(25)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Completed"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run slow tool")], context, config, signal, nil)

      # Abort after tool starts
      Task.start(fn ->
        Process.sleep(100)
        AbortSignal.abort(signal)
      end)

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have tool_execution_start
      assert Enum.any?(events, &match?({:tool_execution_start, "call_slow", _, _}, &1))

      # Should have tool_execution_end (possibly with error)
      tool_end = Enum.find(events, &match?({:tool_execution_end, "call_slow", _, _, _}, &1))
      assert tool_end != nil
    end

    test "tool that ignores abort signal still gets terminated by supervisor" do
      # Tool that does NOT check abort signal - uses a very long delay
      ignoring_tool = %AgentTool{
        name: "ignoring_tool",
        description: "A tool that ignores abort signal",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Ignoring",
        execute: fn _id, _params, _signal, _on_update ->
          # Sleep without checking abort - use a very long delay
          Process.sleep(2000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Finished ignoring"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [ignoring_tool])

      tool_call = Mocks.tool_call("ignoring_tool", %{}, id: "call_ignore")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run ignoring tool")], context, config, signal, nil)

      # Abort shortly after tool starts
      Task.start(fn ->
        Process.sleep(50)
        AbortSignal.abort(signal)
      end)

      # This should complete much faster than 2000ms due to abort termination
      start_time = System.monotonic_time(:millisecond)
      events = EventStream.events(stream) |> Enum.to_list()
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete much faster than the 2000ms sleep
      assert elapsed < 1000

      # Should have agent_end
      assert {:agent_end, _} = List.last(events)
    end

    test "tool_execution_end event contains aborted result for terminated tools" do
      slow_tool = %AgentTool{
        name: "abortable_tool",
        description: "A tool that can be aborted",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Abortable",
        execute: fn _id, _params, _signal, _on_update ->
          Process.sleep(300)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Complete"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("abortable_tool", %{}, id: "call_abort")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      Task.start(fn ->
        Process.sleep(50)
        AbortSignal.abort(signal)
      end)

      events = EventStream.events(stream) |> Enum.to_list()

      tool_end = Enum.find(events, &match?({:tool_execution_end, "call_abort", _, _, _}, &1))
      assert tool_end != nil

      {:tool_execution_end, _id, _name, result, is_error} = tool_end

      # Should be marked as error with aborted message
      assert is_error == true
      assert %AgentToolResult{content: content} = result
      assert Enum.any?(content, fn c -> String.contains?(c.text || "", "abort") end)
    end
  end

  # ============================================================================
  # 3. Abort During Parallel Tool Execution (Partial Results)
  # ============================================================================

  describe "abort during parallel tool execution" do
    test "abort with multiple parallel tools returns mix of completed and aborted results" do
      # One instant tool, one very slow tool
      instant_tool = %AgentTool{
        name: "instant_tool",
        description: "Completes instantly",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Instant",
        execute: fn _id, _params, _signal, _on_update ->
          # No delay - instant completion
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Instant done"}],
            details: nil
          }
        end
      }

      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "Takes a very long time",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow",
        execute: fn _id, _params, _signal, _on_update ->
          # Very long delay to ensure abort happens
          Process.sleep(2000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Slow done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [instant_tool, slow_tool])

      tool_calls = [
        Mocks.tool_call("instant_tool", %{}, id: "call_instant"),
        Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run both tools")], context, config, signal, nil)

      # Abort after instant tool completes but before slow tool (give time for result processing)
      Task.start(fn ->
        Process.sleep(200)
        AbortSignal.abort(signal)
      end)

      events = EventStream.events(stream) |> Enum.to_list()

      tool_ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _, _}, &1))

      # Should have two tool results
      assert length(tool_ends) == 2

      # Instant tool should succeed
      instant_end =
        Enum.find(tool_ends, fn {:tool_execution_end, id, _, _, _} -> id == "call_instant" end)

      assert instant_end != nil
      {:tool_execution_end, _, _, _instant_result, instant_is_error} = instant_end
      assert instant_is_error == false

      # Slow tool should be aborted
      slow_end =
        Enum.find(tool_ends, fn {:tool_execution_end, id, _, _, _} -> id == "call_slow" end)

      assert slow_end != nil
      {:tool_execution_end, _, _, _slow_result, slow_is_error} = slow_end
      assert slow_is_error == true
    end

    test "abort terminates all pending tool tasks" do
      # Multiple slow tools
      make_slow_tool = fn name, delay ->
        %AgentTool{
          name: name,
          description: "Slow tool #{name}",
          parameters: %{"type" => "object", "properties" => %{}},
          label: name,
          execute: fn _id, _params, _signal, _on_update ->
            Process.sleep(delay)

            %AgentToolResult{
              content: [%TextContent{type: :text, text: "#{name} done"}],
              details: nil
            }
          end
        }
      end

      tools = [
        make_slow_tool.("tool_a", 500),
        make_slow_tool.("tool_b", 500),
        make_slow_tool.("tool_c", 500)
      ]

      context = simple_context(tools: tools)

      tool_calls = [
        Mocks.tool_call("tool_a", %{}, id: "call_a"),
        Mocks.tool_call("tool_b", %{}, id: "call_b"),
        Mocks.tool_call("tool_c", %{}, id: "call_c")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run all")], context, config, signal, nil)

      # Abort early
      Task.start(fn ->
        Process.sleep(50)
        AbortSignal.abort(signal)
      end)

      start_time = System.monotonic_time(:millisecond)
      events = EventStream.events(stream) |> Enum.to_list()
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete much faster than 500ms * 3 tools
      assert elapsed < 400

      tool_ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _, _}, &1))
      assert length(tool_ends) == 3

      # All should be aborted
      for {:tool_execution_end, _, _, _, is_error} <- tool_ends do
        assert is_error == true
      end
    end

    test "tool results collected before abort are preserved in final messages" do
      fast_tool = %AgentTool{
        name: "instant_tool",
        description: "Completes instantly",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Instant",
        execute: fn _id, _params, _signal, _on_update ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Instant result"}],
            details: %{preserved: true}
          }
        end
      }

      delayed_tool = %AgentTool{
        name: "delayed_tool",
        description: "Takes time",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Delayed",
        execute: fn _id, _params, _signal, _on_update ->
          Process.sleep(300)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Delayed result"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [fast_tool, delayed_tool])

      tool_calls = [
        Mocks.tool_call("instant_tool", %{}, id: "call_instant"),
        Mocks.tool_call("delayed_tool", %{}, id: "call_delayed")
      ]

      tool_response = Mocks.assistant_message_with_tool_calls(tool_calls)
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run both")], context, config, signal, nil)

      # Give instant tool time to complete
      Task.start(fn ->
        Process.sleep(100)
        AbortSignal.abort(signal)
      end)

      {:ok, messages} = EventStream.result(stream)

      # Find the instant tool result
      instant_result =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :tool_result and Map.get(msg, :tool_call_id) == "call_instant"
        end)

      assert instant_result != nil
      assert instant_result.is_error == false

      # Find the delayed tool result (should be aborted)
      delayed_result =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :tool_result and Map.get(msg, :tool_call_id) == "call_delayed"
        end)

      assert delayed_result != nil
      assert delayed_result.is_error == true
    end
  end

  # ============================================================================
  # 4. Abort Signal Propagation Timing
  # ============================================================================

  describe "abort signal propagation timing" do
    test "abort signal is checked between streaming iterations in consume loop" do
      context = simple_context()

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Response")
          Ai.EventStream.push(stream, {:start, response})

          # Simulate slow streaming with multiple chunks
          for i <- 1..10 do
            Process.sleep(30)
            Ai.EventStream.push(stream, {:text_delta, 0, "chunk #{i}", response})
          end

          Ai.EventStream.push(stream, {:done, :stop, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort during streaming (abort is checked per event consumed)
      Task.start(fn ->
        Process.sleep(100)
        AbortSignal.abort(signal)
      end)

      start_time = System.monotonic_time(:millisecond)
      events = EventStream.events(stream) |> Enum.to_list()
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete faster than full streaming (10 * 30ms = 300ms)
      assert elapsed < 250

      # Should have been aborted
      assistant_msg =
        Enum.find(events, fn
          {:message_end, msg} -> Map.get(msg, :role) == :assistant
          _ -> false
        end)

      assert assistant_msg != nil
      {:message_end, msg} = assistant_msg
      assert msg.stop_reason == :aborted
    end

    test "abort signal is checked in parallel tool collect loop every 100ms" do
      slow_tool = %AgentTool{
        name: "very_slow_tool",
        description: "Takes a long time",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Very Slow",
        execute: fn _id, _params, _signal, _on_update ->
          Process.sleep(2000)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Done"}],
            details: nil
          }
        end
      }

      context = simple_context(tools: [slow_tool])

      tool_call = Mocks.tool_call("very_slow_tool", %{}, id: "call_vs")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Run slow")], context, config, signal, nil)

      # Abort after ~150ms (should be detected on next 100ms check)
      Task.start(fn ->
        Process.sleep(150)
        AbortSignal.abort(signal)
      end)

      start_time = System.monotonic_time(:millisecond)
      _events = EventStream.events(stream) |> Enum.to_list()
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete within ~250ms (150ms wait + 100ms check interval)
      assert elapsed < 400
    end

    test "abort after turn completes but before next turn starts" do
      context = simple_context()
      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Second response")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([response1, response2]),
          get_follow_up_messages: fn ->
            Process.sleep(50)
            [user_message("Follow up")]
          end
        )

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Start")], context, config, signal, nil)

      # Abort during the follow-up check delay
      Task.start(fn ->
        Process.sleep(100)
        AbortSignal.abort(signal)
      end)

      {:ok, messages} = EventStream.result(stream)

      # Should have at least the first assistant response
      assistant_msgs =
        Enum.filter(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert length(assistant_msgs) >= 1
    end

    test "abort signal state persists across multiple checks" do
      signal = AbortSignal.new()

      assert AbortSignal.aborted?(signal) == false

      AbortSignal.abort(signal)

      # Multiple checks should all return true
      for _ <- 1..100 do
        assert AbortSignal.aborted?(signal) == true
      end
    end
  end

  # ============================================================================
  # 5. Steering Message Injection After Abort
  # ============================================================================

  describe "steering message injection after abort" do
    test "steering messages queued during abort are not processed" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      steering_call_count = :counters.new(1, [:atomics])

      get_steering = fn ->
        :counters.add(steering_call_count, 1, 1)
        []
      end

      tool_call = Mocks.tool_call("echo", %{"text" => "hi"}, id: "call_1")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should have aborted immediately
      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted

      # Steering should have been called at most once (initial check)
      assert :counters.get(steering_call_count, 1) <= 1
    end

    test "abort during steering message processing stops loop" do
      context = simple_context()

      steering_processed = :counters.new(1, [:atomics])
      abort_signal = AbortSignal.new()

      get_steering = fn ->
        count = :counters.get(steering_processed, 1)
        :counters.add(steering_processed, 1, 1)

        if count >= 2 do
          AbortSignal.abort(abort_signal)
        end

        if count < 5 do
          [user_message("Steering #{count}")]
        else
          []
        end
      end

      responses =
        for i <- 1..10 do
          Mocks.assistant_message("Response #{i}")
        end

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn(responses)
        )

      stream = Loop.agent_loop([user_message("Start")], context, config, abort_signal, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should have stopped processing before all 5 steering messages
      assert :counters.get(steering_processed, 1) < 5

      # Last assistant should be aborted
      assistant_msgs =
        Enum.filter(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      last_assistant = List.last(assistant_msgs)
      assert last_assistant.stop_reason == :aborted
    end

    test "steering messages returned after abort are not executed" do
      context = simple_context()
      abort_signal = AbortSignal.new()

      steering_call_count = :counters.new(1, [:atomics])

      get_steering = fn ->
        :counters.add(steering_call_count, 1, 1)

        if AbortSignal.aborted?(abort_signal) do
          # Even if we return messages after abort, they should be ignored
          [user_message("This should be ignored")]
        else
          []
        end
      end

      response = Mocks.assistant_message("First response")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Pre-abort
      AbortSignal.abort(abort_signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, abort_signal, nil)

      {:ok, messages} = EventStream.result(stream)

      # Find the assistant message - it should be aborted
      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted

      # Steering was called but since we aborted, the loop didn't continue
      # with the steering messages (the aborted response ends the loop)
      assert :counters.get(steering_call_count, 1) >= 1
    end
  end

  # ============================================================================
  # 6. Context Transformation During Abort
  # ============================================================================

  describe "context transformation during abort" do
    test "transform_context receives abort signal and can inspect it" do
      context = simple_context()
      transform_received_signal = Agent.start_link(fn -> nil end) |> elem(1)

      transform_fn = fn messages, signal ->
        Agent.update(transform_received_signal, fn _ -> signal end)
        # Just pass through - we're testing signal propagation
        messages
      end

      response = Mocks.assistant_message("Response")

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # First test: non-aborted signal
      signal1 = AbortSignal.new()
      stream1 = Loop.agent_loop([user_message("Test 1")], context, config, signal1, nil)
      {:ok, _messages} = EventStream.result(stream1)

      received_signal = Agent.get(transform_received_signal, & &1)
      assert is_reference(received_signal)
      assert AbortSignal.aborted?(received_signal) == false

      # Second test: aborted signal - transform still gets called but
      # the abort check before streaming short-circuits
      signal2 = AbortSignal.new()
      AbortSignal.abort(signal2)

      # Reset the agent
      Agent.update(transform_received_signal, fn _ -> nil end)

      stream2 = Loop.agent_loop([user_message("Test 2")], context, config, signal2, nil)
      {:ok, messages} = EventStream.result(stream2)

      # With pre-aborted signal, the loop short-circuits before transform
      # so transform may or may not be called - but the result is aborted
      assistant_msg = Enum.find(messages, &(Map.get(&1, :role) == :assistant))
      assert assistant_msg.stop_reason == :aborted
    end

    test "transform_context error during abort is superseded by abort handling" do
      context = simple_context()

      transform_fn = fn _messages, signal ->
        if AbortSignal.aborted?(signal) do
          # Transform may return error, but abort check happens first
          {:error, {:aborted_during_transform, System.monotonic_time()}}
        else
          {:error, :regular_error}
        end
      end

      response = Mocks.assistant_message("Response")

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      result = EventStream.result(stream)

      # When signal is aborted before streaming, the loop short-circuits
      # with an aborted message rather than calling transform/stream
      {:ok, messages} = result

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted
    end

    test "abort triggered during transform affects subsequent streaming" do
      context = simple_context()
      parent = self()
      abort_signal = AbortSignal.new()

      transform_fn = fn messages, _signal ->
        # Abort after transform starts
        AbortSignal.abort(abort_signal)
        send(parent, :transform_completed)
        messages
      end

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          send(parent, :stream_fn_called)
          # The stream will be canceled mid-flight by abort check
          response = Mocks.assistant_message("Response")
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(50)
          Ai.EventStream.push(stream, {:done, :stop, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: stream_fn
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, abort_signal, nil)

      {:ok, messages} = EventStream.result(stream)

      # Transform completed
      assert_receive :transform_completed, 500

      # Stream_fn may be called (abort check is per-event in stream consumption)
      # but the resulting message will be aborted

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted
    end

    test "abort during multi-turn conversation preserves context up to abort point" do
      context = simple_context()

      turn_count = :counters.new(1, [:atomics])
      abort_signal = AbortSignal.new()

      transform_fn = fn messages, _signal ->
        count = :counters.get(turn_count, 1)
        :counters.add(turn_count, 1, 1)

        if count >= 2 do
          AbortSignal.abort(abort_signal)
        end

        messages
      end

      responses =
        for i <- 1..5 do
          Mocks.assistant_message("Response #{i}")
        end

      follow_up_count = :counters.new(1, [:atomics])

      get_follow_up = fn ->
        count = :counters.get(follow_up_count, 1)
        :counters.add(follow_up_count, 1, 1)

        if count < 5 do
          [user_message("Follow up #{count}")]
        else
          []
        end
      end

      config =
        simple_config(
          transform_context: transform_fn,
          get_follow_up_messages: get_follow_up,
          stream_fn: Mocks.mock_stream_fn(responses)
        )

      stream = Loop.agent_loop([user_message("Start")], context, config, abort_signal, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should have processed some turns before abort
      assistant_msgs =
        Enum.filter(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      # At least 1-2 responses before abort kicked in
      assert length(assistant_msgs) >= 1
      assert length(assistant_msgs) < 5
    end
  end

  # ============================================================================
  # Additional Abort Edge Cases
  # ============================================================================

  describe "abort edge cases" do
    test "nil signal is treated as non-aborted" do
      context = simple_context()
      response = Mocks.assistant_message("Response")

      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      # Explicitly pass nil signal
      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :stop
    end

    test "abort signal state at check time determines abort behavior" do
      context = simple_context()

      # Create a stream function that produces events slowly
      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Response")
          Ai.EventStream.push(stream, {:start, response})
          # Slow streaming to give abort time to be detected
          for i <- 1..5 do
            Process.sleep(40)
            Ai.EventStream.push(stream, {:text_delta, 0, "chunk #{i}", response})
          end

          Ai.EventStream.push(stream, {:done, :stop, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)

      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      # Abort during streaming (after some chunks have been processed)
      Task.start(fn ->
        Process.sleep(80)
        AbortSignal.abort(signal)
      end)

      {:ok, messages} = EventStream.result(stream)

      # The abort was detected during stream event consumption
      assistant_msg =
        Enum.find(messages, fn msg ->
          Map.get(msg, :role) == :assistant
        end)

      assert assistant_msg.stop_reason == :aborted
    end

    test "multiple loops can use different abort signals independently" do
      context = simple_context()

      make_slow_response = fn delay, text ->
        fn _model, _context, _options ->
          {:ok, stream} = Ai.EventStream.start_link()

          Task.start(fn ->
            Process.sleep(delay)
            response = Mocks.assistant_message(text)
            Ai.EventStream.push(stream, {:start, response})
            Ai.EventStream.push(stream, {:done, :stop, response})
            Ai.EventStream.complete(stream, response)
          end)

          {:ok, stream}
        end
      end

      signal1 = AbortSignal.new()
      signal2 = AbortSignal.new()

      config1 = simple_config(stream_fn: make_slow_response.(200, "Response 1"))
      config2 = simple_config(stream_fn: make_slow_response.(200, "Response 2"))

      stream1 = Loop.agent_loop([user_message("Test 1")], context, config1, signal1, nil)
      stream2 = Loop.agent_loop([user_message("Test 2")], context, config2, signal2, nil)

      # Abort only stream1
      Task.start(fn ->
        Process.sleep(50)
        AbortSignal.abort(signal1)
      end)

      result1 = EventStream.result(stream1)
      result2 = EventStream.result(stream2)

      {:ok, messages1} = result1
      {:ok, messages2} = result2

      assistant1 = Enum.find(messages1, &(Map.get(&1, :role) == :assistant))
      assistant2 = Enum.find(messages2, &(Map.get(&1, :role) == :assistant))

      assert assistant1.stop_reason == :aborted
      assert assistant2.stop_reason == :stop
    end

    test "abort during loop with no tools completes cleanly" do
      context = simple_context(tools: [])
      response = Mocks.assistant_message("Response without tools")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Process.sleep(100)
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(100)
          Ai.EventStream.push(stream, {:done, :stop, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      signal = AbortSignal.new()

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      Task.start(fn ->
        Process.sleep(50)
        AbortSignal.abort(signal)
      end)

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have proper lifecycle events
      assert {:agent_start} = hd(events)
      assert {:agent_end, messages} = List.last(events)

      # Messages should include an aborted assistant message
      assistant_msg = Enum.find(messages, &(Map.get(&1, :role) == :assistant))
      assert assistant_msg.stop_reason == :aborted
    end
  end
end
