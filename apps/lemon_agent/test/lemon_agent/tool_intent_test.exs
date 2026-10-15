defmodule LemonAgent.ToolIntentTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{EventStream, ToolIntent}
  alias LemonAgent.Loop.{Streaming, ToolCalls}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentToolResult}
  alias LemonAi.Providers.OpenAIResponsesShared

  @schema %{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"],
    "additionalProperties" => false
  }

  test "injection is optional, idempotent and preserves closed schemas" do
    injected = ToolIntent.schema(@schema)
    assert injected["properties"]["i"]["type"] == "string"
    assert injected["properties"]["i"]["description"] =~ "present-participle"
    assert injected["required"] == ["text"]
    assert injected["additionalProperties"] == false
    assert ToolIntent.schema(injected) == injected
    assert ToolIntent.schema(@schema, false) == @schema
  end

  test "native i parameters are neither replaced nor stripped" do
    schema = put_in(@schema, ["properties", "i"], %{"type" => "integer"})
    assert ToolIntent.schema(schema) == schema
    assert ToolIntent.extract(schema, %{"i" => 42}) == {nil, %{"i" => 42}}
  end

  test "closed union alternatives get intent without an incompatible root object" do
    for union <- ["anyOf", "oneOf"] do
      schema = %{union => [@schema, @schema]}
      injected = ToolIntent.schema(schema)
      refute Map.has_key?(injected, "properties")

      for variant <- injected[union] do
        assert variant["properties"]["i"]["type"] == "string"
        assert variant["required"] == ["text"]
        assert variant["additionalProperties"] == false
      end
    end
  end

  test "only strings become intent, but all presentation values are stripped" do
    for value <- [nil, 4, %{}, ["Reading settings"]] do
      assert ToolIntent.extract(@schema, %{"text" => "hello", "i" => value}) ==
               {nil, %{"text" => "hello"}}
    end
  end

  test "JSON object arguments are decoded before intent extraction and coercion" do
    arguments = %{"text" => "hello", "i" => "Reading model settings"}

    assert ToolIntent.extract(@schema, Jason.encode!(arguments)) ==
             {"Reading model settings", %{"text" => "hello"}}

    assert ToolIntent.extract(@schema, "not json") == {nil, "not json"}
  end

  test "provider schemas honor loop config and leave execution schemas untouched" do
    parent = self()
    tool = %{Mocks.echo_tool() | parameters: @schema}

    stream_fn = fn _, context, _ ->
      send(parent, {:provider_tools, context.tools})
      message = Mocks.assistant_message("done")
      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.complete(stream, message)
      {:ok, stream}
    end

    for enabled <- [true, false] do
      {:ok, stream} = EventStream.start_link(timeout: :infinity)
      context = AgentContext.new(tools: [tool], messages: [Mocks.user_message("hello")])

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        intent_tracing: enabled
      }

      assert {:ok, _, updated} =
               Streaming.stream_assistant_response(context, config, nil, stream_fn, stream)

      assert_receive {:provider_tools, [provider_tool]}
      assert Map.has_key?(provider_tool.parameters["properties"], "i") == enabled
      assert provider_tool.parameters["required"] == ["text"]
      assert hd(updated.tools).parameters == @schema
      [wire_tool] = OpenAIResponsesShared.convert_tools([provider_tool])
      assert wire_tool["strict"] == false
      assert wire_tool["parameters"]["required"] == ["text"]
      assert wire_tool["parameters"]["additionalProperties"] == false
      EventStream.complete(stream, [])
    end
  end

  test "closed tool receives clean arguments while start events and history retain intent" do
    parent = self()
    intent = "Reading model role settings. "
    arguments = %{"text" => "hello", "i" => intent}
    call = Mocks.tool_call("echo", arguments)
    message = Mocks.assistant_message_with_tool_calls([call])

    tool = %{
      Mocks.echo_tool()
      | parameters: @schema,
        execute: fn _, args, _, _ ->
          send(parent, {:executed, args, ToolIntent.current()})
          %AgentToolResult{content: []}
        end
    }

    {:ok, stream} = EventStream.start_link(timeout: :infinity)
    context = AgentContext.new(tools: [tool], messages: [message])

    {[result], [], updated, [^message, _result]} =
      ToolCalls.execute_and_collect_tools(
        context,
        [message],
        [call],
        %AgentLoopConfig{},
        nil,
        stream
      )

    refute result.is_error
    assert_receive {:executed, %{"text" => "hello"}, ^intent}
    assert hd(updated.messages) == message
    assert ToolIntent.current() == nil
    EventStream.complete(stream, [])
    events = Enum.to_list(EventStream.events(stream))
    assert {:tool_execution_start, call.id, "echo", arguments} in events
  end

  test "omitting intent still executes a closed tool" do
    call = Mocks.tool_call("echo", %{"text" => "hello"})
    tool = %{Mocks.echo_tool() | parameters: @schema}
    context = AgentContext.new(tools: [tool])
    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {[result], _, _, _} =
      ToolCalls.execute_and_collect_tools(context, [], [call], %AgentLoopConfig{}, nil, stream)

    refute result.is_error
    EventStream.complete(stream, [])
  end
end
