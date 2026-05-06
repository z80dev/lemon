defmodule Ai.Providers.OpenAIResponsesSharedTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Ai.EventStream
  alias Ai.Providers.OpenAIResponsesShared

  alias Ai.Types.{
    AssistantMessage,
    Cost,
    ImageContent,
    Model,
    ModelCost,
    TextContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  @soft_function_call_output_bytes 65_536

  test "process_stream catches thrown stream errors" do
    {:ok, stream} = EventStream.start_link()

    events =
      Stream.resource(
        fn -> :ok end,
        fn _ -> throw({:stream_error, "boom"}) end,
        fn _ -> :ok end
      )

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

    assert {:error, "boom"} = OpenAIResponsesShared.process_stream(events, output, stream, model)

    EventStream.cancel(stream, :test_cleanup)
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

  test "sanitize_surrogates handles invalid utf-8 safely" do
    invalid = <<0xC3, 0x28, 0xFF>>

    sanitized = OpenAIResponsesShared.sanitize_surrogates(invalid)

    assert is_binary(sanitized)
    assert String.valid?(sanitized)
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
        %Ai.Types.Context{system_prompt: nil, messages: [assistant]},
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
        %Ai.Types.Context{system_prompt: nil, messages: [assistant]},
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

    context = %Ai.Types.Context{system_prompt: "System", messages: []}

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
    context = %Ai.Types.Context{system_prompt: nil, messages: [%UserMessage{content: [image]}]}

    messages = OpenAIResponsesShared.convert_messages(model, context, MapSet.new([:openai]))

    assert messages == []
  end

  test "convert_tools honors strict option" do
    tools = [
      %Ai.Types.Tool{name: "tool_a", description: "A", parameters: %{"type" => "object"}}
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
      %Ai.Types.Tool{
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

    context = %Ai.Types.Context{system_prompt: nil, messages: [tool_result]}

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

    context = %Ai.Types.Context{system_prompt: nil, messages: [tool_result]}

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

  test "parse_streaming_json handles partial objects" do
    assert %{"a" => 1} = OpenAIResponsesShared.parse_streaming_json("{\"a\":1")
    assert %{} = OpenAIResponsesShared.parse_streaming_json("{not-json")
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

  test "process_stream maps failed status to error stop_reason" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{"type" => "response.completed", "response" => %{"status" => "failed"}}
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
    assert final.stop_reason == :error

    EventStream.cancel(stream, :test_cleanup)
  end

  test "process_stream maps incomplete status to length" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{"type" => "response.completed", "response" => %{"status" => "incomplete"}}
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
    assert final.stop_reason == :length

    EventStream.cancel(stream, :test_cleanup)
  end

  test "process_stream promotes stop_reason to tool_use when tool calls exist" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_1",
          "id" => "fc_1",
          "name" => "tool_a"
        }
      },
      %{
        "type" => "response.function_call_arguments.done",
        "arguments" => "{\"a\":1}"
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
    assert final.stop_reason == :tool_use

    EventStream.cancel(stream, :test_cleanup)
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

  test "process_stream builds reasoning blocks with signature" do
    {:ok, stream} = EventStream.start_link()

    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{"type" => "reasoning"}
      },
      %{"type" => "response.reasoning_summary_text.delta", "delta" => "Step 1"},
      %{
        "type" => "response.output_item.done",
        "item" => %{"type" => "reasoning", "summary" => [%{"text" => "Step 1"}]}
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
      cost: %ModelCost{}
    }

    assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
    [%Ai.Types.ThinkingContent{} = block] = final.content
    assert block.thinking == "Step 1"
    assert is_binary(block.thinking_signature)

    EventStream.cancel(stream, :test_cleanup)
  end
end
