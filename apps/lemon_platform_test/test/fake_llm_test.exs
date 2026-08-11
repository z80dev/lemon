defmodule LemonPlatformTest.FakeLLMTest do
  @moduledoc """
  Self-validation for `LemonPlatformTest.FakeLLM`: every scripted step is driven
  through a *real* `LemonAgent.Loop`, the same code path a provider adapter feeds.
  If the push protocol drifts, these break.
  """
  use ExUnit.Case, async: true

  alias LemonAgent.{EventStream, Loop}
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.Types.{StreamOptions, TextContent, ToolCall, UserMessage}
  alias LemonPlatformTest.FakeLLM

  # convert_to_llm keeps the standard conversational roles; the loop hands the
  # result to the (fake) stream function, which ignores it.
  defp convert_to_llm do
    fn messages ->
      Enum.filter(messages, &(Map.get(&1, :role) in [:user, :assistant, :tool_result]))
    end
  end

  defp config(stream_fn) do
    %AgentLoopConfig{
      model: FakeLLM.model(),
      convert_to_llm: convert_to_llm(),
      stream_options: %StreamOptions{},
      max_tool_turns: 25,
      stream_fn: stream_fn
    }
  end

  defp user(text), do: %UserMessage{role: :user, content: text, timestamp: 0}

  defp run(stream_fn, context \\ AgentContext.new(system_prompt: "You are helpful.")) do
    stream = Loop.agent_loop([user("go")], context, config(stream_fn), nil, nil)
    {:ok, messages} = EventStream.result(stream)
    messages
  end

  defp assistant_text(messages) do
    messages
    |> Enum.filter(&(Map.get(&1, :role) == :assistant))
    |> Enum.flat_map(fn m -> m.content end)
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map_join(" ", & &1.text)
  end

  defp weather_tool(parent \\ nil) do
    %AgentTool{
      name: "get_weather",
      description: "Weather for a city",
      parameters: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      label: "Weather",
      execute: fn _id, %{"city" => city}, _signal, _on_update ->
        if parent, do: send(parent, {:tool_ran, city})

        %AgentToolResult{
          content: [%TextContent{type: :text, text: "sunny in #{city}"}],
          details: nil
        }
      end
    }
  end

  test "a plain text step drives the loop to a text answer" do
    messages = run(FakeLLM.script([{:text, "Hello there."}]))
    assert assistant_text(messages) == "Hello there."
  end

  test "a tool_call step runs the real tool, then the next step answers" do
    parent = self()
    context = AgentContext.new(system_prompt: "You are helpful.", tools: [weather_tool(parent)])

    stream_fn =
      FakeLLM.script([
        {:tool_call, "get_weather", %{"city" => "Paris"}},
        {:text, "It is sunny in Paris."}
      ])

    messages = run(stream_fn, context)

    assert_received {:tool_ran, "Paris"}
    assert assistant_text(messages) == "It is sunny in Paris."

    # The tool result the loop produced is in the transcript.
    tool_result = Enum.find(messages, &(Map.get(&1, :role) == :tool_result))
    assert tool_result
    assert Enum.any?(tool_result.content, &(&1.text =~ "sunny in Paris"))
  end

  test "multiple tool calls in one turn run as a batch" do
    parent = self()
    context = AgentContext.new(system_prompt: "You are helpful.", tools: [weather_tool(parent)])

    stream_fn =
      FakeLLM.script([
        {:tool_calls,
         [
           {"get_weather", %{"city" => "Paris"}},
           {"get_weather", %{"city" => "Tokyo"}}
         ]},
        {:text, "Both reported."}
      ])

    messages = run(stream_fn, context)

    assert_received {:tool_ran, "Paris"}
    assert_received {:tool_ran, "Tokyo"}

    results = Enum.filter(messages, &(Map.get(&1, :role) == :tool_result))
    assert length(results) == 2
    assert assistant_text(messages) == "Both reported."
  end

  test "a pinned ToolCall id flows through to the tool result" do
    context = AgentContext.new(system_prompt: "You are helpful.", tools: [weather_tool()])

    stream_fn =
      FakeLLM.script([
        {:tool_calls,
         [
           %ToolCall{
             type: :tool_call,
             id: "call_pinned",
             name: "get_weather",
             arguments: %{"city" => "Rome"}
           }
         ]},
        {:text, "done"}
      ])

    messages = run(stream_fn, context)
    tool_result = Enum.find(messages, &(Map.get(&1, :role) == :tool_result))
    assert tool_result.tool_call_id == "call_pinned"
  end

  test "a refusal produces an errored assistant turn, distinct from a transport error" do
    stream =
      Loop.agent_loop(
        [user("go")],
        AgentContext.new(system_prompt: "You are helpful."),
        config(FakeLLM.script([{:refusal, "I can't help with that."}])),
        nil,
        nil
      )

    # Unlike {:error, reason} (a transport failure with no message), a refusal
    # produced a real assistant turn; the loop reports it as :assistant_error and
    # carries the message in the partial state.
    assert {:error, {:assistant_error, "I can't help with that."}, %{new_messages: msgs}} =
             EventStream.result(stream)

    assistant = Enum.find(msgs, &(Map.get(&1, :role) == :assistant))
    assert assistant.stop_reason == :error
    assert assistant.error_message == "I can't help with that."
  end

  test "an error step propagates as the loop's error result" do
    stream =
      Loop.agent_loop(
        [user("go")],
        AgentContext.new(),
        config(FakeLLM.script([{:error, :rate_limited}])),
        nil,
        nil
      )

    assert {:error, :rate_limited, _partial} = EventStream.result(stream)
  end

  test "a verbatim AssistantMessage step is emitted unchanged" do
    msg = %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: "verbatim"}],
      stop_reason: :stop,
      model: "custom",
      timestamp: 0
    }

    messages = run(FakeLLM.script([msg]))
    assert assistant_text(messages) == "verbatim"
  end

  test "on_exhaust: :stop (default) lets an over-run loop end cleanly" do
    # Only a tool step is scripted; after the tool runs the loop asks for another
    # turn, which the terminal fallback satisfies so the run finishes with :ok.
    context = AgentContext.new(system_prompt: "You are helpful.", tools: [weather_tool()])
    stream_fn = FakeLLM.script([{:tool_call, "get_weather", %{"city" => "Oslo"}}])

    messages = run(stream_fn, context)
    assert Enum.any?(messages, &(Map.get(&1, :role) == :tool_result))
    assert assistant_text(messages) =~ "script exhausted"
  end

  test "on_exhaust: :raise is a function escape hatch, not a compile error" do
    stream_fn = FakeLLM.script([{:text, "one"}], on_exhaust: :raise)
    # First call is scripted and fine.
    assert {:ok, pid} = stream_fn.(FakeLLM.model(), %{}, %StreamOptions{})
    assert is_pid(pid)
    # Second call is past the end and raises.
    assert_raise RuntimeError, ~r/script exhausted/, fn ->
      stream_fn.(FakeLLM.model(), %{}, %StreamOptions{})
    end
  end
end
