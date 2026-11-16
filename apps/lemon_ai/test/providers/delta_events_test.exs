defmodule LemonAi.Providers.DeltaEventsTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, StreamAccumulator}
  alias LemonAi.Providers

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Model,
    ModelCost,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall,
    UserMessage
  }

  @arguments %{"path" => "a\"b\\c.txt", "size" => 7}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  for {provider, family} <- [
        {Providers.Anthropic, :anthropic},
        {Providers.OpenAICompletions, :completions},
        {Providers.MistralConversations, :completions},
        {Providers.OpenAIResponses, :responses},
        {Providers.OpenAICodexResponses, :responses},
        {Providers.AzureOpenAIResponses, :responses},
        {Providers.Google, :google},
        {Providers.GoogleVertex, :google},
        {Providers.GoogleGeminiCli, :google},
        {Providers.Bedrock, :bedrock}
      ] do
    @provider provider
    @family family

    test "#{inspect(provider)} streams only deltas and retains identical final content" do
      body = response_body(@family, @provider)
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      context = Context.new(messages: [%UserMessage{content: "Use the lookup tool."}])

      assert {:ok, stream} = @provider.stream(model(@provider), context, options(@provider))
      assert {:ok, final} = EventStream.result(stream, 2_000)
      events = Enum.to_list(EventStream.events(stream))
      assert [{:start, %AssistantMessage{}} | _] = events
      assert {:done, :tool_use, ^final} = List.last(events)
      assert_delta_contract(events)

      assert Enum.any?(events, &match?({:tool_call_start, _, %ToolCall{name: "lookup"}}, &1))

      assert [
               %ThinkingContent{thinking: "Plan carefully"} = thinking,
               %TextContent{text: "Hello, world!"},
               %ToolCall{name: "lookup", arguments: @arguments} = call
             ] = final.content

      assert is_binary(call.id) and call.id != ""

      case @family do
        :responses ->
          assert Jason.decode!(thinking.thinking_signature) == %{
                   "type" => "reasoning",
                   "id" => "rs_fixture",
                   "summary" => [%{"text" => "Plan carefully"}]
                 }

        :completions ->
          assert thinking.thinking_signature == "reasoning_content"

        _ ->
          assert thinking.thinking_signature == "signed-thinking"
      end

      {:tool_call_start, 2, started_call} =
        Enum.find(events, &match?({:tool_call_start, 2, _}, &1))

      assert started_call.id == call.id
      assert started_call.name == call.name
      assert started_call.arguments == %{}

      before_terminal = Enum.drop(events, -1)

      accumulated =
        Enum.reduce(
          before_terminal,
          StreamAccumulator.new(%AssistantMessage{}),
          &StreamAccumulator.apply(&2, &1)
        )

      partial = StreamAccumulator.snapshot(accumulated)
      assert Enum.map(partial.content, &rendered/1) == Enum.map(final.content, &rendered/1)

      raw_arguments = for {:tool_call_delta, 2, delta} <- events, into: "", do: delta
      assert Jason.decode!(raw_arguments) == @arguments
      assert {:tool_call_end, 2, call} in events
      GenServer.stop(stream)
    end
  end

  test "Anthropic starts with initial text and thinking without losing either delta" do
    body =
      sse([
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "thinking",
            "thinking" => "Initial",
            "signature" => "signed"
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => " thought"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{"type" => "text", "text" => "Hello"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => " world"}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
      ])

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} =
      Providers.Anthropic.stream(
        model(Providers.Anthropic),
        context,
        options(Providers.Anthropic)
      )

    assert {:ok, final} = EventStream.result(stream, 2_000)
    events = Enum.to_list(EventStream.events(stream))
    assert_delta_contract(events)
    assert {:thinking_delta, 0, "Initial"} in events
    assert {:text_delta, 1, "Hello"} in events

    assert [
             %ThinkingContent{thinking: "Initial thought", thinking_signature: "signed"},
             %TextContent{text: "Hello world"}
           ] = final.content

    GenServer.stop(stream)
  end

  test "Anthropic errors retain buffered tool arguments in the terminal message" do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "call_fixture", "name" => "lookup"}
      }
    ]

    deltas =
      Enum.map(argument_chunks(), fn chunk ->
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => chunk}
        }
      end)

    body =
      sse(events ++ deltas ++ [%{"type" => "error", "error" => %{"message" => "failed"}}])

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} =
      Providers.Anthropic.stream(
        model(Providers.Anthropic),
        context,
        options(Providers.Anthropic)
      )

    assert {:error, final} = EventStream.result(stream, 2_000)
    assert [%ToolCall{arguments: @arguments}] = final.content
    emitted = Enum.to_list(EventStream.events(stream))
    assert_delta_contract(emitted)
    assert {:error, :error, final} == List.last(emitted)
    GenServer.stop(stream)
  end

  test "Responses reconstructs tool arguments when no authoritative final input is supplied" do
    {:ok, stream} = EventStream.start_link()
    item = %{"type" => "function_call", "id" => "fc", "call_id" => "call", "name" => "lookup"}

    events =
      [%{"type" => "response.output_item.added", "item" => item}] ++
        Enum.map(argument_chunks(), fn chunk ->
          %{"type" => "response.function_call_arguments.delta", "delta" => chunk}
        end) ++
        [
          %{"type" => "response.output_item.done", "item" => item},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]

    assert {:ok, final} =
             Providers.OpenAIResponsesShared.process_stream(
               events,
               %AssistantMessage{},
               stream,
               model(Providers.OpenAIResponses)
             )

    assert [%ToolCall{arguments: @arguments}] = final.content
    EventStream.complete(stream, final)
    assert_delta_contract(Enum.to_list(EventStream.events(stream)))
    GenServer.stop(stream)
  end

  defp assert_delta_contract(events) do
    Enum.each(events, fn
      {:start, %AssistantMessage{}} ->
        :ok

      {:done, _, %AssistantMessage{}} ->
        :ok

      {:error, _, %AssistantMessage{}} ->
        :ok

      {kind, index} when kind in [:text_start, :thinking_start] and is_integer(index) ->
        :ok

      {kind, index, text}
      when kind in [:text_delta, :thinking_delta, :tool_call_delta, :text_end, :thinking_end] and
             is_integer(index) and is_binary(text) ->
        :ok

      {kind, index, %ToolCall{id: id, name: name}}
      when kind in [:tool_call_start, :tool_call_end] and is_integer(index) and is_binary(id) and
             is_binary(name) ->
        :ok

      event ->
        flunk("Unexpected provider event: #{inspect(event)}")
    end)
  end

  defp rendered(%TextContent{text: text}), do: {:text, text}
  defp rendered(%ThinkingContent{thinking: text}), do: {:thinking, text}
  defp rendered(%ToolCall{} = call), do: call

  defp model(provider) do
    %Model{
      id: model_id(provider),
      name: "Delta contract fixture",
      api: provider.api_id(),
      provider: provider.provider_id(),
      base_url: "https://example.test",
      max_tokens: 8_192,
      cost: %ModelCost{}
    }
  end

  defp model_id(Providers.Anthropic), do: "claude-sonnet-4-5"
  defp model_id(Providers.Bedrock), do: "anthropic.claude-3-5-haiku-20241022-v1:0"

  defp model_id(provider)
       when provider in [Providers.Google, Providers.GoogleVertex, Providers.GoogleGeminiCli],
       do: "gemini-2.5-pro"

  defp model_id(_), do: "gpt-4o"

  defp options(Providers.GoogleVertex),
    do: %StreamOptions{
      access_token: "fixture-token",
      project: "fixture-project",
      location: "us-central1"
    }

  defp options(Providers.GoogleGeminiCli),
    do: %StreamOptions{
      api_key: Jason.encode!(%{"token" => "fixture-token", "projectId" => "fixture-project"})
    }

  defp options(Providers.OpenAICodexResponses) do
    payload =
      Jason.encode!(%{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => "fixture-account"}
      })

    %StreamOptions{api_key: "header." <> Base.encode64(payload) <> ".signature"}
  end

  defp options(Providers.Bedrock),
    do: %StreamOptions{
      headers: %{
        "aws_access_key_id" => "fixture-access",
        "aws_secret_access_key" => "fixture-secret",
        "aws_region" => "us-east-1"
      }
    }

  defp options(_), do: %StreamOptions{api_key: "fixture-key"}

  defp response_body(:anthropic, _) do
    sse(
      [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Plan "}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "carefully"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => "signed-thinking"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "Hello, "}
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "world!"}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{
          "type" => "content_block_start",
          "index" => 2,
          "content_block" => %{"type" => "tool_use", "id" => "call_fixture", "name" => "lookup"}
        }
      ] ++
        Enum.map(argument_chunks(), fn chunk ->
          %{
            "type" => "content_block_delta",
            "index" => 2,
            "delta" => %{"type" => "input_json_delta", "partial_json" => chunk}
          }
        end) ++
        [
          %{"type" => "content_block_stop", "index" => 2},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}}
        ]
    )
  end

  defp response_body(:completions, _) do
    deltas =
      [
        %{"reasoning_content" => "Plan "},
        %{"reasoning_content" => "carefully"},
        %{"content" => "Hello, "},
        %{"content" => "world!"},
        %{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_fixture",
              "function" => %{"name" => "lookup", "arguments" => ""}
            }
          ]
        }
      ] ++
        Enum.map(argument_chunks(), fn chunk ->
          %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => chunk}}]}
        end)

    events = Enum.map(deltas, &%{"choices" => [%{"delta" => &1}]})

    sse(events ++ [%{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}]) <>
      "data: [DONE]\n\n"
  end

  defp response_body(:responses, _) do
    thinking = %{"type" => "reasoning", "id" => "rs_fixture"}
    text = %{"type" => "message", "id" => "msg_fixture"}

    tool = %{
      "type" => "function_call",
      "id" => "fc_fixture",
      "call_id" => "call_fixture",
      "name" => "lookup"
    }

    sse(
      [
        %{"type" => "response.output_item.added", "item" => thinking},
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "Plan "},
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "carefully"},
        %{
          "type" => "response.output_item.done",
          "item" => Map.put(thinking, "summary", [%{"text" => "Plan carefully"}])
        },
        %{"type" => "response.output_item.added", "item" => text},
        %{"type" => "response.output_text.delta", "delta" => "Hello, "},
        %{"type" => "response.output_text.delta", "delta" => "world!"},
        %{
          "type" => "response.output_item.done",
          "item" =>
            Map.put(text, "content", [%{"type" => "output_text", "text" => "Hello, world!"}])
        },
        %{"type" => "response.output_item.added", "item" => tool}
      ] ++
        Enum.map(
          argument_chunks(),
          &%{"type" => "response.function_call_arguments.delta", "delta" => &1}
        ) ++
        [
          %{
            "type" => "response.function_call_arguments.done",
            "arguments" => Jason.encode!(@arguments)
          },
          %{
            "type" => "response.output_item.done",
            "item" => Map.put(tool, "arguments", Jason.encode!(@arguments))
          },
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
    )
  end

  defp response_body(:google, provider) do
    parts = [
      %{"text" => "Plan ", "thought" => true, "thoughtSignature" => "signed-thinking"},
      %{"text" => "carefully", "thought" => true},
      %{"text" => "Hello, "},
      %{"text" => "world!"},
      %{
        "functionCall" => %{"id" => "call_fixture", "name" => "lookup", "args" => @arguments},
        "thoughtSignature" => "signed-tool"
      }
    ]

    events =
      Enum.map(parts, &%{"candidates" => [%{"content" => %{"parts" => [&1]}}]}) ++
        [%{"candidates" => [%{"finishReason" => "STOP"}]}]

    events =
      if provider == Providers.GoogleGeminiCli,
        do: Enum.map(events, &%{"response" => &1}),
        else: events

    sse(events)
  end

  defp response_body(:bedrock, _) do
    events =
      [
        {"contentBlockDelta",
         %{
           "contentBlockIndex" => 0,
           "delta" => %{
             "reasoningContent" => %{"text" => "Plan ", "signature" => "signed-thinking"}
           }
         }},
        {"contentBlockDelta",
         %{"contentBlockIndex" => 0, "delta" => %{"reasoningContent" => %{"text" => "carefully"}}}},
        {"contentBlockStop", %{"contentBlockIndex" => 0}},
        {"contentBlockDelta", %{"contentBlockIndex" => 1, "delta" => %{"text" => "Hello, "}}},
        {"contentBlockDelta", %{"contentBlockIndex" => 1, "delta" => %{"text" => "world!"}}},
        {"contentBlockStop", %{"contentBlockIndex" => 1}},
        {"contentBlockStart",
         %{
           "contentBlockIndex" => 2,
           "start" => %{"toolUse" => %{"toolUseId" => "call_fixture", "name" => "lookup"}}
         }}
      ] ++
        Enum.map(
          argument_chunks(),
          &{"contentBlockDelta",
           %{"contentBlockIndex" => 2, "delta" => %{"toolUse" => %{"input" => &1}}}}
        ) ++
        [
          {"contentBlockStop", %{"contentBlockIndex" => 2}},
          {"messageStop", %{"stopReason" => "tool_use"}}
        ]

    events |> Enum.map(&bedrock_frame/1) |> IO.iodata_to_binary()
  end

  defp bedrock_frame({type, payload}) do
    headers =
      Enum.map_join([{":message-type", "event"}, {":event-type", type}], fn {name, value} ->
        <<byte_size(name)::8, name::binary, 7::8, byte_size(value)::16, value::binary>>
      end)

    payload = Jason.encode!(payload)
    prelude = <<16 + byte_size(headers) + byte_size(payload)::32, byte_size(headers)::32>>
    frame = prelude <> <<:erlang.crc32(prelude)::32>> <> headers <> payload
    frame <> <<:erlang.crc32(frame)::32>>
  end

  defp argument_chunks do
    json = Jason.encode!(@arguments)
    for <<chunk::binary-size(1) <- json>>, do: chunk
  end

  defp sse(events), do: Enum.map_join(events, &("data: " <> Jason.encode!(&1) <> "\n\n"))
end
