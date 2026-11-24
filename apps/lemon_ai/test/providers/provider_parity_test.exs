defmodule LemonAi.Providers.ProviderParityTest do
  use ExUnit.Case, async: true

  alias LemonAi.{EventStream, Providers.OpenAIResponsesShared, Providers.StreamTransport}
  alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, Usage}

  test "parallel tool argument streams route by item ID and authoritative final arguments" do
    {:ok, stream} = EventStream.start_link()
    first = %{"type" => "function_call", "id" => "fc_a", "call_id" => "call_a", "name" => "read"}
    second = %{"type" => "function_call", "id" => "fc_b", "call_id" => "call_b", "name" => "read"}

    events = [
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => first},
      %{"type" => "response.output_item.added", "output_index" => 1, "item" => second},
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_a",
        "delta" => "{\"path\":\"a\"}"
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_b",
        "delta" => "{\"path\":\"b\"}"
      },
      %{
        "type" => "response.output_item.done",
        "item" => Map.put(first, "arguments", "{\"path\":\"authoritative-a\"}")
      },
      %{
        "type" => "response.output_item.done",
        "item" => Map.put(second, "arguments", "{\"path\":\"b\"}")
      },
      %{"type" => "response.completed", "response" => %{"status" => "completed"}}
    ]

    assert {:ok, result} =
             OpenAIResponsesShared.process_stream(events, %AssistantMessage{}, stream, %Model{
               provider: :openai
             })

    assert [a, b] = result.content
    assert a.arguments == %{"path" => "authoritative-a"}
    assert b.arguments == %{"path" => "b"}
    assert result.stop_reason == :tool_use
    EventStream.cancel(stream, :test_cleanup)
  end

  test "malformed final tool arguments are not repaired into executable empty arguments" do
    {:ok, stream} = EventStream.start_link()

    item = %{
      "type" => "function_call",
      "id" => "fc_bad",
      "call_id" => "call_bad",
      "name" => "write"
    }

    events = [
      %{"type" => "response.output_item.added", "item" => item},
      %{"type" => "response.output_item.done", "item" => Map.put(item, "arguments", "{\"path\":")}
    ]

    assert {:error, message} =
             OpenAIResponsesShared.process_stream(events, %AssistantMessage{}, stream, %Model{
               provider: :openai
             })

    assert message =~ "Invalid tool arguments"
    EventStream.cancel(stream, :test_cleanup)
  end

  test "SSE decodes CRLF, multiline data and fragmented UTF-8 without consuming another response" do
    ref = make_ref()
    other = make_ref()

    response = %Req.Response{
      body: %Req.Response.Async{
        ref: ref,
        stream_fun: fn ^ref, {^ref, part} -> {:ok, [part]} end,
        cancel_fun: fn ^ref -> :ok end
      }
    }

    send(self(), {other, {:data, "unrelated"}})

    payload =
      "data: {\r\ndata: \"type\": \"response.completed\",\r\ndata: \"text\": \"café\"}\r\n\r\n"

    {position, _} = :binary.match(payload, "é")
    split = position + 1
    <<first::binary-size(^split), rest::binary>> = payload
    send(self(), {ref, {:data, first}})
    send(self(), {ref, {:data, rest}})
    send(self(), {ref, :done})

    assert [%{"type" => "response.completed", "text" => "café"}] =
             Enum.to_list(StreamTransport.sse_events(response, 100))

    assert_received {^other, {:data, "unrelated"}}
  end

  test "SSE flushes a final frame at EOF and reports timeouts" do
    ref = make_ref()

    response = %Req.Response{
      body: %Req.Response.Async{
        ref: ref,
        stream_fun: fn ^ref, {^ref, part} -> {:ok, [part]} end,
        cancel_fun: fn ^ref -> :ok end
      }
    }

    send(self(), {ref, {:data, "data: {\"type\":\"response.completed\"}"}})
    send(self(), {ref, :done})

    assert [%{"type" => "response.completed"}] =
             Enum.to_list(StreamTransport.sse_events(response, 100))

    assert [{:stream_error, %{category: :transient, retryable: true}}] =
             Enum.to_list(StreamTransport.sse_events(response, 1))
  end

  test "Responses does not report a disconnected generation as successful" do
    {:ok, stream} = EventStream.start_link()

    assert {:error, %{category: :transient, retryable: true, message: message}} =
             OpenAIResponsesShared.process_stream([], %AssistantMessage{}, stream, %Model{})

    assert message =~ "closed before the response completed"
    EventStream.cancel(stream, :test_cleanup)
  end

  test "incomplete Responses preserve cache usage and synthesize omitted total tokens" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{
        "type" => "response.incomplete",
        "response" => %{
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"},
          "usage" => %{
            "input_tokens" => 100,
            "prompt_cache_hit_tokens" => 80,
            "output_tokens" => 25
          }
        }
      }
    ]

    model = %Model{cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 0.2}}

    assert {:ok, result} =
             OpenAIResponsesShared.process_stream(events, %AssistantMessage{}, stream, model)

    assert result.stop_reason == :length
    assert %Usage{input: 20, output: 25, cache_read: 80, total_tokens: 125} = result.usage
    assert_in_delta result.usage.cost.total, 0.000306, 1.0e-10
    EventStream.cancel(stream, :test_cleanup)
  end

  test "long-context pricing uses all input tokens and hourly writes remain a subset" do
    model = %Model{
      cost: %ModelCost{
        input: 2,
        output: 10,
        cache_read: 0.2,
        cache_write: 2.5,
        long_context: %{
          input_threshold: 100,
          input: 4,
          output: 15,
          cache_read: 0.4,
          cache_write: 5
        }
      }
    }

    usage = %Usage{input: 20, output: 10, cache_read: 60, cache_write: 30, cache_write_long: 10}
    cost = LemonAi.calculate_cost(model, usage)
    assert_in_delta cost.input, 0.00008, 1.0e-10
    assert_in_delta cost.output, 0.00015, 1.0e-10
    assert_in_delta cost.cache_read, 0.000024, 1.0e-10
    assert_in_delta cost.cache_write, 0.00018, 1.0e-10
  end

  test "Codex service tiers use model-specific multipliers" do
    usage = %Usage{cost: %Cost{input: 1, output: 2, cache_read: 0.5, total: 3.5}}

    priced =
      OpenAIResponsesShared.apply_service_tier_pricing(usage, "priority", %{"priority" => 2.5})

    assert priced.cost.total == 8.75

    assert OpenAIResponsesShared.apply_service_tier_pricing(usage, "default", %{"priority" => 2.5}) ==
             usage
  end
end
