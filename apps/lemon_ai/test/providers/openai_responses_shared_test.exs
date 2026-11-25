defmodule LemonAi.Providers.OpenAIResponsesSharedTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias LemonAi.EventStream
  alias LemonAi.Providers.OpenAIResponsesShared

  alias LemonAi.Types.{
    AssistantMessage,
    Cost,
    ImageContent,
    Model,
    ModelCost,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  @soft_function_call_output_bytes 65_536

  test "process_stream catches thrown stream errors" do
    events = Stream.map([:error], fn _ -> throw({:stream_error, "boom"}) end)
    assert {:error, "boom"} = process_events(events)
  end

  test "process_stream reports provider error payloads" do
    for {event, error} <- [
          {%{
             "type" => "error",
             "code" => "rate_limit_exceeded",
             "message" => "Too many requests"
           }, "Error Code rate_limit_exceeded: Too many requests"},
          {%{"type" => "error", "code" => "unknown_error", "message" => nil},
           "Error Code unknown_error: Unknown error"},
          {%{
             "type" => "response.failed",
             "response" => %{"error" => %{"message" => "Quota exceeded"}}
           }, "Quota exceeded"}
        ] do
      assert {:error, ^error} = process_events([event])
    end
  end

  test "adds synthetic tool results for trailing tool calls" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    tool_call = %ToolCall{id: "call_1|fc_1", name: "tool_a", arguments: %{}}

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    messages =
      OpenAIResponsesShared.transform_messages(
        [assistant],
        model,
        MapSet.new([:openai])
      )

    assert length(messages) == 2
    assert [%AssistantMessage{}, %ToolResultMessage{}] = messages
    assert %ToolResultMessage{tool_call_id: "call_1|fc_1", is_error: true} = List.last(messages)
  end

  test "does not add synthetic tool results when tool output exists" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    tool_call = %ToolCall{id: "call_1|fc_1", name: "tool_a", arguments: %{}}

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    tool_result = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_1|fc_1",
      tool_name: "tool_a",
      content: [],
      is_error: false,
      timestamp: System.system_time(:millisecond)
    }

    messages =
      OpenAIResponsesShared.transform_messages(
        [assistant, tool_result],
        model,
        MapSet.new([:openai])
      )

    assert length(messages) == 2
    assert [%AssistantMessage{}, %ToolResultMessage{}] = messages
    assert %ToolResultMessage{tool_call_id: "call_1|fc_1", is_error: false} = List.last(messages)
  end

  test "clamps cached tokens to avoid negative input usage" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "usage" => %{
            "input_tokens" => 5,
            "output_tokens" => 1,
            "total_tokens" => 6,
            "input_tokens_details" => %{"cached_tokens" => 10}
          }
        }
      }
    ]

    output = %AssistantMessage{
      role: :assistant,
      content: [],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{input: 1.0, output: 1.0, cache_read: 1.0, cache_write: 1.0}
    }

    assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
    assert final.usage.input == 0
    assert final.usage.cache_read == 10

    EventStream.cancel(stream, :test_cleanup)
  end

  test "accounts for mixed cache-write lifetimes before long-context and service-tier pricing" do
    {:ok, stream} = EventStream.start_link()

    model = %Model{
      id: "cache-write-model",
      api: :openai_responses,
      provider: :openai,
      cost: %ModelCost{
        input: 1.0,
        output: 5.0,
        cache_read: 0.05,
        cache_write: 1.25,
        long_context: %{
          input_threshold: 10_000,
          input: 2.0,
          output: 7.5,
          cache_read: 0.1,
          cache_write: 2.5
        }
      }
    }

    events = [
      %{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "service_tier" => "ultrafast",
          "usage" => %{
            "input_tokens" => 12_000,
            "output_tokens" => 100,
            "input_tokens_details" => %{
              "cached_tokens" => 4_000,
              "cache_write_tokens" => 7_000,
              "cache_write_tokens_details" => %{
                "ttl_30m_tokens" => 3_000,
                "ttl_12h_tokens" => 4_000
              }
            }
          }
        }
      }
    ]

    output = %AssistantMessage{content: [], usage: %Usage{cost: %Cost{}}}

    opts = %{
      apply_service_tier_pricing: fn usage, tier ->
        OpenAIResponsesShared.apply_service_tier_pricing(usage, tier, %{"ultrafast" => 6.0})
      end
    }

    assert {:ok, final} =
             OpenAIResponsesShared.process_stream(events, output, stream, model, opts)

    assert final.usage.input == 1_000
    assert final.usage.cache_read == 4_000
    assert final.usage.cache_write == 7_000
    assert final.usage.total_tokens == 12_100
    assert_in_delta final.usage.cost.input, 0.012, 0.000001
    assert_in_delta final.usage.cost.cache_read, 0.0024, 0.000001
    assert_in_delta final.usage.cost.cache_write, 0.165, 0.000001
    assert_in_delta final.usage.cost.output, 0.0045, 0.000001
    assert_in_delta final.usage.cost.total, 0.1839, 0.000001

    EventStream.cancel(stream, :test_cleanup)
  end

  test "cache-write totals without lifetime details use the standard write rate" do
    {:ok, stream} = EventStream.start_link()
    model = %Model{cost: %ModelCost{input: 1.0, cache_write: 1.25}}
    output = %AssistantMessage{content: [], usage: %Usage{cost: %Cost{}}}

    events = [
      %{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "usage" => %{
            "input_tokens" => 1_000,
            "input_tokens_details" => %{"cache_write_tokens" => 1_000}
          }
        }
      }
    ]

    assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
    assert final.usage.input == 0
    assert final.usage.cache_write == 1_000
    assert_in_delta final.usage.cost.cache_write, 0.00125, 0.000001
    EventStream.cancel(stream, :test_cleanup)
  end

  test "uses the configured service-tier multiplier and defaults to the standard price" do
    for {tier, multiplier} <- [
          {"flex", 0.5},
          {"priority", 2.0},
          {"fast", 2.0},
          {"auto", 1.0},
          {"default", 1.0},
          {"unknown", 1.0},
          {nil, 1.0}
        ] do
      assert OpenAIResponsesShared.service_tier_cost_multiplier(tier) == multiplier
    end

    assert OpenAIResponsesShared.service_tier_cost_multiplier("fast", %{"priority" => 2.5}) == 2.5
  end

  test "convert_messages sanitizes invalid utf8 in system and user content" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    invalid_system = <<"system", 0xED, 0xA0, 0x80>>
    invalid_user = <<"user", 0xED, 0xB0, 0x80>>

    context =
      %LemonAi.Types.Context{
        system_prompt: invalid_system,
        messages: [%UserMessage{content: invalid_user}]
      }

    messages = OpenAIResponsesShared.convert_messages(model, context, MapSet.new([:openai]))

    assert [
             %{"role" => "system", "content" => system_content},
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => user_content}]
             }
           ] = messages

    assert String.valid?(system_content)
    assert String.valid?(user_content)
    assert String.starts_with?(system_content, "system")
    assert String.starts_with?(user_content, "user")
  end

  test "convert_messages sanitizes invalid utf8 in assistant tool call arguments" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    invalid_utf8 = <<"ok", 0xED, 0xA0, 0x80>>

    tool_call = %ToolCall{
      id: "call_1|fc_1",
      name: "echo",
      arguments: %{"items" => [%{"text" => invalid_utf8}]}
    }

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }

    [converted | _] =
      OpenAIResponsesShared.convert_messages(
        model,
        %LemonAi.Types.Context{system_prompt: nil, messages: [assistant]},
        MapSet.new([:openai])
      )

    assert %{"items" => [%{"text" => sanitized_text}]} = Jason.decode!(converted["arguments"])
    assert String.starts_with?(sanitized_text, "ok")
    assert String.valid?(sanitized_text)
  end

  test "convert_messages sanitizes invalid utf8 in assistant tool call identity fields" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    invalid_utf8 = <<0xED, 0xA0, 0x80>>

    tool_call = %ToolCall{
      id: "call_#{invalid_utf8}|fc_#{invalid_utf8}",
      name: "echo_#{invalid_utf8}",
      arguments: %{}
    }

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }

    [converted, synthetic_output] =
      OpenAIResponsesShared.convert_messages(
        model,
        %LemonAi.Types.Context{system_prompt: nil, messages: [assistant]},
        MapSet.new([:openai])
      )

    assert String.starts_with?(converted["call_id"], "call_")
    assert String.starts_with?(converted["id"], "fc_")
    assert String.starts_with?(converted["name"], "echo_")
    assert String.valid?(converted["call_id"])
    assert String.valid?(converted["id"])
    assert String.valid?(converted["name"])
    assert String.valid?(synthetic_output["call_id"])
  end

  test "convert_messages uses developer role for reasoning models" do
    model = %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      cost: %ModelCost{}
    }

    context = %LemonAi.Types.Context{system_prompt: "System", messages: []}

    messages = OpenAIResponsesShared.convert_messages(model, context, MapSet.new([:openai]))

    assert [%{"role" => "developer"}] = messages
  end

  test "convert_messages filters unsupported images" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{}
    }

    image = %ImageContent{data: "AA==", mime_type: "image/png"}

    context = %LemonAi.Types.Context{
      system_prompt: nil,
      messages: [%UserMessage{content: [image]}]
    }

    messages = OpenAIResponsesShared.convert_messages(model, context, MapSet.new([:openai]))

    assert messages == []
  end

  test "convert_tools honors strict option" do
    tools = [
      %LemonAi.Types.Tool{name: "tool_a", description: "A", parameters: %{"type" => "object"}}
    ]

    [tool_nil] = OpenAIResponsesShared.convert_tools(tools, %{strict: nil})
    refute Map.has_key?(tool_nil, "strict")

    [tool_true] = OpenAIResponsesShared.convert_tools(tools, %{strict: true})
    assert tool_true["strict"] == true

    [tool_false] = OpenAIResponsesShared.convert_tools(tools, %{strict: false})
    assert tool_false["strict"] == false
  end

  test "convert_tools sanitizes invalid utf8 in schema fields" do
    invalid_utf8 = <<0xED, 0xA0, 0x80>>

    tools = [
      %LemonAi.Types.Tool{
        name: "tool_#{invalid_utf8}",
        description: "desc_#{invalid_utf8}",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "field_#{invalid_utf8}" => %{"description" => "value_#{invalid_utf8}"}
          }
        }
      }
    ]

    [tool] = OpenAIResponsesShared.convert_tools(tools)

    assert String.starts_with?(tool["name"], "tool_")
    assert String.starts_with?(tool["description"], "desc_")
    assert String.valid?(tool["name"])
    assert String.valid?(tool["description"])
    assert Jason.encode!(tool["parameters"])
  end

  test "normalizes tool call ids across different models" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    tool_call = %ToolCall{id: "call 1|item 1", name: "tool_a", arguments: %{}}

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_responses,
      provider: :openai,
      model: "different-model",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    [updated | _] =
      OpenAIResponsesShared.transform_messages(
        [assistant],
        model,
        MapSet.new([:openai])
      )

    [%ToolCall{id: normalized_id}] = updated.content
    assert String.contains?(normalized_id, "|")
    [call_id, item_id] = String.split(normalized_id, "|")
    assert call_id == "call_1"
    assert String.starts_with?(item_id, "fc_")
  end

  test "convert_messages adds follow-up user image for tool results" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      input: [:text, :image],
      cost: %ModelCost{}
    }

    tool_result = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_1|fc_1",
      tool_name: "tool_a",
      content: [
        %TextContent{text: "ok"},
        %ImageContent{data: "AA==", mime_type: "image/png"}
      ],
      is_error: false,
      timestamp: System.system_time(:millisecond)
    }

    context = %LemonAi.Types.Context{system_prompt: nil, messages: [tool_result]}

    messages = OpenAIResponsesShared.convert_messages(model, context, MapSet.new([:openai]))

    assert length(messages) == 2
    assert Enum.any?(messages, &(&1["type"] == "function_call_output"))
    assert Enum.any?(messages, &(&1["role"] == "user"))
  end

  test "convert_messages truncates oversized function_call_output to API limit" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      input: [:text],
      cost: %ModelCost{}
    }

    oversized = String.duplicate("a", @soft_function_call_output_bytes + 1)

    tool_result = %ToolResultMessage{
      role: :tool_result,
      tool_call_id: "call_big|fc_1",
      tool_name: "tool_big",
      content: [%TextContent{text: oversized}],
      is_error: false,
      timestamp: System.system_time(:millisecond)
    }

    context = %LemonAi.Types.Context{system_prompt: nil, messages: [tool_result]}

    log =
      capture_log(fn ->
        messages = OpenAIResponsesShared.convert_messages(model, context, MapSet.new([:openai]))

        [output] = Enum.filter(messages, &(&1["type"] == "function_call_output"))
        assert output["call_id"] == "call_big"
        assert byte_size(output["output"]) == @soft_function_call_output_bytes
        assert output["output"] == binary_part(oversized, 0, @soft_function_call_output_bytes)
      end)

    assert log =~ "function_call_output truncated"
  end

  test "clamp_function_call_outputs truncates oversized payload items" do
    oversized = String.duplicate("b", @soft_function_call_output_bytes + 25)

    params = %{
      "model" => "gpt-5.3-codex",
      "input" => [
        %{"type" => "function_call_output", "call_id" => "call_big", "output" => oversized},
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}
      ]
    }

    clamped = OpenAIResponsesShared.clamp_function_call_outputs(params)
    [first, second] = clamped["input"]

    assert first["type"] == "function_call_output"
    assert first["call_id"] == "call_big"
    assert byte_size(first["output"]) == @soft_function_call_output_bytes
    assert first["output"] == binary_part(oversized, 0, @soft_function_call_output_bytes)
    assert second == Enum.at(params["input"], 1)
  end

  test "clamp_function_call_outputs leaves payload unchanged without input list" do
    params = %{"model" => "gpt-4o", "stream" => true}
    assert OpenAIResponsesShared.clamp_function_call_outputs(params) == params
  end

  test "insert_synthetic_tool_results when user interrupts tool flow" do
    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    tool_call = %ToolCall{id: "call_1|fc_1", name: "tool_a", arguments: %{}}

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    user = %UserMessage{role: :user, content: "next", timestamp: System.system_time(:millisecond)}

    messages =
      OpenAIResponsesShared.transform_messages(
        [assistant, user],
        model,
        MapSet.new([:openai])
      )

    assert [%AssistantMessage{}, %ToolResultMessage{}, %UserMessage{}] = messages
  end

  test "parse_streaming_json recovers partial objects and rejects inputs that are not objects" do
    for {input, expected} <- [
          {~S|{"a":1|, %{"a" => 1}},
          {~S|{"a":{"b":{"c":{"d":1|, %{"a" => %{"b" => %{"c" => %{"d" => 1}}}}},
          {~S|{"arr":[1,2,3|, %{"arr" => [1, 2, 3]}},
          {~S|{"text":"hello \"world|, %{"text" => ~s(hello "world)}},
          {"{not-json", %{}},
          {"[1,2,3]", %{}},
          {nil, %{}},
          {123, %{}}
        ] do
      assert OpenAIResponsesShared.parse_streaming_json(input) == expected
    end
  end

  test "apply_service_tier_pricing adjusts costs" do
    usage =
      %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{input: 2.0, output: 4.0, cache_read: 1.0, cache_write: 3.0, total: 10.0}
      }

    flex = OpenAIResponsesShared.apply_service_tier_pricing(usage, "flex")
    assert_in_delta flex.cost.total, 5.0, 0.0001

    priority = OpenAIResponsesShared.apply_service_tier_pricing(usage, "priority")
    assert_in_delta priority.cost.total, 20.0, 0.0001
  end

  test "service tier pricing preserves unknown components and totals" do
    usage = %Usage{
      input: nil,
      output: 100,
      cost: %Cost{input: nil, output: 4.0, cache_read: 0.0, cache_write: nil, total: nil}
    }

    for {tier, multiplier} <- [{"flex", 0.5}, {"priority", 2.0}, {"custom", 3.0}] do
      result =
        OpenAIResponsesShared.apply_service_tier_pricing(
          usage,
          tier,
          %{"flex" => 0.5, "priority" => 2.0, "custom" => 3.0}
        )

      assert result.input == nil
      assert result.output == 100
      assert is_nil(result.cost.input)
      assert result.cost.output == 4.0 * multiplier
      assert result.cost.cache_read == 0.0
      assert is_nil(result.cost.cache_write)
      assert is_nil(result.cost.total)
    end
  end

  test "service tier pricing does not reconstruct an unknown total from known components" do
    usage = %Usage{cost: %Cost{input: 2.0, output: 4.0, total: nil}}
    result = OpenAIResponsesShared.apply_service_tier_pricing(usage, "priority")

    assert result.cost.input == 4.0
    assert result.cost.output == 8.0
    assert is_nil(result.cost.total)
  end

  test "service tier pricing preserves an absent cost breakdown" do
    usage = %Usage{input: nil, cost: nil}

    for tier <- ["flex", "priority", "auto", nil] do
      assert OpenAIResponsesShared.apply_service_tier_pricing(usage, tier) == usage
    end
  end

  test "calculated partial costs survive service tier pricing" do
    model = %Model{cost: %ModelCost{input: 10.0, output: 20.0}}
    usage = %Usage{input: nil, output: 100}

    result =
      model
      |> OpenAIResponsesShared.calculate_cost(usage)
      |> OpenAIResponsesShared.apply_service_tier_pricing("flex")

    assert is_nil(result.cost.input)
    assert_in_delta result.cost.output, 0.001, 0.0000001
    assert is_nil(result.cost.total)
  end

  test "process_stream maps wire completion statuses to stop reasons" do
    for {status, reason} <- [
          {"completed", :stop},
          {"queued", :stop},
          {"in_progress", :stop},
          {"incomplete", :length},
          {"failed", :error},
          {"cancelled", :error}
        ] do
      assert {:ok, %{stop_reason: ^reason}} = process_events([completion(status)])
    end
  end

  test "halts immediately once response.completed arrives" do
    events =
      Stream.map([:terminal, :unexpected], fn
        :terminal -> completion()
        :unexpected -> flunk("consumed another event after response.completed")
      end)

    assert {:ok, %{stop_reason: :stop}} = process_events(events)
  end

  test "converts a tool list into ordered function definitions with their schemas" do
    schema = %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }

    tools = [
      %LemonAi.Types.Tool{name: "read_file", description: "Read a file", parameters: schema},
      %LemonAi.Types.Tool{name: "list_files", description: "List files", parameters: %{}}
    ]

    assert OpenAIResponsesShared.convert_tools([]) == []

    assert [
             %{
               "type" => "function",
               "name" => "read_file",
               "description" => "Read a file",
               "parameters" => ^schema
             },
             %{
               "type" => "function",
               "name" => "list_files",
               "description" => "List files",
               "parameters" => %{}
             }
           ] = OpenAIResponsesShared.convert_tools(tools)
  end

  test "long assistant message IDs are shortened consistently and remain distinct" do
    first = String.duplicate("🌟", 65) <> "a"
    second = String.duplicate("🌟", 65) <> "b"

    content =
      for id <- [first, second, first], do: %TextContent{text: "message", text_signature: id}

    context = %LemonAi.Types.Context{messages: [assistant_message(content)]}

    assert [
             %{"type" => "message", "id" => "msg_" <> _ = short_first},
             %{"type" => "message", "id" => "msg_" <> _ = short_second},
             %{"type" => "message", "id" => repeated}
           ] =
             OpenAIResponsesShared.convert_messages(base_model(), context, MapSet.new([:openai]))

    assert byte_size(short_first) in 5..64
    assert byte_size(short_second) in 5..64
    assert repeated == short_first
    refute short_first == short_second
  end

  test "retains signed reasoning for the same model and converts it to text across models" do
    signature = ~s({"type":"reasoning","summary":[]})
    thinking = %ThinkingContent{thinking: "Some reasoning", thinking_signature: signature}
    messages = [assistant_message([thinking])]

    assert [%AssistantMessage{content: [^thinking]}] =
             OpenAIResponsesShared.transform_messages(
               messages,
               base_model(),
               MapSet.new([:openai])
             )

    assert [%AssistantMessage{content: [%TextContent{text: "Some reasoning"}]}] =
             OpenAIResponsesShared.transform_messages(
               messages,
               %{base_model() | id: "gpt-5"},
               MapSet.new([:openai])
             )
  end

  test "process_stream emits text and refusal deltas as text content" do
    for {kind, content_key, first, last} <- [
          {"output_text", "text", "Hello, ", "world!"},
          {"refusal", "refusal", "I cannot ", "do that."}
        ] do
      text = first <> last

      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.#{kind}.delta", "delta" => first},
        %{"type" => "response.#{kind}.delta", "delta" => last},
        %{
          "type" => "response.output_item.done",
          "item" => %{"type" => "message", "content" => [%{"type" => kind, content_key => text}]}
        },
        completion()
      ]

      assert {%AssistantMessage{content: [%TextContent{text: ^text}]} = final,
              [
                {:text_start, 0},
                {:text_delta, 0, ^first},
                {:text_delta, 0, ^last},
                {:text_end, 0, ^text},
                {:done, :stop, final}
              ]} = process_and_drain(events)
    end
  end

  test "process_stream emits function call deltas and ends with decoded arguments" do
    args_start = ~s({"path": ")
    args_end = ~s(/test.txt"})

    item = %{
      "type" => "function_call",
      "call_id" => "call_abc",
      "id" => "fc_123",
      "name" => "read_file"
    }

    events = [
      %{"type" => "response.output_item.added", "item" => item},
      %{"type" => "response.function_call_arguments.delta", "delta" => args_start},
      %{"type" => "response.function_call_arguments.delta", "delta" => args_end},
      %{"type" => "response.function_call_arguments.done", "arguments" => args_start <> args_end},
      %{"type" => "response.output_item.done", "item" => item},
      completion()
    ]

    assert {%AssistantMessage{stop_reason: :tool_use, content: [%ToolCall{} = call]} = final,
            [
              {:tool_call_start, 0, %ToolCall{id: "call_abc|fc_123", name: "read_file"}},
              {:tool_call_delta, 0, ^args_start},
              {:tool_call_delta, 0, ^args_end},
              {:tool_call_end, 0, call},
              {:done, :tool_use, final}
            ]} = process_and_drain(events)

    assert call.arguments == %{"path" => "/test.txt"}
    refute Map.has_key?(call, :argument_chunks)
  end

  test "process_stream normalizes malformed function call identity fields" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call"
        }
      },
      %{
        "type" => "response.function_call_arguments.done",
        "arguments" => "{\"path\":\"mix.exs\"}"
      },
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "arguments" => "{\"path\":\"mix.exs\"}"
        }
      },
      %{"type" => "response.completed", "response" => %{"status" => "completed"}}
    ]

    output = %AssistantMessage{
      role: :assistant,
      content: [],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
    assert [%ToolCall{} = tool_call] = final.content
    assert final.stop_reason == :tool_use
    assert tool_call.name == "unknown_tool"
    assert tool_call.arguments == %{"path" => "mix.exs"}
    assert String.contains?(tool_call.id, "|")
    refute String.contains?(tool_call.id, "nil")

    [call_id, item_id] = String.split(tool_call.id, "|")
    assert String.starts_with?(call_id, "call_")
    assert String.starts_with?(item_id, "fc_")

    EventStream.cancel(stream, :test_cleanup)
  end

  test "process_stream normalizes duplicate function call ids to unique ids" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_dup",
          "id" => "fc_dup",
          "name" => "tool_a"
        }
      },
      %{
        "type" => "response.function_call_arguments.done",
        "arguments" => "{\"foo\":1}"
      },
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_dup",
          "id" => "fc_dup",
          "name" => "tool_a",
          "arguments" => "{\"foo\":1}"
        }
      },
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_dup",
          "id" => "fc_dup",
          "name" => "tool_b"
        }
      },
      %{"type" => "response.function_call_arguments.delta", "delta" => "{\"bar\":"},
      %{"type" => "response.function_call_arguments.delta", "delta" => "2}"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_dup",
          "id" => "fc_dup",
          "name" => "tool_b",
          "arguments" => "{\"bar\":2}"
        }
      },
      %{"type" => "response.completed", "response" => %{"status" => "completed"}}
    ]

    output = %AssistantMessage{
      role: :assistant,
      content: [],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
    assert [%ToolCall{} = first, %ToolCall{} = second] = final.content
    assert final.stop_reason == :tool_use

    assert first.id == "call_dup|fc_dup"
    assert first.name == "tool_a"
    assert first.arguments == %{"foo" => 1}

    assert second.id == "call_dup|fc_dup_1"
    assert second.name == "tool_b"
    assert second.arguments == %{"bar" => 2}

    EventStream.cancel(stream, :test_cleanup)
  end

  test "process_stream emits reasoning summary parts and retains their signed wire item" do
    parts = ["First, analyze the problem.", "Then solve it."]
    item = %{"type" => "reasoning", "summary" => Enum.map(parts, &%{"text" => &1})}

    deltas =
      Enum.flat_map(parts, fn text ->
        [
          %{
            "type" => "response.reasoning_summary_part.added",
            "part" => %{"type" => "summary_text"}
          },
          %{"type" => "response.reasoning_summary_text.delta", "delta" => text},
          %{"type" => "response.reasoning_summary_part.done"}
        ]
      end)

    events =
      [%{"type" => "response.output_item.added", "item" => %{"type" => "reasoning"}} | deltas] ++
        [%{"type" => "response.output_item.done", "item" => item}, completion()]

    [first, second] = parts
    thinking = Enum.join(parts, "\n\n")

    assert {%AssistantMessage{
              content: [%ThinkingContent{thinking: ^thinking, thinking_signature: signature}]
            } = final,
            [
              {:thinking_start, 0},
              {:thinking_delta, 0, ^first},
              {:thinking_delta, 0, "\n\n"},
              {:thinking_delta, 0, ^second},
              {:thinking_delta, 0, "\n\n"},
              {:thinking_end, 0, ^thinking},
              {:done, :stop, final}
            ]} = process_and_drain(events)

    assert Jason.decode!(signature) == item
  end

  defp completion(status \\ "completed") do
    %{"type" => "response.completed", "response" => %{"status" => status}}
  end

  defp process_events(events) do
    {:ok, stream} = EventStream.start_link()

    try do
      OpenAIResponsesShared.process_stream(events, assistant_message(), stream, base_model())
    after
      EventStream.cancel(stream, :test_cleanup)
    end
  end

  defp process_and_drain(events) do
    {:ok, stream} = EventStream.start_link()

    try do
      assert {:ok, final} =
               OpenAIResponsesShared.process_stream(
                 events,
                 assistant_message(),
                 stream,
                 base_model()
               )

      EventStream.complete(stream, final)
      {final, Enum.to_list(EventStream.events(stream))}
    after
      EventStream.cancel(stream, :test_cleanup)
    end
  end

  defp assistant_message(content \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp base_model do
    %Model{id: "gpt-4o", api: :openai_responses, provider: :openai, cost: %ModelCost{}}
  end
end
