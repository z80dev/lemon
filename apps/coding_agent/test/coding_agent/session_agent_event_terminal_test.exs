defmodule CodingAgent.SessionAgentEventTerminalTest do
  use ExUnit.Case, async: true

  alias LemonAgent.EventStream
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.AssistantMessage
  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias LemonAgent.Types.{AgentTool, AgentToolResult, ToolSchemaSnapshot}
  alias LemonAi.Types.{TextContent, ToolCall, ToolResultMessage}

  defp start_session(opts \\ []) do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "session_agent_event_terminal_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)
    session_file = Path.join(cwd, "session.jsonl")
    :ok = SessionManager.save_to_file(session_file, SessionManager.new(cwd))

    defaults = [
      cwd: cwd,
      workspace_dir: Path.join(cwd, "workspace"),
      tools: [],
      extension_inventory: {[], []},
      mcp_tools: [],
      session_file: session_file,
      model: Mocks.mock_model(),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    session = start_supervised!({Session, Keyword.merge(defaults, opts)})

    on_exit(fn ->
      File.rm_rf!(cwd)
    end)

    session
  end

  test "schema snapshot admission accepts nested tool structs but rejects oversized backing" do
    backing = :binary.copy("x", 2048)
    description = binary_part(backing, 0, 256)
    assert :binary.referenced_byte_size(description) == byte_size(backing)

    tool = %AgentTool{
      name: "schema_read",
      label: "Schema read",
      description: description,
      parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}},
      execute: fn _id, _args, _signal, _on_update ->
        %AgentToolResult{content: [%TextContent{type: :text, text: "read result"}]}
      end
    }

    snapshot = ToolSchemaSnapshot.new([tool])

    message = {:session_event, "schema-session", {:tool_schema_snapshot, snapshot}}
    delivery = LemonCore.Bus.Delivery.new(self(), tagged: true, max_bytes: 16_384)
    assert :ok = LemonCore.Bus.Delivery.send(delivery, message)
    assert_receive {:lemon_bus_delivery, gate, ^message}
    assert LemonCore.Bus.Delivery.matches?(delivery, gate)
    refute LemonCore.Bus.Delivery.closed?(delivery)

    oversized_backing = :binary.copy("x", 65_536)
    oversized_description = binary_part(oversized_backing, 0, 256)
    assert :binary.referenced_byte_size(oversized_description) == byte_size(oversized_backing)
    oversized_snapshot = %{snapshot | tools: [%{tool | description: oversized_description}]}

    oversized_message =
      {:session_event, "schema-session", {:tool_schema_snapshot, oversized_snapshot}}

    assert :erlang.external_size(oversized_message) < delivery.max_bytes
    assert {:error, :overflow} = LemonCore.Bus.Delivery.send(delivery, oversized_message)
    assert :ok = LemonCore.Bus.Delivery.terminal(delivery, oversized_message)
    assert_receive {:lemon_bus_delivery, ^gate, {:stream_resync, :overflow}}
    refute_received {:lemon_bus_delivery, ^gate, ^oversized_message}
    assert LemonCore.Bus.Delivery.closed?(delivery)
  end

  defp force_streaming(session) do
    :sys.replace_state(session, fn state ->
      %{state | is_streaming: true}
    end)
  end

  defp queue_diagnostic_follow_up(session) do
    :ok = Session.follow_up(session, "queued follow-up")
    _ = Session.get_state(session)
    :ok
  end

  defp collect_stream_events(stream, timeout \\ 2_000) do
    Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
    |> Task.await(timeout)
  end

  defp wait_for_abort(signal) do
    unless LemonAgent.AbortSignal.aborted?(signal) do
      Process.sleep(5)
      wait_for_abort(signal)
    end
  end

  defp assert_native_cancel(mode) do
    parent = self()
    call_id = "native_cancel_#{mode}"
    queued_id = "native_queued_#{mode}"

    tool = %AgentTool{
      name: "native_wait",
      label: "Native wait",
      description: "Emits observed output before cancellation",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, _args, signal, on_update ->
        on_update.(%AgentToolResult{
          content: [%TextContent{type: :text, text: "STARTED\n"}],
          trust: :untrusted,
          details: %{source: "observed stdout"}
        })

        send(parent, {:native_tool_started, mode, self()})

        if mode == :cooperative do
          wait_for_abort(signal)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: "Command cancelled.\n\nSTARTED\n"}],
            trust: :untrusted,
            is_error: true,
            details: %{cancelled: true, source: "actual final result"}
          }
        else
          Process.sleep(5_000)
          send(parent, :forbidden_mutation)
          %AgentToolResult{content: [%TextContent{type: :text, text: "too late"}]}
        end
      end
    }

    queued = %{
      tool
      | name: "native_queued",
        execute: fn _id, _args, _signal, _on_update ->
          send(parent, :forbidden_mutation)
          %AgentToolResult{content: []}
        end
    }

    response = %{
      Mocks.assistant_message("")
      | stop_reason: :tool_use,
        content: [
          %ToolCall{type: :tool_call, id: call_id, name: tool.name, arguments: %{}},
          %ToolCall{type: :tool_call, id: queued_id, name: queued.name, arguments: %{}}
        ]
    }

    session =
      start_session(tools: [tool, queued], stream_fn: Mocks.mock_stream_fn_single(response))

    {:ok, stream} = Session.subscribe(session, mode: :stream)
    :ok = Session.prompt(session, "start the tool and wait")
    assert_receive {:native_tool_started, ^mode, worker}, 2_000
    monitor = Process.monitor(worker)
    :ok = Session.abort(session)

    events = collect_stream_events(stream)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    refute_receive :forbidden_mutation, 10

    native_events =
      for {:session_event, _, event} <- events, do: event

    assert Enum.any?(native_events, fn
             {:tool_schema_snapshot, %ToolSchemaSnapshot{tools: tools}} ->
               Enum.any?(tools, &(&1.name == "native_wait"))

             _ ->
               false
           end)

    assert {:tool_execution_end, ^call_id, "native_wait", result, true} =
             Enum.find(native_events, &match?({:tool_execution_end, ^call_id, _, _, _}, &1))

    assert result.trust == :untrusted
    assert result.details.cancelled
    assert Enum.any?(result.content, &(&1.text =~ "STARTED"))

    if mode == :cooperative do
      assert result.details.source == "actual final result"
      assert Enum.map_join(result.content, "", & &1.text) == "Command cancelled.\n\nSTARTED\n"
    else
      assert result.details.outcome == :unknown
      assert result.details.partial_details == %{source: "observed stdout"}
      assert Enum.any?(result.content, &(&1.text =~ "Mutation outcome is unknown"))
    end

    assert {:tool_execution_end, ^queued_id, "native_queued", queued_result, true} =
             Enum.find(native_events, &match?({:tool_execution_end, ^queued_id, _, _, _}, &1))

    assert queued_result.details.outcome == :not_started

    tool_end_index =
      Enum.find_index(native_events, &match?({:tool_execution_end, ^call_id, _, _, _}, &1))

    message_end_index =
      Enum.find_index(
        native_events,
        &match?({:message_end, %ToolResultMessage{tool_call_id: ^call_id}}, &1)
      )

    turn_end_index = Enum.find_index(native_events, &match?({:turn_end, _, _}, &1))
    assert tool_end_index < message_end_index
    assert message_end_index < turn_end_index
    assert List.last(events) == {:canceled, :assistant_aborted}

    state = Session.get_state(session)
    refute state.is_streaming
    {:ok, reloaded} = SessionManager.load_from_file(state.session_file)

    persisted =
      SessionManager.entries(reloaded)
      |> Enum.filter(&(&1.type == :message and &1.message["role"] == "tool_result"))

    assert Enum.map(persisted, & &1.message["tool_call_id"]) == [call_id, queued_id]
    assert hd(persisted).message["details"]["cancelled"] == true
    assert Enum.any?(hd(persisted).message["content"], &(&1["text"] =~ "STARTED"))
  end

  test "native cancellation drains cooperative tool output and persists paired tool results" do
    assert_native_cancel(:cooperative)
  end

  test "native cancellation preserves observed partial output when cleanup must kill the worker" do
    assert_native_cancel(:forced)
  end

  test "aborting an idle provider preserves observed partial prose in chronological journal order" do
    partial = Mocks.assistant_message("OBSERVED_PARTIAL_PROSE")

    stream_fn = fn _model, _context, _options ->
      {:ok, response_stream} = LemonAi.EventStream.start_link()
      :ok = LemonAi.EventStream.push(response_stream, {:start, Mocks.assistant_message("")})

      :ok =
        LemonAi.EventStream.push(
          response_stream,
          {:text_delta, 0, "OBSERVED_PARTIAL_PROSE", partial}
        )

      {:ok, response_stream}
    end

    session = start_session(stream_fn: stream_fn)
    _unsubscribe = Session.subscribe(session)
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    session_id = Session.get_state(session).session_manager.header.id
    :ok = Session.prompt(session, "write an essay")

    assert_receive {:session_event, ^session_id,
                    {:message_update,
                     %AssistantMessage{content: [%TextContent{text: "OBSERVED_PARTIAL_PROSE"}]},
                     _}},
                   2_000

    :ok = Session.abort(session)
    events = collect_stream_events(stream)
    assert List.last(events) == {:canceled, :assistant_aborted}

    assert Enum.any?(events, fn
             {:session_event, _,
              {:message_end, %AssistantMessage{stop_reason: :aborted} = message}} ->
               Enum.any?(message.content, &(&1.text == "OBSERVED_PARTIAL_PROSE"))

             _ ->
               false
           end)

    state = Session.get_state(session)
    {:ok, reloaded} = SessionManager.load_from_file(state.session_file)

    messages =
      for entry <- SessionManager.entries(reloaded), entry.type == :message, do: entry.message

    assert Enum.map(messages, & &1["role"]) == ["user", "assistant"]
    assert List.last(messages)["stop_reason"] == "aborted"

    assert Enum.map_join(List.last(messages)["content"], "", & &1["text"]) ==
             "OBSERVED_PARTIAL_PROSE"
  end

  test "aborted assistant message_end clears streaming and completes stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    queue_diagnostic_follow_up(session)
    force_streaming(session)

    aborted_message = Mocks.assistant_message("", stop_reason: :aborted)
    send(session, {:agent_event, {:message_end, aborted_message}})

    events = collect_stream_events(stream)

    assert Enum.any?(events, fn
             {:session_event, _, {:message_end, %AssistantMessage{stop_reason: :aborted}}} ->
               true

             _ ->
               false
           end)

    assert List.last(events) == {:canceled, :assistant_aborted}

    state = Session.get_state(session)
    assert state.is_streaming == false
    assert map_size(state.event_streams) == 0
    assert Session.diagnostics(session).follow_up_queue_size == 0
  end

  test "message_end persists user, assistant, and tool_result messages" do
    session = start_session()

    send(session, {:agent_event, {:message_end, Mocks.user_message("hello")}})
    send(session, {:agent_event, {:message_end, Mocks.assistant_message("world")}})

    send(
      session,
      {:agent_event,
       {:message_end,
        Mocks.tool_result_message("call_1", "echo", "Echo: hello", details: %{ok: true})}}
    )

    state = Session.get_state(session)

    message_entries =
      Enum.filter(SessionManager.entries(state.session_manager), fn entry ->
        entry.type == :message
      end)

    assert Enum.map(message_entries, & &1.message["role"]) == ["user", "assistant", "tool_result"]
    assert List.last(message_entries).message["details"] == %{ok: true}
  end

  test "agent_end terminal semantics stay consistent for stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    queue_diagnostic_follow_up(session)
    force_streaming(session)

    final_messages = [Mocks.user_message("hi"), Mocks.assistant_message("done")]
    send(session, {:agent_event, {:agent_end, final_messages}})

    events = collect_stream_events(stream)

    assert Enum.any?(events, fn
             {:session_event, _, {:agent_end, ^final_messages}} -> true
             _ -> false
           end)

    assert List.last(events) == {:agent_end, final_messages}

    state = Session.get_state(session)
    assert state.is_streaming == false
    assert map_size(state.event_streams) == 0
    assert :queue.len(state.steering_queue) == 0
    assert Session.diagnostics(session).follow_up_queue_size == 0
  end

  test "error terminal semantics stay consistent for stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    queue_diagnostic_follow_up(session)
    force_streaming(session)

    partial_state = %{messages: [Mocks.user_message("partial")]}
    send(session, {:agent_event, {:error, :upstream_failure, partial_state}})

    events = collect_stream_events(stream)

    assert Enum.any?(events, fn
             {:session_event, _, {:error, :upstream_failure, ^partial_state}} -> true
             _ -> false
           end)

    assert List.last(events) == {:error, :upstream_failure, partial_state}

    state = Session.get_state(session)
    assert state.is_streaming == false
    assert map_size(state.event_streams) == 0
    assert Session.diagnostics(session).follow_up_queue_size == 0
  end

  test "canceled terminal semantics stay consistent for stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    :ok = Session.steer(session, "queued steering")
    queue_diagnostic_follow_up(session)
    force_streaming(session)

    send(session, {:agent_event, {:canceled, :reset}})

    events = collect_stream_events(stream)

    assert Enum.any?(events, fn
             {:session_event, _, {:canceled, :reset}} -> true
             _ -> false
           end)

    assert List.last(events) == {:canceled, :reset}

    state = Session.get_state(session)
    assert state.is_streaming == false
    assert map_size(state.event_streams) == 0
    assert :queue.len(state.steering_queue) == 0
    assert Session.diagnostics(session).follow_up_queue_size == 0
  end

  test "abort immediately clears the session follow-up diagnostic mirror" do
    session = start_session()
    queue_diagnostic_follow_up(session)
    assert Session.diagnostics(session).follow_up_queue_size == 1

    assert :ok = Session.abort(session)
    assert Session.diagnostics(session).follow_up_queue_size == 0
  end

  test "agent exit clears the session follow-up diagnostic mirror" do
    session = start_session()
    queue_diagnostic_follow_up(session)
    state = Session.get_state(session)

    send(session, {:EXIT, state.agent, :provider_crash})

    assert Session.diagnostics(session).follow_up_queue_size == 0
    assert :queue.len(Session.get_state(session).steering_queue) == 0
  end
end
