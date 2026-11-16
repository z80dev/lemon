defmodule LemonAgent.AgentStreamingTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Agent
  alias LemonAgent.Test.Mocks
  alias LemonAi.StreamAccumulator
  alias LemonAi.Types.{AssistantMessage, TextContent, ThinkingContent, ToolCall}

  defp start_agent(opts \\ []) do
    start_supervised!(
      {Agent, Keyword.put_new(opts, :initial_state, %{model: Mocks.mock_model()})}
    )
  end

  defp start_message do
    %{Mocks.assistant_message("") | content: []}
  end

  defp emit(agent, event), do: send(agent, {:agent_event, event})

  test "snapshots reconstruct interleaved blocks without replacing the chunk accumulator" do
    agent = start_agent()
    initial = start_message()
    tool = Mocks.tool_call("read_file", %{}, id: "call_1")

    emit(agent, {:message_start, initial})
    emit(agent, {:message_update, {:thinking_start, 0}})
    emit(agent, {:message_update, {:thinking_delta, 0, "Let me "}})
    emit(agent, {:message_update, {:text_start, 1}})
    emit(agent, {:message_update, {:text_delta, 1, "Hel"}})
    emit(agent, {:message_update, {:tool_call_start, 2, tool}})

    assert %AssistantMessage{
             content: [
               %ThinkingContent{thinking: "Let me "},
               %TextContent{text: "Hel"},
               %ToolCall{id: "call_1", name: "read_file", arguments: %{}}
             ]
           } = Agent.get_state(agent).stream_message

    emit(agent, {:message_update, {:thinking_delta, 0, "check."}})
    emit(agent, {:message_update, {:text_delta, 1, "lo"}})
    emit(agent, {:message_update, {:tool_call_delta, 2, ~s({"path":"mix)}})

    internal = :sys.get_state(agent)
    assert %StreamAccumulator{} = internal.stream_accumulator
    assert internal.agent_state.stream_message == nil

    assert %AssistantMessage{
             content: [
               %ThinkingContent{thinking: "Let me check."},
               %TextContent{text: "Hello"},
               %ToolCall{arguments: %{"path" => "mix"}}
             ]
           } = Agent.get_state(agent).stream_message

    assert :sys.get_state(agent).stream_accumulator == internal.stream_accumulator
    assert Agent.get_state(agent).stream_message.model == initial.model

    emit(agent, {:message_update, {:tool_call_delta, 2, ~s(.exs"})}})
    final_tool = %{tool | arguments: %{"path" => "mix.exs"}}
    emit(agent, {:message_update, {:tool_call_end, 2, final_tool}})
    emit(agent, {:message_update, {:thinking_end, 0, "Let me check."}})
    emit(agent, {:message_update, {:text_end, 1, "Hello!"}})

    assert %AssistantMessage{
             content: [
               %ThinkingContent{thinking: "Let me check."},
               %TextContent{text: "Hello!"},
               ^final_tool
             ]
           } = Agent.get_state(agent).stream_message
  end

  test "100 KB tool arguments travel only as deltas until a snapshot or message end" do
    agent = start_agent()
    Agent.subscribe(agent, self())
    initial = start_message()
    tool = Mocks.tool_call("write_file", %{}, id: "large_call")
    chunk = String.duplicate("x", 1_000)
    payload = String.duplicate(chunk, 100)

    emit(agent, {:message_start, initial})
    emit(agent, {:message_update, {:tool_call_start, 0, tool}})
    emit(agent, {:message_update, {:tool_call_delta, 0, ~s({"content":")}})

    for _ <- 1..100 do
      emit(agent, {:message_update, {:tool_call_delta, 0, chunk}})
    end

    emit(agent, {:message_update, {:tool_call_delta, 0, ~s("})}})
    internal = :sys.get_state(agent)
    assert internal.agent_state.stream_message == nil
    assert %StreamAccumulator{} = internal.stream_accumulator

    assert_receive {:agent_event, {:message_start, ^initial}}
    assert_receive {:agent_event, {:message_update, {:tool_call_start, 0, ^tool}}}
    assert_receive {:agent_event, {:message_update, {:tool_call_delta, 0, ~s({"content":")}}}

    for _ <- 1..100 do
      assert_receive {:agent_event, {:message_update, {:tool_call_delta, 0, ^chunk}}}
    end

    assert_receive {:agent_event, {:message_update, {:tool_call_delta, 0, ~s("})}}}
    refute_received {:agent_event, {:message_update, _, _}}

    assert %AssistantMessage{content: [%ToolCall{arguments: %{"content" => ^payload}}]} =
             Agent.get_state(agent).stream_message

    assert :sys.get_state(agent).stream_accumulator == internal.stream_accumulator

    final_tool = %{tool | arguments: %{"content" => payload}}
    final = %{initial | content: [final_tool], stop_reason: :tool_use}
    emit(agent, {:message_update, {:tool_call_end, 0, final_tool}})
    emit(agent, {:message_end, final})

    assert Agent.get_state(agent).messages == [final]
    assert Agent.get_state(agent).stream_message == nil
    assert :sys.get_state(agent).stream_accumulator == nil
    assert_receive {:agent_event, {:message_update, {:tool_call_end, 0, ^final_tool}}}
    assert_receive {:agent_event, {:message_end, ^final}}
  end

  test "live provider deltas are available through get_state before completion" do
    final = Mocks.assistant_message("Final answer")

    agent =
      start_agent(stream_fn: Mocks.blocking_stream_fn(final, self(), chunks: 2))

    Agent.subscribe(agent, self())
    :ok = Agent.prompt(agent, "Start")
    assert_receive {:stream_blocked, producer}, 2_000
    assert_receive {:agent_event, {:message_update, {:text_delta, 0, "chunk 2"}}}, 2_000

    assert %AssistantMessage{content: [%TextContent{text: "chunk 1chunk 2"}]} =
             Agent.get_state(agent).stream_message

    assert :sys.get_state(agent).agent_state.stream_message == nil

    send(producer, :release_stream)
    assert :ok = Agent.wait_for_idle(agent, timeout: 2_000)
    assert_receive {:agent_event, {:message_end, ^final}}
    assert List.last(Agent.get_state(agent).messages) == final
    assert Agent.get_state(agent).stream_message == nil
    assert :sys.get_state(agent).stream_accumulator == nil
  end

  test "normal notifications retain event boundaries and terminal thinking signatures" do
    thinking = %ThinkingContent{thinking: "Reasoning", thinking_signature: "signed-reasoning"}
    text = %TextContent{text: "Answer"}
    final = %{Mocks.assistant_message("") | content: [thinking, text]}
    agent = start_agent(stream_fn: Mocks.mock_stream_fn_single(final))
    Agent.subscribe(agent, self())

    :ok = Agent.prompt(agent, "Question")
    assert :ok = Agent.wait_for_idle(agent, timeout: 2_000)
    events = receive_events()

    assert Enum.filter(events, &match?({:message_update, _}, &1)) == [
             {:message_update, {:thinking_start, 0}},
             {:message_update, {:thinking_delta, 0, "Reasoning"}},
             {:message_update, {:thinking_end, 0, "Reasoning"}},
             {:message_update, {:text_start, 1}},
             {:message_update, {:text_delta, 1, "Answer"}},
             {:message_update, {:text_end, 1, "Answer"}}
           ]

    refute Enum.any?(events, &match?({:message_update, _, _}, &1))
    assert {:message_end, final} in events
    assert {:agent_end, messages} = List.last(events)
    assert List.last(messages) == final
    assert List.last(Agent.get_state(agent).messages) == final
  end

  test "retry, message boundaries, reset and terminal events discard old chunks" do
    agent = start_agent()

    for boundary <- [
          {:provider_retry, %{attempt: 1}},
          {:message_end, Mocks.assistant_message("Finished")},
          {:agent_end, []},
          :reset
        ] do
      emit(agent, {:message_start, start_message()})
      emit(agent, {:message_update, {:text_start, 0}})
      emit(agent, {:message_update, {:text_delta, 0, "Old answer"}})
      assert Agent.get_state(agent).stream_message.content == [%TextContent{text: "Old answer"}]

      if boundary == :reset, do: Agent.reset(agent), else: emit(agent, boundary)
      assert Agent.get_state(agent).stream_message == nil
      assert :sys.get_state(agent).stream_accumulator == nil

      emit(agent, {:message_update, {:text_delta, 0, "Late delta"}})
      assert Agent.get_state(agent).stream_message == nil

      emit(agent, {:message_start, start_message()})
      emit(agent, {:message_update, {:text_start, 0}})
      emit(agent, {:message_update, {:text_delta, 0, "New answer"}})
      assert Agent.get_state(agent).stream_message.content == [%TextContent{text: "New answer"}]
    end
  end

  test "non-assistant message starts remain available without an accumulator" do
    agent = start_agent()
    user = Mocks.user_message("Question")
    emit(agent, {:message_start, user})
    assert Agent.get_state(agent).stream_message == user
    assert :sys.get_state(agent).stream_accumulator == nil

    emit(agent, {:message_end, user})
    assert Agent.get_state(agent).stream_message == nil
    assert Agent.get_state(agent).messages == [user]
  end

  defp receive_events(events \\ []) do
    receive do
      {:agent_event, {:agent_end, _} = event} -> Enum.reverse([event | events])
      {:agent_event, event} -> receive_events([event | events])
    after
      2_000 -> flunk("agent did not deliver its terminal event")
    end
  end
end
