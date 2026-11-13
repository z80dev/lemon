defmodule LemonAgent.Loop.ToolStreamTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{AbortSignal, EventStream, Loop}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  test "streams accumulated arguments before execution and settles once afterwards" do
    run([
      streamed_call("call_1", [~s({"n":), ~s( "2", "i": "Spawning"})], %{"n" => 2}),
      reply(Mocks.assistant_message("done"))
    ])

    assert [
             {:stream, {:args, %{id: "call_1", json: ~s({"n":)}}},
             {:stream, {:args, %{id: "call_1", json: json, prepare: prepare}}},
             {:executed, "call_1", %{"n" => 2}},
             {:stream, {:settle, "call_1"}}
           ] = observed()

    # The callback sees what execute will receive: intent removed, schema types.
    assert {:ok, %{"n" => 2}} = prepare.(Jason.decode!(json))
  end

  test "a provider error after streamed arguments settles without executing" do
    call = Mocks.tool_call("spawn", %{"n" => 1}, id: "call_err")

    failed = %{
      Mocks.assistant_message_with_tool_calls([call])
      | stop_reason: :error,
        error_message: "provider failed"
    }

    events =
      run([
        Enum.drop(streamed_call("call_err", [~s({"n": 1})], %{"n" => 1}), -1) ++
          [{:error, :error, failed}]
      ])

    assert Enum.any?(events, &match?({:error, _, _}, &1))

    assert [{:stream, {:args, %{id: "call_err"}}}, {:stream, {:settle, "call_err"}}] =
             observed()
  end

  test "aborting while arguments stream settles the call without executing it" do
    signal = AbortSignal.new()

    run(
      [streamed_call("call_abort", [~s({"n"), ~s(: 1}), "  "], %{"n" => 1})],
      signal: signal,
      abort_on_args: true
    )

    assert [{:stream, {:args, %{id: "call_abort"}}} | rest] = observed()
    assert rest == [{:stream, {:settle, "call_abort"}}]
  end

  test "a discarded attempt is settled before the next attempt streams" do
    run([
      streamed_call("call_bad", [~s({"n":)], %{}),
      streamed_call("call_good", [~s({"n": 3})], %{"n" => 3}),
      reply(Mocks.assistant_message("done"))
    ])

    assert [
             {:stream, {:args, %{id: "call_bad"}}},
             {:stream, {:settle, "call_bad"}},
             {:stream, {:args, %{id: "call_good"}}},
             {:executed, "call_good", %{"n" => 3}},
             {:stream, {:settle, "call_good"}}
           ] = observed()
  end

  test "schema-only snapshots drop the stream callback" do
    snapshot = LemonAgent.Types.ToolSchemaSnapshot.new([spawn_tool(self(), [])])

    assert [%AgentTool{execute: nil, on_stream: nil}] =
             LemonAgent.Types.ToolSchemaSnapshot.without_executors(snapshot).tools
  end

  defp run(replies, opts \\ []) do
    {:ok, queue} = Agent.start_link(fn -> replies end)

    stream_fn = fn _model, _context, _options ->
      events = Agent.get_and_update(queue, fn [head | rest] -> {head, rest} end)
      {:ok, stream} = LemonAi.EventStream.start_link()
      Enum.each(events, &LemonAi.EventStream.push(stream, &1))
      LemonAi.EventStream.complete(stream, events |> List.last() |> elem(2))
      {:ok, stream}
    end

    config = %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      stream_fn: stream_fn,
      max_retries: 0
    }

    context = AgentContext.new(system_prompt: "Test", tools: [spawn_tool(self(), opts)])

    stream =
      Loop.agent_loop([Mocks.user_message("go")], context, config, opts[:signal], stream_fn)

    events = EventStream.events(stream) |> Enum.to_list()
    Agent.stop(queue)
    events
  end

  defp spawn_tool(parent, opts) do
    %AgentTool{
      name: "spawn",
      description: "Spawn",
      parameters: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}},
      execute: fn id, params, _signal, _on_update ->
        send(parent, {:observed, System.unique_integer([:monotonic]), {:executed, id, params}})
        %AgentToolResult{content: [%TextContent{text: "ok"}]}
      end,
      on_stream: fn event ->
        send(parent, {:observed, System.unique_integer([:monotonic]), {:stream, event}})

        case event do
          {:args, %{signal: signal}} -> if opts[:abort_on_args], do: AbortSignal.abort(signal)
          _ -> :ok
        end
      end
    }
  end

  # The callbacks run in the loop and tool processes; order them by the
  # monotonic stamp taken when each was observed.
  defp observed(acc \\ []) do
    receive do
      {:observed, at, observation} -> observed([{at, observation} | acc])
    after
      100 -> acc |> Enum.sort() |> Enum.map(&elem(&1, 1))
    end
  end

  defp streamed_call(id, chunks, arguments) do
    call = Mocks.tool_call("spawn", arguments, id: id)
    partial = Mocks.assistant_message_with_tool_calls([%{call | arguments: %{}}])
    final = Mocks.assistant_message_with_tool_calls([call])

    [{:start, %{partial | content: []}}, {:tool_call_start, 0, partial}] ++
      Enum.map(chunks, &{:tool_call_delta, 0, &1, partial}) ++
      [{:tool_call_end, 0, call, final}, {:done, :tool_use, final}]
  end

  defp reply(message), do: [{:done, message.stop_reason, message}]
end
