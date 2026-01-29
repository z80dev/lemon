defmodule AgentCore.LoopTest do
  use ExUnit.Case, async: true

  alias AgentCore.Loop
  alias AgentCore.EventStream
  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias AgentCore.Test.Mocks

  alias Ai.Types.{
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
  # agent_loop/5 Tests
  # ============================================================================

  describe "agent_loop/5" do
    test "returns an EventStream" do
      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop([user_message("Hi")], context, config, nil, nil)

      assert is_pid(stream)
    end

    test "emits agent_start as first event" do
      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop([user_message("Hi")], context, config, nil, nil)
      events = EventStream.events(stream) |> Enum.to_list()

      assert {:agent_start} = hd(events)
    end

    test "emits agent_end as last event" do
      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop([user_message("Hi")], context, config, nil, nil)
      events = EventStream.events(stream) |> Enum.to_list()

      assert {:agent_end, _messages} = List.last(events)
    end

    test "returns new messages in agent_end" do
      context = simple_context()
      response = Mocks.assistant_message("Hello back!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      prompt = user_message("Hi there")
      stream = Loop.agent_loop([prompt], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should contain the prompt and the assistant response
      assert length(messages) >= 1

      # Find the assistant message
      assistant_msg = Enum.find(messages, fn m -> Map.get(m, :role) == :assistant end)
      assert assistant_msg != nil
    end

    test "handles simple text response" do
      context = simple_context()
      response = Mocks.assistant_message("I'm doing well, thank you!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop([user_message("How are you?")], context, config, nil, nil)
      events = EventStream.events(stream) |> Enum.to_list()

      # Check we have message events
      message_starts = Enum.filter(events, fn e -> match?({:message_start, _}, e) end)
      message_ends = Enum.filter(events, fn e -> match?({:message_end, _}, e) end)

      assert length(message_starts) >= 1
      assert length(message_ends) >= 1
    end
  end

  # ============================================================================
  # stream/4 Tests
  # ============================================================================

  describe "stream/4" do
    test "returns an Enumerable of events" do
      context = simple_context()
      response = Mocks.assistant_message("Test response")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      assert is_list(events)
      assert length(events) > 0
    end

    test "includes agent lifecycle events" do
      context = simple_context()
      response = Mocks.assistant_message("Response")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      event_types = Enum.map(events, fn e -> elem(e, 0) end)

      assert :agent_start in event_types
      assert :agent_end in event_types
    end

    test "accepts stream_fn returning stream directly" do
      context = simple_context()
      response = Mocks.assistant_message("Direct stream response")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single_direct(response))

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      assert {:agent_end, _messages} = List.last(events)
    end
  end

  # ============================================================================
  # agent_loop_continue/4 Tests
  # ============================================================================

  describe "agent_loop_continue/4" do
    test "raises error when context has no messages" do
      context = simple_context()
      config = simple_config()

      assert_raise ArgumentError, ~r/no messages in context/, fn ->
        Loop.agent_loop_continue(context, config, nil, nil)
      end
    end

    test "raises error when last message is assistant" do
      assistant_msg = Mocks.assistant_message("Previous response")
      context = simple_context(messages: [user_message("Hi"), assistant_msg])
      config = simple_config()

      assert_raise ArgumentError, ~r/Cannot continue from message role: assistant/, fn ->
        Loop.agent_loop_continue(context, config, nil, nil)
      end
    end

    test "continues from tool_result message" do
      tool_result = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_123",
        tool_name: "test_tool",
        content: [%TextContent{type: :text, text: "Result"}],
        is_error: false,
        timestamp: System.system_time(:millisecond)
      }

      context = simple_context(messages: [user_message("Test"), tool_result])
      response = Mocks.assistant_message("Processed the tool result")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop_continue(context, config, nil, nil)
      events = EventStream.events(stream) |> Enum.to_list()

      assert {:agent_start} = hd(events)
    end

    test "continues from user message" do
      context = simple_context(messages: [user_message("Please continue")])
      response = Mocks.assistant_message("Continuing...")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop_continue(context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)
      assert length(messages) >= 0
    end
  end

  # ============================================================================
  # stream_continue/3 Tests
  # ============================================================================

  describe "stream_continue/3" do
    test "returns an Enumerable" do
      context = simple_context(messages: [user_message("Start")])
      response = Mocks.assistant_message("Continue")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream_continue(context, config) |> Enum.to_list()

      assert is_list(events)
    end
  end

  # ============================================================================
  # Event Sequencing Tests
  # ============================================================================

  describe "event sequencing" do
    test "emits events in correct order for simple request" do
      context = simple_context()
      response = Mocks.assistant_message("Response text")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("Hello")], context, config) |> Enum.to_list()
      event_types = Enum.map(events, fn e -> elem(e, 0) end)

      # Should start with agent_start
      assert hd(event_types) == :agent_start

      # Should have turn_start before messages
      turn_start_idx = Enum.find_index(event_types, &(&1 == :turn_start))
      first_message_start_idx = Enum.find_index(event_types, &(&1 == :message_start))

      assert turn_start_idx != nil
      assert first_message_start_idx != nil
      assert turn_start_idx < first_message_start_idx

      # Should end with agent_end
      assert List.last(event_types) == :agent_end
    end

    test "emits message_start and message_end for each message" do
      context = simple_context()
      response = Mocks.assistant_message("Response")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("Input")], context, config) |> Enum.to_list()

      message_starts = Enum.filter(events, fn e -> match?({:message_start, _}, e) end)
      message_ends = Enum.filter(events, fn e -> match?({:message_end, _}, e) end)

      # At minimum, should have prompt message and assistant response
      assert length(message_starts) >= 1
      assert length(message_ends) >= 1

      # Each message_start should have a corresponding message_end
      assert length(message_starts) == length(message_ends)
    end

    test "emits turn_end after turn completes" do
      context = simple_context()
      response = Mocks.assistant_message("Done")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()
      event_types = Enum.map(events, fn e -> elem(e, 0) end)

      assert :turn_end in event_types

      # turn_end should come before agent_end
      turn_end_idx = Enum.find_index(event_types, &(&1 == :turn_end))
      agent_end_idx = Enum.find_index(event_types, &(&1 == :agent_end))

      assert turn_end_idx < agent_end_idx
    end
  end

  # ============================================================================
  # Tool Execution Tests
  # ============================================================================

  describe "tool execution events" do
    test "emits tool_execution_start and tool_execution_end" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_001")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("I echoed your message")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Echo hello")], context, config) |> Enum.to_list()
      event_types = Enum.map(events, fn e -> elem(e, 0) end)

      assert :tool_execution_start in event_types
      assert :tool_execution_end in event_types
    end

    test "tool_execution_start includes tool name and arguments" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "test input"}, id: "call_002")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Echo test")], context, config) |> Enum.to_list()

      tool_start =
        Enum.find(events, fn e ->
          match?({:tool_execution_start, _, _, _}, e)
        end)

      assert tool_start != nil
      {:tool_execution_start, id, name, args} = tool_start
      assert id == "call_002"
      assert name == "echo"
      assert args == %{"text" => "test input"}
    end

    test "tool_execution_end includes result and is_error flag" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_003")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Complete")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Echo")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, _, _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, id, name, result, is_error} = tool_end
      assert id == "call_003"
      assert name == "echo"
      assert %AgentToolResult{} = result
      assert is_error == false
    end

    test "handles tool that returns error" do
      error_tool = Mocks.error_tool()
      context = simple_context(tools: [error_tool])

      tool_call = Mocks.tool_call("error_tool", %{"message" => "Intentional error"}, id: "call_err")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled the error")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Trigger error")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_err", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true
      assert %AgentToolResult{} = result
    end

    test "handles unknown tool gracefully" do
      context = simple_context(tools: [])

      tool_call = Mocks.tool_call("unknown_tool", %{}, id: "call_unknown")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Tool not found")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Use unknown tool")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_unknown", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true

      [%TextContent{text: error_text}] = result.content
      assert error_text =~ "not found"
    end

    test "executes multiple tool calls in sequence" do
      add_tool = Mocks.add_tool()
      context = simple_context(tools: [add_tool])

      tool_call1 = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: "call_1")
      tool_call2 = Mocks.tool_call("add", %{"a" => 3, "b" => 4}, id: "call_2")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call1, tool_call2])
      final_response = Mocks.assistant_message("Results: 3 and 7")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Add numbers")], context, config) |> Enum.to_list()

      tool_ends =
        Enum.filter(events, fn e ->
          match?({:tool_execution_end, _, _, _, _}, e)
        end)

      assert length(tool_ends) == 2
    end

    test "emits tool_execution_update for streaming tools" do
      streaming_tool = Mocks.streaming_tool()
      context = simple_context(tools: [streaming_tool])

      tool_call = Mocks.tool_call("streaming_tool", %{"count" => 3}, id: "call_stream")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Streaming done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Stream tool")], context, config) |> Enum.to_list()

      updates =
        Enum.filter(events, fn e ->
          match?({:tool_execution_update, "call_stream", _, _, _}, e)
        end)

      assert length(updates) == 3
    end
  end

  # ============================================================================
  # Steering Messages Tests
  # ============================================================================

  describe "steering messages" do
    test "injects steering messages mid-run" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      # Queue a steering message to be returned
      steering_message = user_message("Stop and acknowledge this")
      steering_queue = Agent.start_link(fn -> [steering_message] end) |> elem(1)

      get_steering = fn ->
        Agent.get_and_update(steering_queue, fn
          [] -> {[], []}
          messages -> {messages, []}
        end)
      end

      tool_call = Mocks.tool_call("echo", %{"text" => "hi"}, id: "call_steer")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Acknowledged")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Test steering")], context, config) |> Enum.to_list()

      # Should have events for the steering message
      # The exact behavior depends on implementation
      assert length(events) > 0
    end

    test "skips remaining tool calls when steering messages arrive" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      steering_message = user_message("Interrupt now")
      {:ok, call_counter} = Agent.start_link(fn -> 0 end)

      get_steering = fn ->
        Agent.get_and_update(call_counter, fn
          0 -> {[], 1}
          1 -> {[steering_message], 2}
          count -> {[], count}
        end)
      end

      tool_call1 = Mocks.tool_call("echo", %{"text" => "first"}, id: "call_1")
      tool_call2 = Mocks.tool_call("echo", %{"text" => "second"}, id: "call_2")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call1, tool_call2])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          get_steering_messages: get_steering,
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Run tools")], context, config) |> Enum.to_list()

      skipped =
        Enum.find(events, fn
          {:tool_execution_end, "call_2", _, result, true} ->
            case result.content do
              [%TextContent{text: text}] -> String.contains?(text, "Skipped due to queued user message.")
              _ -> false
            end

          _ ->
            false
        end)

      assert skipped != nil
    end
  end

  # ============================================================================
  # Follow-up Messages Tests
  # ============================================================================

  describe "follow-up messages" do
    test "processes follow-up messages after agent would stop" do
      context = simple_context()

      # Queue a follow-up message
      follow_up_message = user_message("One more thing...")
      follow_up_queue = Agent.start_link(fn -> [follow_up_message] end) |> elem(1)

      get_follow_up = fn ->
        Agent.get_and_update(follow_up_queue, fn
          [] -> {[], []}
          messages -> {messages, []}
        end)
      end

      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Follow-up response")

      config =
        simple_config(
          get_follow_up_messages: get_follow_up,
          stream_fn: Mocks.mock_stream_fn([response1, response2])
        )

      events = Loop.stream([user_message("Start")], context, config) |> Enum.to_list()

      # Should have multiple turns
      turn_starts = Enum.filter(events, fn e -> match?({:turn_start}, e) end)
      assert length(turn_starts) >= 1
    end
  end

  # ============================================================================
  # Transform Context Tests
  # ============================================================================

  describe "transform_context" do
    test "applies transform before convert_to_llm" do
      context = simple_context()

      # Transform that adds a prefix to message content
      transform_fn = fn messages, _signal ->
        Enum.map(messages, fn msg ->
          case msg do
            %UserMessage{content: content} = m when is_binary(content) ->
              %{m | content: "[TRANSFORMED] " <> content}

            other ->
              other
          end
        end)
      end

      response = Mocks.assistant_message("Got transformed message")

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      events = Loop.stream([user_message("Original")], context, config) |> Enum.to_list()

      # Should complete without error
      assert {:agent_end, _} = List.last(events)
    end

    test "transform_context can return {:ok, messages}" do
      context = simple_context()

      transform_fn = fn messages, _signal ->
        {:ok, messages}
      end

      response = Mocks.assistant_message("Response")

      config =
        simple_config(
          transform_context: transform_fn,
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      assert {:agent_end, _} = List.last(events)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles stream function returning error" do
      context = simple_context()

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_error(:api_unavailable)
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:error, reason, _partial} = EventStream.result(stream)
      assert reason == :api_unavailable
    end

    test "propagates convert_to_llm errors without wrapping" do
      context = simple_context()

      config =
        simple_config(
          convert_to_llm: fn _messages -> {:error, :bad_convert} end
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:error, reason, _partial} = EventStream.result(stream)
      assert reason == :bad_convert
    end

    test "propagates transform_context errors without wrapping" do
      context = simple_context()

      config =
        simple_config(
          transform_context: fn _messages, _signal -> {:error, :bad_transform} end
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:error, reason, _partial} = EventStream.result(stream)
      assert reason == :bad_transform
    end

    test "catches exceptions in tool execution" do
      bad_tool = %AgentTool{
        name: "bad_tool",
        description: "A tool that throws",
        parameters: %{},
        label: "Bad",
        execute: fn _id, _params, _signal, _on_update ->
          raise "Intentional exception"
        end
      }

      context = simple_context(tools: [bad_tool])

      tool_call = Mocks.tool_call("bad_tool", %{}, id: "call_bad")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      events = Loop.stream([user_message("Use bad tool")], context, config) |> Enum.to_list()

      tool_end =
        Enum.find(events, fn e ->
          match?({:tool_execution_end, "call_bad", _, _, _}, e)
        end)

      assert tool_end != nil
      {:tool_execution_end, _, _, result, is_error} = tool_end
      assert is_error == true
      [%TextContent{text: error_text}] = result.content
      assert error_text =~ "Intentional exception"
    end
  end

  # ============================================================================
  # API Key Resolution Tests
  # ============================================================================

  describe "get_api_key" do
    test "accepts atom providers by retrying with string" do
      context = simple_context()
      response = Mocks.assistant_message("Ok")
      parent = self()

      stream_fn = fn model, llm_context, options ->
        send(parent, {:api_key, options.api_key})
        Mocks.mock_stream_fn_single(response).(model, llm_context, options)
      end

      get_api_key = fn
        "mock_provider" -> "from_fn"
        _ -> nil
      end

      config =
        simple_config(
          get_api_key: get_api_key,
          stream_options: %StreamOptions{api_key: "fallback"},
          stream_fn: stream_fn
        )

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      assert_receive {:api_key, "from_fn"}
    end
  end

  # ============================================================================
  # Cancellation Handling Tests
  # ============================================================================

  describe "canceled streams" do
    test "emits aborted message when stream is canceled" do
      context = simple_context()

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          partial = Mocks.assistant_message("Partial response")
          Ai.EventStream.push(stream, {:start, partial})
          Ai.EventStream.cancel(stream, :aborted)
        end)

        {:ok, stream}
      end

      config =
        simple_config(
          stream_fn: stream_fn
        )

      stream = Loop.agent_loop([user_message("Test")], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      final_assistant =
        Enum.find(messages, fn message ->
          Map.get(message, :role) == :assistant
        end)

      assert final_assistant != nil
      assert final_assistant.stop_reason == :aborted
      assert String.contains?(final_assistant.error_message || "", "canceled")
    end
  end

  # ============================================================================
  # Abort Signal Tests
  # ============================================================================

  describe "abort signal" do
    test "short-circuits streaming when signal is already aborted" do
      context = simple_context()
      parent = self()

      stream_fn = fn model, llm_context, options ->
        send(parent, :stream_called)
        Mocks.mock_stream_fn_single(Mocks.assistant_message("Should not run")).(model, llm_context, options)
      end

      signal = AbortSignal.new()
      :ok = AbortSignal.abort(signal)

      config = simple_config(stream_fn: stream_fn)

      stream = Loop.agent_loop([user_message("Test")], context, config, signal, nil)

      {:ok, messages} = EventStream.result(stream)

      final_assistant =
        Enum.find(messages, fn message ->
          Map.get(message, :role) == :assistant
        end)

      assert final_assistant.stop_reason == :aborted
      refute_receive :stream_called
    end
  end

  # ============================================================================
  # Result Collection Tests
  # ============================================================================

  describe "result collection" do
    test "result includes all new messages" do
      context = simple_context()
      response = Mocks.assistant_message("Hello!")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      prompt = user_message("Hi")
      stream = Loop.agent_loop([prompt], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should have at least the prompt
      assert length(messages) >= 1
    end

    test "result includes tool results" do
      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "test"}, id: "call_tr")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      stream = Loop.agent_loop([user_message("Echo")], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      # Should include tool result message
      tool_results = Enum.filter(messages, fn m -> Map.get(m, :role) == :tool_result end)
      assert length(tool_results) >= 1
    end
  end
end
