defmodule AgentCore.TelemetryTest do
  # Telemetry handlers are global and will observe events emitted by other tests.
  # Keep this test case synchronous to avoid cross-test contamination.
  use ExUnit.Case, async: false

  alias AgentCore.Loop
  alias AgentCore.Test.Mocks
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool}
  alias Ai.Types.StreamOptions

  # ============================================================================
  # Setup and Helpers
  # ============================================================================

  setup do
    # Generate a unique handler ID for this test
    handler_id = :erlang.unique_integer()

    # Start an agent to collect telemetry events
    {:ok, collector} = Agent.start_link(fn -> [] end)

    %{handler_id: handler_id, collector: collector}
  end

  defp attach_telemetry(event_names, handler_id, collector) do
    :telemetry.attach_many(
      "test-handler-#{handler_id}",
      event_names,
      fn event_name, measurements, metadata, _config ->
        Agent.update(collector, fn events ->
          [{event_name, measurements, metadata} | events]
        end)
      end,
      nil
    )
  end

  defp detach_telemetry(handler_id) do
    :telemetry.detach("test-handler-#{handler_id}")
  end

  defp get_events(collector) do
    Agent.get(collector, & &1) |> Enum.reverse()
  end

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
    %Ai.Types.UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }
  end

  # ============================================================================
  # Telemetry Event Name Consistency Tests
  # ============================================================================

  describe "telemetry event name consistency" do
    test "all loop telemetry events use [:agent_core, :loop, *] prefix", %{
      handler_id: handler_id,
      collector: collector
    } do
      # Attach to all possible loop events
      loop_events = [
        [:agent_core, :loop, :start],
        [:agent_core, :loop, :end]
      ]

      attach_telemetry(loop_events, handler_id, collector)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Verify all collected events have the correct prefix
      assert length(telemetry_events) >= 2

      for {event_name, _measurements, _metadata} <- telemetry_events do
        assert [:agent_core, :loop | _rest] = event_name
      end
    end

    test "all tool_task telemetry events use [:agent_core, :tool_task, *] prefix", %{
      handler_id: handler_id,
      collector: collector
    } do
      tool_events = [
        [:agent_core, :tool_task, :start],
        [:agent_core, :tool_task, :end],
        [:agent_core, :tool_task, :error]
      ]

      attach_telemetry(tool_events, handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_prefix_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Verify all collected events have the correct prefix
      for {event_name, _measurements, _metadata} <- telemetry_events do
        assert [:agent_core, :tool_task | _rest] = event_name
      end
    end

    test "all tool_result telemetry events use [:agent_core, :tool_result, *] prefix", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_result, :emit]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call =
        Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_tool_result_prefix_test")

      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(telemetry_events) >= 1

      for {event_name, _measurements, _metadata} <- telemetry_events do
        assert [:agent_core, :tool_result | _rest] = event_name
      end
    end
  end

  # ============================================================================
  # Tool Task Telemetry Tests
  # ============================================================================

  describe "tool task telemetry" do
    test "emits :start event when tool execution begins", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_task, :start]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_start_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter for this test's specific tool call (telemetry is global with async tests)
      matching_events =
        Enum.filter(telemetry_events, fn {_name, _measurements, metadata} ->
          metadata.tool_call_id == "call_start_test"
        end)

      assert length(matching_events) >= 1

      {event_name, measurements, metadata} = hd(matching_events)
      assert event_name == [:agent_core, :tool_task, :start]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.tool_name == "echo"
      assert metadata.tool_call_id == "call_start_test"
    end

    test "emits :end event when tool execution completes", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_task, :end]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_end_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter for this test's specific tool call (telemetry is global with async tests)
      matching_events =
        Enum.filter(telemetry_events, fn {_name, _measurements, metadata} ->
          metadata.tool_call_id == "call_end_test"
        end)

      assert length(matching_events) >= 1

      {event_name, measurements, metadata} = hd(matching_events)
      assert event_name == [:agent_core, :tool_task, :end]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.tool_name == "echo"
      assert metadata.tool_call_id == "call_end_test"
      assert metadata.is_error == false
    end

    test "emits :end event with is_error=true when tool returns error", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_task, :end]], handler_id, collector)

      error_tool = Mocks.error_tool()
      context = simple_context(tools: [error_tool])

      tool_call =
        Mocks.tool_call("error_tool", %{"message" => "test error"}, id: "call_error_test")

      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled error")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter for this test's specific tool call (telemetry is global with async tests)
      matching_events =
        Enum.filter(telemetry_events, fn {_name, _measurements, metadata} ->
          metadata.tool_call_id == "call_error_test"
        end)

      assert length(matching_events) >= 1

      {event_name, _measurements, metadata} = hd(matching_events)
      assert event_name == [:agent_core, :tool_task, :end]
      assert metadata.tool_name == "error_tool"
      assert metadata.is_error == true
    end

    test "emits :end with is_error=true when tool raises exception", %{
      handler_id: handler_id,
      collector: collector
    } do
      # Note: Tool exceptions are caught and returned as error results,
      # so they emit :end with is_error=true, not :error
      # The :error event is only emitted when the task process itself crashes
      attach_telemetry([[:agent_core, :tool_task, :end]], handler_id, collector)

      crash_tool = %AgentTool{
        name: "crash_tool",
        description: "A tool that crashes",
        parameters: %{},
        label: "Crash",
        execute: fn _id, _params, _signal, _on_update ->
          raise "Intentional crash"
        end
      }

      context = simple_context(tools: [crash_tool])

      tool_call = Mocks.tool_call("crash_tool", %{}, id: "call_crash_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled crash")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # The crash is caught and returned as error result via :end event
      end_events =
        Enum.filter(telemetry_events, fn {name, _, meta} ->
          name == [:agent_core, :tool_task, :end] and meta.tool_call_id == "call_crash_test"
        end)

      # Should have :end event with is_error=true
      assert length(end_events) >= 1

      {event_name, measurements, metadata} = hd(end_events)
      assert event_name == [:agent_core, :tool_task, :end]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.tool_name == "crash_tool"
      assert metadata.is_error == true
    end

    test "emits telemetry for multiple parallel tool calls", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry(
        [
          [:agent_core, :tool_task, :start],
          [:agent_core, :tool_task, :end]
        ],
        handler_id,
        collector
      )

      add_tool = Mocks.add_tool()
      context = simple_context(tools: [add_tool])

      tool_call1 = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: "call_parallel_1")
      tool_call2 = Mocks.tool_call("add", %{"a" => 3, "b" => 4}, id: "call_parallel_2")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call1, tool_call2])
      final_response = Mocks.assistant_message("Results: 3 and 7")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      start_events =
        Enum.filter(telemetry_events, fn {name, _, meta} ->
          name == [:agent_core, :tool_task, :start] and
            meta.tool_call_id in ["call_parallel_1", "call_parallel_2"]
        end)

      end_events =
        Enum.filter(telemetry_events, fn {name, _, meta} ->
          name == [:agent_core, :tool_task, :end] and
            meta.tool_call_id in ["call_parallel_1", "call_parallel_2"]
        end)

      assert length(start_events) == 2
      assert length(end_events) == 2
    end
  end

  # ============================================================================
  # Tool Result Telemetry Tests
  # ============================================================================

  describe "tool result telemetry" do
    test "emits :emit event with trust=:trusted for successful tool results", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_result, :emit]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "tool_result_trusted_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      matching_events =
        Enum.filter(telemetry_events, fn {name, _measurements, metadata} ->
          name == [:agent_core, :tool_result, :emit] and
            metadata.tool_call_id == "tool_result_trusted_test"
        end)

      assert length(matching_events) >= 1

      {event_name, measurements, metadata} = hd(matching_events)
      assert event_name == [:agent_core, :tool_result, :emit]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.tool_name == "echo"
      assert metadata.tool_call_id == "tool_result_trusted_test"
      assert metadata.is_error == false
      assert metadata.trust == :trusted
    end

    test "emits :emit event with trust=:untrusted when tool marks result untrusted", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_result, :emit]], handler_id, collector)

      untrusted_tool = %AgentTool{
        name: "untrusted_echo",
        description: "Returns untrusted output",
        parameters: %{"type" => "object"},
        label: "Untrusted Echo",
        execute: fn _id, %{"text" => text}, _signal, _on_update ->
          %AgentCore.Types.AgentToolResult{
            content: [%Ai.Types.TextContent{type: :text, text: text}],
            trust: :untrusted
          }
        end
      }

      context = simple_context(tools: [untrusted_tool])

      tool_call =
        Mocks.tool_call("untrusted_echo", %{"text" => "from web"},
          id: "tool_result_untrusted_test"
        )

      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      matching_events =
        Enum.filter(telemetry_events, fn {name, _measurements, metadata} ->
          name == [:agent_core, :tool_result, :emit] and
            metadata.tool_call_id == "tool_result_untrusted_test"
        end)

      assert length(matching_events) >= 1

      {event_name, measurements, metadata} = hd(matching_events)
      assert event_name == [:agent_core, :tool_result, :emit]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.tool_name == "untrusted_echo"
      assert metadata.tool_call_id == "tool_result_untrusted_test"
      assert metadata.is_error == false
      assert metadata.trust == :untrusted
    end

    test "emits :emit event with is_error=true for tool execution errors", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_result, :emit]], handler_id, collector)

      error_tool = Mocks.error_tool()
      context = simple_context(tools: [error_tool])

      tool_call =
        Mocks.tool_call("error_tool", %{"message" => "fail"}, id: "tool_result_error_test")

      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      matching_events =
        Enum.filter(telemetry_events, fn {name, _measurements, metadata} ->
          name == [:agent_core, :tool_result, :emit] and
            metadata.tool_call_id == "tool_result_error_test"
        end)

      assert length(matching_events) >= 1

      {_event_name, _measurements, metadata} = hd(matching_events)
      assert metadata.tool_name == "error_tool"
      assert metadata.tool_call_id == "tool_result_error_test"
      assert metadata.is_error == true
      assert metadata.trust == :trusted
    end
  end

  # ============================================================================
  # Loop Telemetry Tests
  # ============================================================================

  describe "loop telemetry" do
    test "emits :start event when loop begins", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :loop, :start]], handler_id, collector)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(telemetry_events) >= 1

      {event_name, measurements, metadata} = hd(telemetry_events)
      assert event_name == [:agent_core, :loop, :start]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.prompt_count == 1
      assert metadata.message_count == 0
      assert metadata.tool_count == 0
    end

    test "emits :end event with duration when loop completes", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :loop, :end]], handler_id, collector)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(telemetry_events) >= 1

      {event_name, measurements, metadata} = hd(telemetry_events)
      assert event_name == [:agent_core, :loop, :end]
      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :duration)
      assert is_integer(measurements.duration) or is_nil(measurements.duration)
      assert metadata.status == :completed
    end

    test "loop :start event has correct metadata structure", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :loop, :start]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events =
        Loop.stream([user_message("Test1"), user_message("Test2")], context, config)
        |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(telemetry_events) >= 1

      {event_name, measurements, metadata} = hd(telemetry_events)
      assert event_name == [:agent_core, :loop, :start]

      # Verify measurements
      assert Map.has_key?(measurements, :system_time)
      assert is_integer(measurements.system_time)

      # Verify metadata
      assert Map.has_key?(metadata, :prompt_count)
      assert Map.has_key?(metadata, :message_count)
      assert Map.has_key?(metadata, :tool_count)
      assert Map.has_key?(metadata, :model)

      # Verify correct counts
      # Two user messages
      assert metadata.prompt_count == 2
      # No prior messages in context
      assert metadata.message_count == 0
      # One tool (echo_tool)
      assert metadata.tool_count == 1
    end

    test "loop :end event has duration measurement", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :loop, :end]], handler_id, collector)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(telemetry_events) >= 1

      {event_name, measurements, metadata} = hd(telemetry_events)
      assert event_name == [:agent_core, :loop, :end]

      # Verify measurements
      assert Map.has_key?(measurements, :duration)
      assert Map.has_key?(measurements, :system_time)
      # Duration should be non-negative (can be nil if not available)
      if measurements.duration != nil do
        assert is_integer(measurements.duration)
        assert measurements.duration >= 0
      end

      # Verify metadata
      assert Map.has_key?(metadata, :message_count)
      assert Map.has_key?(metadata, :status)
      assert Map.has_key?(metadata, :model)
    end

    test "loop :end event status reflects completion type", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :loop, :end]], handler_id, collector)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      {_event_name, _measurements, metadata} = hd(telemetry_events)
      assert metadata.status == :completed
    end
  end

  # ============================================================================
  # Tool Task Telemetry Measurements and Metadata Tests
  # ============================================================================

  describe "tool task telemetry measurements and metadata" do
    test "tool_task :start has correct metadata fields", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :tool_task, :start]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "meta_test_start")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter for our specific tool call
      matching =
        Enum.filter(telemetry_events, fn {_name, _m, meta} ->
          meta.tool_call_id == "meta_test_start"
        end)

      assert length(matching) >= 1

      {event_name, measurements, metadata} = hd(matching)
      assert event_name == [:agent_core, :tool_task, :start]

      # Verify measurements
      assert Map.has_key?(measurements, :system_time)
      assert is_integer(measurements.system_time)

      # Verify metadata
      assert Map.has_key?(metadata, :tool_name)
      assert Map.has_key?(metadata, :tool_call_id)
      assert metadata.tool_name == "echo"
      assert metadata.tool_call_id == "meta_test_start"
    end

    test "tool_task :end has is_error field", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :tool_task, :end]], handler_id, collector)

      echo_tool = Mocks.echo_tool()
      context = simple_context(tools: [echo_tool])

      tool_call = Mocks.tool_call("echo", %{"text" => "hello"}, id: "meta_test_end")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter for our specific tool call
      matching =
        Enum.filter(telemetry_events, fn {_name, _m, meta} ->
          meta.tool_call_id == "meta_test_end"
        end)

      assert length(matching) >= 1

      {event_name, measurements, metadata} = hd(matching)
      assert event_name == [:agent_core, :tool_task, :end]

      # Verify measurements
      assert Map.has_key?(measurements, :system_time)

      # Verify metadata
      assert Map.has_key?(metadata, :tool_name)
      assert Map.has_key?(metadata, :tool_call_id)
      assert Map.has_key?(metadata, :is_error)
      assert metadata.is_error == false
    end

    test "tool_task :end with is_error=true when tool raises exception", %{
      handler_id: handler_id,
      collector: collector
    } do
      # Note: Tool exceptions are caught inside the task and returned as error results
      # The :error telemetry is only for when the task process itself crashes (killed, etc.)
      attach_telemetry([[:agent_core, :tool_task, :end]], handler_id, collector)

      # Create a tool that will raise an exception
      crash_tool = %AgentTool{
        name: "crash_tool",
        description: "A tool that crashes",
        parameters: %{},
        label: "Crash",
        execute: fn _id, _params, _signal, _on_update ->
          raise "Intentional crash for telemetry test"
        end
      }

      context = simple_context(tools: [crash_tool])

      tool_call = Mocks.tool_call("crash_tool", %{}, id: "crash_error_test")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Handled crash")

      config = simple_config(stream_fn: Mocks.mock_stream_fn([tool_response, final_response]))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # The exception is caught and results in :end with is_error=true
      end_events =
        Enum.filter(telemetry_events, fn {name, _m, meta} ->
          name == [:agent_core, :tool_task, :end] and meta.tool_call_id == "crash_error_test"
        end)

      assert length(end_events) >= 1

      {event_name, measurements, metadata} = hd(end_events)
      assert event_name == [:agent_core, :tool_task, :end]
      assert Map.has_key?(measurements, :system_time)
      assert metadata.is_error == true
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "telemetry edge cases" do
    test "telemetry events are emitted even for no tool calls", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry(
        [
          [:agent_core, :loop, :start],
          [:agent_core, :loop, :end]
        ],
        handler_id,
        collector
      )

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      start_events =
        Enum.filter(telemetry_events, fn {name, _, _} ->
          name == [:agent_core, :loop, :start]
        end)

      end_events =
        Enum.filter(telemetry_events, fn {name, _, _} ->
          name == [:agent_core, :loop, :end]
        end)

      assert length(start_events) >= 1
      assert length(end_events) >= 1
    end

    test "multiple sequential tool calls emit separate telemetry events", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry(
        [
          [:agent_core, :tool_task, :start],
          [:agent_core, :tool_task, :end]
        ],
        handler_id,
        collector
      )

      add_tool = Mocks.add_tool()
      context = simple_context(tools: [add_tool])

      # First turn: single tool call
      tool_call1 = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: "sequential_1")
      tool_response1 = Mocks.assistant_message_with_tool_calls([tool_call1])

      # Second turn: another tool call
      tool_call2 = Mocks.tool_call("add", %{"a" => 3, "b" => 4}, id: "sequential_2")
      tool_response2 = Mocks.assistant_message_with_tool_calls([tool_call2])

      final_response = Mocks.assistant_message("Final result")

      config =
        simple_config(
          stream_fn: Mocks.mock_stream_fn([tool_response1, tool_response2, final_response])
        )

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      telemetry_events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter start events for our specific tool calls
      start_events =
        Enum.filter(telemetry_events, fn {name, _m, meta} ->
          name == [:agent_core, :tool_task, :start] and
            meta.tool_call_id in ["sequential_1", "sequential_2"]
        end)

      end_events =
        Enum.filter(telemetry_events, fn {name, _m, meta} ->
          name == [:agent_core, :tool_task, :end] and
            meta.tool_call_id in ["sequential_1", "sequential_2"]
        end)

      # Should have start and end for both tool calls
      assert length(start_events) == 2
      assert length(end_events) == 2

      # Verify both tool call IDs are represented
      start_ids = Enum.map(start_events, fn {_, _, meta} -> meta.tool_call_id end) |> Enum.sort()
      assert start_ids == ["sequential_1", "sequential_2"]
    end
  end

  # ============================================================================
  # Telemetry Handler Attachment Tests
  # ============================================================================

  describe "telemetry handler management" do
    test "multiple handlers can attach to same events", %{
      handler_id: handler_id,
      collector: collector
    } do
      # Create a second collector
      {:ok, collector2} = Agent.start_link(fn -> [] end)
      handler_id2 = :erlang.unique_integer()

      # Attach both handlers
      attach_telemetry([[:agent_core, :loop, :start]], handler_id, collector)
      attach_telemetry([[:agent_core, :loop, :start]], handler_id2, collector2)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      events1 = get_events(collector)
      events2 = get_events(collector2)

      detach_telemetry(handler_id)
      detach_telemetry(handler_id2)
      Agent.stop(collector2)

      # Both handlers should have received the event
      assert length(events1) >= 1
      assert length(events2) >= 1

      # Events should be the same
      assert hd(events1) == hd(events2)
    end

    test "detaching handler stops receiving events", %{
      handler_id: handler_id,
      collector: collector
    } do
      attach_telemetry([[:agent_core, :loop, :start]], handler_id, collector)

      context = simple_context()
      response = Mocks.assistant_message("Hello!")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      # First run - should collect events
      _events = Loop.stream([user_message("Test")], context, config) |> Enum.to_list()

      events_before = get_events(collector)
      assert length(events_before) >= 1

      # Detach handler
      detach_telemetry(handler_id)

      # Clear collector
      Agent.update(collector, fn _ -> [] end)

      # Second run - should not collect events
      _events = Loop.stream([user_message("Test2")], context, config) |> Enum.to_list()

      events_after = get_events(collector)
      assert events_after == []
    end
  end
end
