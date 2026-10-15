defmodule LemonAgent.Loop.ContinuationTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{EventStream, Loop}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}

  defp run(replies, tools \\ []) do
    parent = self()
    {:ok, queue} = Agent.start_link(fn -> replies end)

    stream_fn = fn _model, context, _options ->
      send(parent, {:request, context})
      events = Agent.get_and_update(queue, fn [head | rest] -> {head, rest} end)
      message = List.last(events) |> elem(2)
      {:ok, stream} = LemonAi.EventStream.start_link()
      Enum.each(events, &LemonAi.EventStream.push(stream, &1))
      LemonAi.EventStream.complete(stream, message)
      {:ok, stream}
    end

    config = %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      stream_fn: stream_fn,
      max_retries: 0
    }

    context = AgentContext.new(system_prompt: "Test system", tools: tools)
    stream = Loop.agent_loop([Mocks.user_message("do it")], context, config, nil, stream_fn)
    events = EventStream.events(stream) |> Enum.to_list()
    Agent.stop(queue)
    events
  end

  defp reply(message), do: [{:done, message.stop_reason, message}]
  defp empty, do: Mocks.assistant_message("")

  test "empty reply continues inside one run without a synthetic human message" do
    events = run([reply(empty()), reply(Mocks.assistant_message("done"))])
    assert Enum.count(events, &match?({:agent_start}, &1)) == 1
    assert {:agent_end, messages} = List.last(events)
    assert [%{role: :user}, %{content: [%{text: "done"}]}] = messages
    assert_receive {:request, %{system_prompt: "Test system"}}
    assert_receive {:request, context}
    assert context.system_prompt =~ "previous reply was empty"
    assert [%{role: :user}] = context.messages

    assert Enum.any?(
             events,
             &match?({:provider_retry, %{reason: "empty reply, continuing (1/3)"}}, &1)
           )
  end

  test "ordinary announce-then-stop replies remain final" do
    events = run([reply(Mocks.assistant_message("I'll run the tests now."))])
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
    assert {:agent_end, _} = List.last(events)
  end

  test "malformed arguments after the cap use the existing argument-error tool result path" do
    bad = Mocks.assistant_message_with_tool_calls([Mocks.tool_call("echo", %{})])

    events =
      run(
        List.duplicate(reply(bad), 4) ++ [reply(Mocks.assistant_message("done"))],
        [Mocks.echo_tool()]
      )

    assert Enum.count(events, &match?({:provider_retry, _}, &1)) == 3
    assert Enum.count(events, &match?({:tool_execution_start, _, "echo", %{}}, &1)) == 1
    assert {:agent_end, messages} = List.last(events)

    assert Enum.any?(messages, fn
             %{
               role: :tool_result,
               is_error: true,
               details: %{error_type: :invalid_tool_arguments}
             } ->
               true

             _ ->
               false
           end)
  end

  for arguments <- ["{broken", %{}] do
    test "malformed arguments #{inspect(arguments)} continue before executing the corrected call" do
      bad =
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("echo", unquote(Macro.escape(arguments)))
        ])

      good = Mocks.assistant_message_with_tool_calls([Mocks.tool_call("echo", %{"text" => "ok"})])

      events =
        run([reply(bad), reply(good), reply(Mocks.assistant_message("done"))], [Mocks.echo_tool()])

      assert Enum.count(events, &match?({:tool_execution_start, _, _, _}, &1)) == 1
      assert Enum.any?(events, &match?({:tool_execution_start, _, "echo", %{"text" => "ok"}}, &1))
      assert {:agent_end, _} = List.last(events)
    end
  end

  test "three continuations exhaust into the existing assistant error" do
    events = run(List.duplicate(reply(empty()), 4))
    assert Enum.count(events, &match?({:provider_retry, _}, &1)) == 3

    assert Enum.any?(events, fn
             {:error, {:assistant_error, "empty_assistant_response"}, _} -> true
             _ -> false
           end)
  end

  test "committed text is retained once and continuation only appends" do
    call = Mocks.tool_call("echo", %{})

    partial = %{
      Mocks.assistant_message("already sent")
      | content: Mocks.assistant_message("already sent").content ++ [call]
    }

    terminal = %{partial | stop_reason: :tool_use}
    first = [{:text_delta, 0, "already sent", partial}, {:done, :tool_use, terminal}]
    events = run([first, reply(Mocks.assistant_message("appended"))], [Mocks.echo_tool()])

    assert Enum.count(
             events,
             &match?({:message_update, _, {:text_delta, _, "already sent", _}}, &1)
           ) == 1

    assert_receive {:request, _}
    assert_receive {:request, context}
    assert [%{role: :user}, %{content: [%{text: "already sent"}]}] = context.messages

    assert {:agent_end,
            [
              %{role: :user},
              %{content: [%{text: "already sent"}]},
              %{content: [%{text: "appended"}]}
            ]} = List.last(events)
  end

  test "invalid raw JSON is not hidden by provider partial JSON repair" do
    call = Mocks.tool_call("echo", %{"text" => "repaired"})
    message = Mocks.assistant_message_with_tool_calls([call])

    first = [
      {:tool_call_delta, 0, "{\"text\":\"repaired\"", message},
      {:done, :tool_use, message}
    ]

    events = run([first, reply(Mocks.assistant_message("done"))], [Mocks.echo_tool()])
    refute Enum.any?(events, &match?({:tool_execution_start, _, _, _}, &1))
    assert Enum.any?(events, &match?({:provider_retry, %{category: :continuation}}, &1))
  end

  test "continuation after tool execution keeps results without re-executing tools" do
    call = Mocks.assistant_message_with_tool_calls([Mocks.tool_call("echo", %{"text" => "ok"})])

    events =
      run(
        [reply(empty()), reply(call), reply(empty()), reply(Mocks.assistant_message("done"))],
        [Mocks.echo_tool()]
      )

    assert Enum.count(events, &match?({:provider_retry, _}, &1)) == 2
    assert Enum.count(events, &match?({:tool_execution_start, _, _, _}, &1)) == 1
    assert {:agent_end, messages} = List.last(events)
    assert List.last(messages).content == Mocks.assistant_message("done").content
    assert_receive {:request, _}
    assert_receive {:request, _}
    assert_receive {:request, before_continuation}
    assert_receive {:request, after_continuation}
    assert before_continuation.messages == after_continuation.messages
    assert Enum.any?(after_continuation.messages, &match?(%{role: :tool_result}, &1))
  end
end
