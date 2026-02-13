defmodule CodingAgent.AgentLoopComprehensiveTest do
  @moduledoc """
  Comprehensive tests for the CodingAgent agent loop functionality.

  These tests verify the complete agent loop behavior including:
  - Full conversation cycles with tool use
  - Multi-turn conversations
  - Error recovery flows
  - Streaming and backpressure scenarios
  - Concurrent prompts handling
  - Tool execution within loop
  - Loop interruption and resumption
  - Context window management

  Tests use mocked stream functions to avoid real API calls.
  """

  use ExUnit.Case, async: true

  alias AgentCore.Test.Mocks
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.{AssistantMessage, TextContent, ToolCall}
  alias CodingAgent.Session
  alias CodingAgent.SettingsManager

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp default_settings do
    %SettingsManager{
      default_thinking_level: :off,
      compaction_enabled: false,
      reserve_tokens: 16384,
      extension_paths: [],
      providers: %{}
    }
  end

  defp start_session(opts) do
    tmp_dir = System.tmp_dir!()
    cwd = Keyword.get(opts, :cwd, tmp_dir)

    base_opts = [
      cwd: cwd,
      model: Keyword.get(opts, :model, Mocks.mock_model()),
      settings_manager: Keyword.get(opts, :settings_manager, default_settings()),
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful assistant."),
      tools: Keyword.get(opts, :tools, []),
      stream_fn: Keyword.get(opts, :stream_fn)
    ]

    merged_opts =
      Keyword.merge(
        base_opts,
        Keyword.drop(opts, [:cwd, :model, :settings_manager, :system_prompt, :tools, :stream_fn])
      )

    {:ok, session} = Session.start_link(merged_opts)
    session
  end

  defp subscribe_and_collect(session, timeout \\ 5000) do
    _unsub = Session.subscribe(session)
    collect_events([], timeout)
  end

  defp collect_events(events, timeout, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + timeout
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0 do
      Enum.reverse(events ++ [{:timeout, timeout}])
    else
      receive do
        {:session_event, _session_id, {:agent_end, _messages}} ->
          Enum.reverse(events ++ [{:agent_end, []}])

        {:session_event, _session_id, {:error, reason, _partial}} ->
          Enum.reverse(events ++ [{:error, reason}])

        {:session_event, _session_id, {:canceled, reason}} ->
          Enum.reverse(events ++ [{:canceled, reason}])

        {:session_event, _session_id,
         {:turn_end, %AssistantMessage{stop_reason: :aborted} = message, messages}} ->
          Enum.reverse(events ++ [{:turn_end, message, messages}])

        {:session_event, _session_id, event} ->
          collect_events(events ++ [event], timeout, deadline)
      after
        remaining ->
          Enum.reverse(events ++ [{:timeout, timeout}])
      end
    end
  end

  defp wait_for_idle(session, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_idle(session, deadline)
  end

  defp do_wait_for_idle(session, deadline) do
    cond do
      Session.get_state(session).is_streaming == false ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(50)
        do_wait_for_idle(session, deadline)
    end
  end

  defp delayed_stream_fn(response, delay_ms) do
    fn _model, _context, _options ->
      {:ok, stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Process.sleep(delay_ms)
        Ai.EventStream.push(stream, {:start, response})
        Ai.EventStream.push(stream, {:done, response.stop_reason, response})
        Ai.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp multi_response_stream_fn(responses) do
    {:ok, agent} = Elixir.Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      case Elixir.Agent.get_and_update(agent, fn
             [] -> {nil, []}
             [head | tail] -> {head, tail}
           end) do
        nil ->
          {:ok, stream} = Ai.EventStream.start_link()
          empty_msg = Mocks.assistant_message("", stop_reason: :stop)

          Task.start(fn ->
            Ai.EventStream.complete(stream, empty_msg)
          end)

          {:ok, stream}

        response ->
          {:ok, stream} = Ai.EventStream.start_link()

          Task.start(fn ->
            Ai.EventStream.push(stream, {:start, response})

            Enum.with_index(response.content)
            |> Enum.each(fn {content, idx} ->
              case content do
                %TextContent{text: text} ->
                  Ai.EventStream.push(stream, {:text_start, idx, response})
                  Ai.EventStream.push(stream, {:text_delta, idx, text, response})
                  Ai.EventStream.push(stream, {:text_end, idx, response})

                %ToolCall{} = tool_call ->
                  Ai.EventStream.push(stream, {:tool_call_start, idx, tool_call, response})
                  Ai.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})

                _ ->
                  :ok
              end
            end)

            Ai.EventStream.push(stream, {:done, response.stop_reason, response})
            Ai.EventStream.complete(stream, response)
          end)

          {:ok, stream}
      end
    end
  end

  # ============================================================================
  # Full Conversation Cycles with Tool Use
  # ============================================================================

  describe "full conversation cycles with tool use" do
    test "completes a simple prompt-response cycle" do
      response = Mocks.assistant_message("Hello! How can I help you today?")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, "Hello")
      events = subscribe_and_collect(session, 10_000)

      assert Enum.any?(events, &match?({:agent_start}, &1))
      assert Enum.any?(events, &match?({:turn_start}, &1))
      assert Enum.any?(events, &match?({:message_end, %AssistantMessage{}}, &1))
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "executes a single tool call and returns final response" do
      tool_call = Mocks.tool_call("echo", %{"text" => "test input"}, id: "call_1")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("The echo tool returned: Echo: test input")

      session =
        start_session(
          tools: [Mocks.echo_tool()],
          stream_fn: multi_response_stream_fn([tool_response, final_response])
        )

      :ok = Session.prompt(session, "Echo the text 'test input'")
      events = subscribe_and_collect(session)

      # Should have tool execution events
      assert Enum.any?(events, fn
               {:tool_execution_start, "call_1", "echo", _args} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:tool_execution_end, "call_1", "echo", _result, _is_error} -> true
               _ -> false
             end)

      # Should have final assistant message
      message_ends = Enum.filter(events, &match?({:message_end, %AssistantMessage{}}, &1))
      assert length(message_ends) >= 2
    end

    test "executes multiple tool calls in sequence" do
      tool_call1 = Mocks.tool_call("add", %{"a" => 5, "b" => 3}, id: "call_add_1")
      tool_call2 = Mocks.tool_call("echo", %{"text" => "result"}, id: "call_echo_1")

      response1 = Mocks.assistant_message_with_tool_calls([tool_call1])
      response2 = Mocks.assistant_message_with_tool_calls([tool_call2])
      final_response = Mocks.assistant_message("Done with calculations and echo")

      session =
        start_session(
          tools: [Mocks.add_tool(), Mocks.echo_tool()],
          stream_fn: multi_response_stream_fn([response1, response2, final_response])
        )

      :ok = Session.prompt(session, "Add 5 and 3, then echo 'result'")
      events = subscribe_and_collect(session)

      # Both tools should have been called
      tool_starts = Enum.filter(events, &match?({:tool_execution_start, _, _, _}, &1))
      assert length(tool_starts) >= 2
    end

    test "handles parallel tool calls" do
      tool_call1 = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: "call_p1")
      tool_call2 = Mocks.tool_call("add", %{"a" => 3, "b" => 4}, id: "call_p2")

      response_with_parallel = Mocks.assistant_message_with_tool_calls([tool_call1, tool_call2])
      final_response = Mocks.assistant_message("Results: 3 and 7")

      session =
        start_session(
          tools: [Mocks.add_tool()],
          stream_fn: multi_response_stream_fn([response_with_parallel, final_response])
        )

      :ok = Session.prompt(session, "Calculate 1+2 and 3+4 at the same time")
      events = subscribe_and_collect(session)

      # Both tool calls should be executed
      tool_ends = Enum.filter(events, &match?({:tool_execution_end, _, "add", _, _}, &1))
      assert length(tool_ends) == 2
    end

    test "handles tool that returns error" do
      tool_call =
        Mocks.tool_call("error_tool", %{"message" => "Something went wrong"}, id: "call_err")

      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("The tool encountered an error.")

      session =
        start_session(
          tools: [Mocks.error_tool()],
          stream_fn: multi_response_stream_fn([tool_response, final_response])
        )

      :ok = Session.prompt(session, "Trigger an error")
      events = subscribe_and_collect(session)

      # Tool should end with error result
      tool_end =
        Enum.find(events, fn
          {:tool_execution_end, "call_err", "error_tool", _result, _is_error} -> true
          _ -> false
        end)

      assert tool_end != nil
    end

    test "handles missing tool gracefully" do
      tool_call = Mocks.tool_call("nonexistent_tool", %{}, id: "call_missing")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Tool not found, proceeding without it.")

      session =
        start_session(
          tools: [],
          stream_fn: multi_response_stream_fn([tool_response, final_response])
        )

      unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "Use nonexistent tool")
      events = collect_events([], 5000)
      unsub.()

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # Multi-turn Conversations
  # ============================================================================

  describe "multi-turn conversations" do
    test "maintains context across turns" do
      response1 = Mocks.assistant_message("I'll remember that your name is Alice.")
      response2 = Mocks.assistant_message("Your name is Alice!")

      session = start_session(stream_fn: multi_response_stream_fn([response1, response2]))

      :ok = Session.prompt(session, "My name is Alice")
      _events1 = subscribe_and_collect(session)

      :ok = Session.prompt(session, "What is my name?")
      _events2 = subscribe_and_collect(session)

      # Get state and verify messages accumulated
      state = Session.get_state(session)
      messages = state.session_manager.entries

      # Should have accumulated messages from both turns
      assert length(messages) >= 2
    end

    test "preserves tool results in context" do
      tool_call = Mocks.tool_call("add", %{"a" => 10, "b" => 20}, id: "call_add")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("The sum is 30.")
      response3 = Mocks.assistant_message("Yes, I calculated 10 + 20 = 30 earlier.")

      session =
        start_session(
          tools: [Mocks.add_tool()],
          stream_fn: multi_response_stream_fn([response1, response2, response3])
        )

      :ok = Session.prompt(session, "Add 10 and 20")
      _events1 = subscribe_and_collect(session)

      :ok = Session.prompt(session, "What was the result?")
      _events2 = subscribe_and_collect(session)

      # Verify messages accumulated properly
      messages = Session.get_messages(session)
      assert length(messages) >= 4
    end

    test "handles rapid consecutive prompts" do
      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Second response")

      session = start_session(stream_fn: multi_response_stream_fn([response1, response2]))

      :ok = Session.prompt(session, "First question")
      _events1 = subscribe_and_collect(session)

      # Immediately send another prompt
      :ok = Session.prompt(session, "Second question")
      events2 = subscribe_and_collect(session)

      assert Enum.any?(events2, &match?({:agent_end, _}, &1))
    end

    test "correctly handles 5 turn conversation" do
      responses =
        for i <- 1..5 do
          Mocks.assistant_message("Response #{i}")
        end

      session = start_session(stream_fn: multi_response_stream_fn(responses))

      for i <- 1..5 do
        :ok = Session.prompt(session, "Turn #{i}")
        events = subscribe_and_collect(session, 10_000)
        assert Enum.any?(events, &match?({:agent_end, _}, &1))
        assert :ok = wait_for_idle(session, 5_000)
      end

      messages = Session.get_messages(session)
      # 5 user + 5 assistant = 10 messages
      assert length(messages) >= 10
    end
  end

  # ============================================================================
  # Error Recovery Flows
  # ============================================================================

  describe "error recovery flows" do
    test "continues after tool execution error" do
      tool_call = Mocks.tool_call("error_tool", %{"message" => "Error occurred"}, id: "call_e1")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("I encountered an error but will continue.")

      session =
        start_session(
          tools: [Mocks.error_tool()],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Trigger error")
      events = subscribe_and_collect(session)

      # Should complete despite tool error
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "handles stream function returning error" do
      error_stream_fn = fn _model, _context, _options ->
        {:error, :api_unavailable}
      end

      session = start_session(stream_fn: error_stream_fn)

      :ok = Session.prompt(session, "Hello")
      events = subscribe_and_collect(session)

      # Should have error event
      assert Enum.any?(events, fn
               {:error, _} -> true
               _ -> false
             end)
    end

    test "recovers from tool crash" do
      crashing_tool = %AgentTool{
        name: "crasher",
        description: "A tool that crashes",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Crasher",
        execute: fn _id, _args, _signal, _on_update ->
          raise "Intentional crash"
        end
      }

      tool_call = Mocks.tool_call("crasher", %{}, id: "call_crash")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Tool crashed but I recovered.")

      session =
        start_session(
          tools: [crashing_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Crash the tool")
      events = subscribe_and_collect(session)

      # Should still complete
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "handles empty response gracefully" do
      empty_response = Mocks.assistant_message("")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(empty_response))

      :ok = Session.prompt(session, "Hello")
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "handles malformed tool arguments" do
      tool_call = Mocks.tool_call("add", %{"invalid" => "args"}, id: "call_bad_args")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("I provided bad arguments.")

      session =
        start_session(
          tools: [Mocks.add_tool()],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Use tool with bad args")
      events = subscribe_and_collect(session)

      # Should complete (tool may error, but loop continues)
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # Streaming and Backpressure Scenarios
  # ============================================================================

  describe "streaming and backpressure scenarios" do
    test "handles slow stream function" do
      response = Mocks.assistant_message("Slow response")
      slow_stream_fn = delayed_stream_fn(response, 100)

      session = start_session(stream_fn: slow_stream_fn)

      :ok = Session.prompt(session, "Hello")
      events = subscribe_and_collect(session, 10_000)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "handles many message updates" do
      long_text = String.duplicate("word ", 100)
      response = Mocks.assistant_message(long_text)
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, "Give me a long response")
      events = subscribe_and_collect(session)

      # Should have message update events
      updates = Enum.filter(events, &match?({:message_update, _, _}, &1))
      assert length(updates) >= 1
    end

    test "multiple subscribers receive events" do
      response = Mocks.assistant_message("Multi-subscriber test")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      # Subscribe from main process
      _unsub1 = Session.subscribe(session)

      # Subscribe from another process
      parent = self()

      spawn(fn ->
        _unsub2 = Session.subscribe(session)

        receive do
          {:session_event, _, event} -> send(parent, {:other_sub, event})
        after
          5000 -> send(parent, :timeout)
        end
      end)

      # Let subscriber connect
      Process.sleep(50)
      :ok = Session.prompt(session, "Hello")

      # Main process collects events
      events = collect_events([], 5000)
      assert Enum.any?(events, &match?({:agent_end, _}, &1))

      # Other subscriber should also receive
      assert_receive {:other_sub, _event}, 5000
    end

    test "unsubscribe stops event delivery" do
      response = Mocks.assistant_message("Unsubscribe test")
      slow_stream_fn = delayed_stream_fn(response, 200)

      session = start_session(stream_fn: slow_stream_fn)

      unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "Hello")

      # Unsubscribe before events arrive
      unsub.()

      # Should not receive agent_end
      receive do
        {:session_event, _, {:agent_end, _}} ->
          flunk("Should not receive events after unsubscribe")
      after
        500 -> :ok
      end
    end

    test "stream mode subscription with backpressure" do
      response = Mocks.assistant_message("Stream mode test")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      {:ok, stream} = Session.subscribe(session, mode: :stream, max_queue: 100)

      :ok = Session.prompt(session, "Hello")

      # Collect events from stream
      events =
        stream
        |> AgentCore.EventStream.events()
        |> Enum.take_while(fn
          {:session_event, _, {:agent_end, _}} -> false
          _ -> true
        end)
        |> Enum.to_list()

      assert length(events) >= 1
    end
  end

  # ============================================================================
  # Concurrent Prompts Handling
  # ============================================================================

  describe "concurrent prompts handling" do
    test "rejects prompt when already streaming" do
      response = Mocks.assistant_message("Still processing")
      slow_stream_fn = delayed_stream_fn(response, 500)

      session = start_session(stream_fn: slow_stream_fn)

      _unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "First prompt")

      # Try to send another prompt immediately
      result = Session.prompt(session, "Second prompt")
      assert result == {:error, :already_streaming}
    end

    test "steering queue injects messages during tool execution" do
      slow_tool = %AgentTool{
        name: "slow_tool",
        description: "A slow tool",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Slow Tool",
        execute: fn _id, _args, _signal, _on_update ->
          Process.sleep(200)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Slow result"}],
            details: nil
          }
        end
      }

      tool_call = Mocks.tool_call("slow_tool", %{}, id: "call_slow")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Received steering message and tool result.")

      session =
        start_session(
          tools: [slow_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      _unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "Run slow tool")

      # Wait a bit then send steering message
      Process.sleep(50)
      :ok = Session.steer(session, "Hurry up!")

      events = collect_events([], 5000)
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "follow-up queue processed after completion" do
      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Follow-up response")

      session = start_session(stream_fn: multi_response_stream_fn([response1, response2]))

      _unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "First message")

      # Queue a follow-up
      :ok = Session.follow_up(session, "Follow up message")

      events = collect_events([], 5000)

      # Should have processed the follow-up
      message_ends = Enum.filter(events, &match?({:message_end, %AssistantMessage{}}, &1))
      assert length(message_ends) >= 2
    end

    test "multiple steering messages queued" do
      response = Mocks.assistant_message("Processed all steering messages")
      slow_stream_fn = delayed_stream_fn(response, 300)

      session = start_session(stream_fn: slow_stream_fn)

      _unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "Start")

      # Queue multiple steering messages
      :ok = Session.steer(session, "Steer 1")
      :ok = Session.steer(session, "Steer 2")
      :ok = Session.steer(session, "Steer 3")

      events = collect_events([], 5000)
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # Tool Execution Within Loop
  # ============================================================================

  describe "tool execution within loop" do
    test "tool receives abort signal" do
      parent = self()

      signal_tool = %AgentTool{
        name: "signal_checker",
        description: "Checks abort signal",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Signal Checker",
        execute: fn _id, _args, signal, _on_update ->
          send(parent, {:signal_received, signal})

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Signal checked"}],
            details: nil
          }
        end
      }

      tool_call = Mocks.tool_call("signal_checker", %{}, id: "call_sig")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Done")

      session =
        start_session(
          tools: [signal_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Check signal")
      _events = subscribe_and_collect(session)

      assert_receive {:signal_received, signal}, 5000
      assert is_reference(signal)
    end

    test "tool can emit progress updates" do
      progress_tool = %AgentTool{
        name: "progress_tool",
        description: "Emits progress updates",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Progress Tool",
        execute: fn _id, _args, _signal, on_update ->
          for i <- 1..3 do
            on_update.(%AgentToolResult{
              content: [%TextContent{type: :text, text: "Progress: #{i}/3"}],
              details: %{step: i}
            })

            Process.sleep(10)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Complete"}],
            details: nil
          }
        end
      }

      tool_call = Mocks.tool_call("progress_tool", %{}, id: "call_prog")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Progress complete")

      session =
        start_session(
          tools: [progress_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Show progress")
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "tool with complex return value" do
      complex_tool = %AgentTool{
        name: "complex_tool",
        description: "Returns complex data",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Complex Tool",
        execute: fn _id, _args, _signal, _on_update ->
          %AgentToolResult{
            content: [
              %TextContent{type: :text, text: "Part 1"},
              %TextContent{type: :text, text: "Part 2"}
            ],
            details: %{
              nested: %{data: [1, 2, 3]},
              timestamp: System.system_time(:millisecond)
            }
          }
        end
      }

      tool_call = Mocks.tool_call("complex_tool", %{}, id: "call_complex")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Complex data processed")

      session =
        start_session(
          tools: [complex_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Get complex data")
      events = subscribe_and_collect(session)

      tool_end =
        Enum.find(events, fn
          {:tool_execution_end, "call_complex", "complex_tool", _result, _is_error} -> true
          _ -> false
        end)

      assert tool_end != nil
    end

    test "long-running tool completes successfully" do
      long_tool = %AgentTool{
        name: "long_tool",
        description: "Takes a while",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Long Tool",
        execute: fn _id, _args, _signal, _on_update ->
          Process.sleep(300)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Finally done"}],
            details: nil
          }
        end
      }

      tool_call = Mocks.tool_call("long_tool", %{}, id: "call_long")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Long operation complete")

      session =
        start_session(
          tools: [long_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Run long operation")
      events = subscribe_and_collect(session, 10_000)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # Loop Interruption and Resumption
  # ============================================================================

  describe "loop interruption and resumption" do
    test "abort stops the loop" do
      slow_response = Mocks.assistant_message("This takes a while")
      slow_stream_fn = delayed_stream_fn(slow_response, 1000)

      session = start_session(stream_fn: slow_stream_fn)

      _unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "Hello")

      # Wait a bit then abort
      Process.sleep(100)
      :ok = Session.abort(session)

      # Collect events - should complete relatively quickly
      events = collect_events([], 2000)

      aborted_terminal? =
        Enum.any?(events, fn
          {:canceled, :assistant_aborted} -> true
          {:turn_end, %AssistantMessage{stop_reason: :aborted}, _} -> true
          _ -> false
        end)

      aborted_message_seen? =
        Enum.any?(events, fn
          {:message_start, %AssistantMessage{stop_reason: :aborted}} -> true
          {:message_end, %AssistantMessage{stop_reason: :aborted}} -> true
          _ -> false
        end)

      agent_ended? = Enum.any?(events, &match?({:agent_end, _}, &1))

      assert aborted_terminal? or aborted_message_seen?

      if agent_ended? do
        assert aborted_message_seen?
      end
    end

    test "abort during tool execution" do
      slow_tool = %AgentTool{
        name: "very_slow",
        description: "Very slow tool",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "Very Slow",
        execute: fn _id, _args, signal, _on_update ->
          # Check abort periodically
          for _ <- 1..50 do
            if AgentCore.AbortSignal.aborted?(signal) do
              throw(:aborted)
            end

            Process.sleep(20)
          end

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Never reached"}],
            details: nil
          }
        end
      }

      tool_call = Mocks.tool_call("very_slow", %{}, id: "call_vs")
      response = Mocks.assistant_message_with_tool_calls([tool_call])

      session =
        start_session(
          tools: [slow_tool],
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      _unsub = Session.subscribe(session)
      :ok = Session.prompt(session, "Run very slow tool")

      # Abort during tool execution
      Process.sleep(100)
      :ok = Session.abort(session)

      events = collect_events([], 3000)

      aborted_terminal? =
        Enum.any?(events, fn
          {:canceled, :assistant_aborted} -> true
          {:turn_end, %AssistantMessage{stop_reason: :aborted}, _} -> true
          _ -> false
        end)

      aborted_message_seen? =
        Enum.any?(events, fn
          {:message_start, %AssistantMessage{stop_reason: :aborted}} -> true
          {:message_end, %AssistantMessage{stop_reason: :aborted}} -> true
          _ -> false
        end)

      agent_ended? = Enum.any?(events, &match?({:agent_end, _}, &1))

      tool_abort_seen? =
        Enum.any?(events, fn
          {:tool_execution_end, _tool_call_id, "very_slow", %AgentToolResult{content: content},
           true} ->
            Enum.any?(content, fn
              %TextContent{text: text} when is_binary(text) ->
                String.contains?(text, "aborted")

              _ ->
                false
            end)

          _ ->
            false
        end)

      unless aborted_terminal? or aborted_message_seen? or tool_abort_seen? do
        IO.inspect(events, label: "failed events during abort tool test")
      end

      assert aborted_terminal? or aborted_message_seen? or tool_abort_seen?

      if agent_ended? do
        assert aborted_terminal? or aborted_message_seen? or tool_abort_seen?
      end
    end

    test "reset clears state and allows new prompts" do
      response1 = Mocks.assistant_message("First session response")
      response2 = Mocks.assistant_message("After reset response")

      session = start_session(stream_fn: multi_response_stream_fn([response1, response2]))

      :ok = Session.prompt(session, "First prompt")
      _events1 = subscribe_and_collect(session)

      # Reset the session
      :ok = Session.reset(session)

      # Should be able to prompt again
      :ok = Session.prompt(session, "After reset")
      events2 = subscribe_and_collect(session)

      assert Enum.any?(events2, &match?({:agent_end, _}, &1))

      # Messages should be fresh
      state = Session.get_state(session)
      assert state.turn_index == 1
    end

    test "session remains functional after error" do
      recovery_response = Mocks.assistant_message("Recovered")

      # Create session that will error first, then work
      {:ok, attempt_agent} = Elixir.Agent.start_link(fn -> 0 end)

      dynamic_stream_fn = fn model, context, options ->
        attempt = Elixir.Agent.get_and_update(attempt_agent, fn n -> {n, n + 1} end)

        if attempt == 0 do
          {:error, :temporary_error}
        else
          Mocks.mock_stream_fn_single(recovery_response).(model, context, options)
        end
      end

      session = start_session(stream_fn: dynamic_stream_fn)

      # First prompt should error
      :ok = Session.prompt(session, "Will error")
      events1 = subscribe_and_collect(session)
      assert Enum.any?(events1, &match?({:error, _}, &1))

      # Second prompt should work
      :ok = Session.prompt(session, "Should work now")
      events2 = subscribe_and_collect(session)
      assert Enum.any?(events2, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # Context Window Management
  # ============================================================================

  describe "context window management" do
    test "accumulates messages correctly across turns" do
      responses =
        for i <- 1..3 do
          Mocks.assistant_message("Response #{i}")
        end

      session = start_session(stream_fn: multi_response_stream_fn(responses))

      for i <- 1..3 do
        :ok = Session.prompt(session, "Prompt #{i}")
        events = subscribe_and_collect(session, 10_000)
        assert Enum.any?(events, &match?({:agent_end, _}, &1))
        assert :ok = wait_for_idle(session, 5_000)
      end

      messages = Session.get_messages(session)

      # Should have 3 user + 3 assistant messages
      user_messages = Enum.filter(messages, &match?(%Ai.Types.UserMessage{}, &1))
      assistant_messages = Enum.filter(messages, &match?(%AssistantMessage{}, &1))

      assert length(user_messages) == 3
      assert length(assistant_messages) == 3
    end

    test "tool result messages are included in context" do
      tool_call = Mocks.tool_call("echo", %{"text" => "context test"}, id: "call_ctx")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Echo completed")

      session =
        start_session(
          tools: [Mocks.echo_tool()],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Echo something")
      _events = subscribe_and_collect(session)

      messages = Session.get_messages(session)

      tool_results = Enum.filter(messages, &match?(%Ai.Types.ToolResultMessage{}, &1))
      assert length(tool_results) == 1
    end

    test "get_stats returns accurate statistics" do
      tool_call = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: "call_stat")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Sum is 3")

      session =
        start_session(
          tools: [Mocks.add_tool()],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Add numbers")
      _events = subscribe_and_collect(session)

      stats = Session.get_stats(session)

      assert stats.turn_count >= 1
      # user + assistant + tool_result + assistant
      assert stats.message_count >= 3
      assert stats.is_streaming == false
    end

    test "health_check returns session status" do
      response = Mocks.assistant_message("Healthy")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, "Check health")
      _events = subscribe_and_collect(session)

      health = Session.health_check(session)

      assert health.status == :healthy
      assert health.agent_alive == true
      assert health.is_streaming == false
      assert is_integer(health.uptime_ms)
    end

    test "diagnostics returns detailed information" do
      response = Mocks.assistant_message("For diagnostics")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, "Test diagnostics")
      _events = subscribe_and_collect(session)

      diag = Session.diagnostics(session)

      assert is_map(diag)
      assert Map.has_key?(diag, :message_count)
      assert Map.has_key?(diag, :tool_call_count)
      assert Map.has_key?(diag, :error_rate)
      assert Map.has_key?(diag, :model)
    end

    test "messages with images are handled correctly" do
      response = Mocks.assistant_message("I see the image")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      image_content = %{data: "base64data==", mime_type: "image/png"}
      :ok = Session.prompt(session, "What's in this image?", images: [image_content])

      events = subscribe_and_collect(session)
      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end

  # ============================================================================
  # Session State Management
  # ============================================================================

  describe "session state management" do
    test "switch_model updates the model" do
      response = Mocks.assistant_message("Using new model")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      new_model = Mocks.mock_model(id: "new-model-v2")
      :ok = Session.switch_model(session, new_model)

      state = Session.get_state(session)
      assert state.model.id == "new-model-v2"
    end

    test "set_thinking_level updates thinking" do
      response = Mocks.assistant_message("Thinking enabled")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.set_thinking_level(session, :high)

      state = Session.get_state(session)
      assert state.thinking_level == :high
    end

    test "save and load session preserves messages" do
      tmp_dir = System.tmp_dir!()

      session_file =
        Path.join(tmp_dir, "test_session_#{System.unique_integer([:positive])}.jsonl")

      response = Mocks.assistant_message("Session to save")

      session1 =
        start_session(
          cwd: tmp_dir,
          session_file: session_file,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      :ok = Session.prompt(session1, "Save this")
      _events = subscribe_and_collect(session1)
      :ok = Session.save(session1)

      # Verify file exists
      assert File.exists?(session_file)

      # Stop the session
      GenServer.stop(session1)

      # Load the session
      response2 = Mocks.assistant_message("Loaded session response")

      session2 =
        start_session(
          cwd: tmp_dir,
          session_file: session_file,
          stream_fn: Mocks.mock_stream_fn_single(response2)
        )

      messages = Session.get_messages(session2)
      assert length(messages) >= 2

      # Cleanup
      File.rm(session_file)
    end

    test "extension status report is available" do
      response = Mocks.assistant_message("Extension check")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      report = Session.get_extension_status_report(session)

      assert is_map(report)
      assert Map.has_key?(report, :total_loaded)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "empty prompt is handled" do
      response = Mocks.assistant_message("You sent an empty message")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, "")
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "very long prompt is handled" do
      long_prompt = String.duplicate("word ", 1000)
      response = Mocks.assistant_message("Processed long message")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, long_prompt)
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "unicode content is handled correctly" do
      response = Mocks.assistant_message("Emoji response: \\u{1F600}")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Session.prompt(session, "Hello \\u{1F44B}")
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "newlines in prompt preserved" do
      response = Mocks.assistant_message("Got multiline")
      session = start_session(stream_fn: Mocks.mock_stream_fn_single(response))

      multiline = """
      Line 1
      Line 2
      Line 3
      """

      :ok = Session.prompt(session, multiline)
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))

      messages = Session.get_messages(session)
      user_msg = Enum.find(messages, &match?(%Ai.Types.UserMessage{}, &1))
      assert String.contains?(user_msg.content, "Line 1")
    end

    test "special characters in tool arguments" do
      tool_call =
        Mocks.tool_call("echo", %{"text" => "Hello \"world\" & <test>"}, id: "call_special")

      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Echoed special chars")

      session =
        start_session(
          tools: [Mocks.echo_tool()],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Echo special characters")
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "null values in tool arguments" do
      null_tool = %AgentTool{
        name: "null_handler",
        description: "Handles null values",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "optional" => %{"type" => "string"}
          }
        },
        label: "Null Handler",
        execute: fn _id, args, _signal, _on_update ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Got: #{inspect(args)}"}],
            details: nil
          }
        end
      }

      tool_call = Mocks.tool_call("null_handler", %{"optional" => nil}, id: "call_null")
      response1 = Mocks.assistant_message_with_tool_calls([tool_call])
      response2 = Mocks.assistant_message("Handled null")

      session =
        start_session(
          tools: [null_tool],
          stream_fn: multi_response_stream_fn([response1, response2])
        )

      :ok = Session.prompt(session, "Handle null")
      events = subscribe_and_collect(session)

      assert Enum.any?(events, &match?({:agent_end, _}, &1))
    end
  end
end
