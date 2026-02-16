defmodule CodingAgent.SessionAgentEventTerminalTest do
  use ExUnit.Case, async: true

  alias AgentCore.EventStream
  alias AgentCore.Test.Mocks
  alias Ai.Types.AssistantMessage
  alias CodingAgent.Session

  defp start_session(opts \\ []) do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "session_agent_event_terminal_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)

    defaults = [
      cwd: cwd,
      model: Mocks.mock_model(),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    {:ok, session} = Session.start_link(Keyword.merge(defaults, opts))
    session
  end

  defp force_streaming(session) do
    :sys.replace_state(session, fn state ->
      %{state | is_streaming: true}
    end)
  end

  defp collect_stream_events(stream, timeout \\ 2_000) do
    Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
    |> Task.await(timeout)
  end

  test "aborted assistant message_end clears streaming and completes stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
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
      Enum.filter(state.session_manager.entries, fn entry ->
        entry.type == :message
      end)

    assert Enum.map(message_entries, & &1.message["role"]) == ["user", "assistant", "tool_result"]
    assert List.last(message_entries).message["details"] == %{ok: true}
  end

  test "agent_end terminal semantics stay consistent for stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
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
  end

  test "error terminal semantics stay consistent for stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
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
  end

  test "canceled terminal semantics stay consistent for stream subscribers" do
    session = start_session()
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    :ok = Session.steer(session, "queued steering")
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
  end
end
