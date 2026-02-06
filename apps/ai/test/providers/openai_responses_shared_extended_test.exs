defmodule Ai.Providers.OpenAIResponsesSharedExtendedTest do
  @moduledoc """
  Extended unit tests for OpenAI Responses API shared utilities.
  Tests error handling, edge cases, and helper functions.
  """
  use ExUnit.Case, async: true

  alias Ai.Providers.OpenAIResponsesShared
  alias Ai.EventStream

  alias Ai.Types.{
    AssistantMessage,
    Cost,
    Model,
    ModelCost,
    TextContent,
    ThinkingContent,
    ToolCall,
    Usage
  }

  # ============================================================================
  # Short Hash Tests
  # ============================================================================

  describe "short_hash/1" do
    test "produces consistent hashes for same input" do
      input = "some_long_string_that_needs_hashing"
      hash1 = OpenAIResponsesShared.short_hash(input)
      hash2 = OpenAIResponsesShared.short_hash(input)

      assert hash1 == hash2
    end

    test "produces different hashes for different inputs" do
      hash1 = OpenAIResponsesShared.short_hash("input_a")
      hash2 = OpenAIResponsesShared.short_hash("input_b")

      assert hash1 != hash2
    end

    test "produces reasonably short hashes" do
      input = String.duplicate("x", 1000)
      hash = OpenAIResponsesShared.short_hash(input)

      # Hash should be much shorter than 64 chars
      assert String.length(hash) < 30
    end

    test "handles empty string" do
      hash = OpenAIResponsesShared.short_hash("")
      assert is_binary(hash)
      assert String.length(hash) > 0
    end

    test "handles unicode characters" do
      hash = OpenAIResponsesShared.short_hash("Hello, \u{1F600}!")
      assert is_binary(hash)
    end
  end

  # ============================================================================
  # Error Event Processing Tests
  # ============================================================================

  describe "process_stream error events" do
    test "handles error event with code and message" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "error", "code" => "rate_limit_exceeded", "message" => "Too many requests"}
      ]

      output = base_output()
      model = base_model()

      assert {:error, error_msg} =
               OpenAIResponsesShared.process_stream(events, output, stream, model)

      assert String.contains?(error_msg, "rate_limit_exceeded")
      assert String.contains?(error_msg, "Too many requests")

      EventStream.cancel(stream, :test_cleanup)
    end

    test "handles error event with nil message" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "error", "code" => "unknown_error", "message" => nil}
      ]

      output = base_output()
      model = base_model()

      assert {:error, error_msg} =
               OpenAIResponsesShared.process_stream(events, output, stream, model)

      assert String.contains?(error_msg, "unknown_error")

      EventStream.cancel(stream, :test_cleanup)
    end

    test "handles response.failed event" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.failed"}
      ]

      output = base_output()
      model = base_model()

      assert {:error, _} = OpenAIResponsesShared.process_stream(events, output, stream, model)

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Streaming JSON Edge Cases Tests
  # ============================================================================

  describe "parse_streaming_json/1 edge cases" do
    test "handles deeply nested incomplete JSON" do
      json = ~s({"a": {"b": {"c": {"d": 1)
      result = OpenAIResponsesShared.parse_streaming_json(json)
      assert is_map(result)
    end

    test "handles array within object" do
      json = ~s({"arr": [1, 2, 3)
      result = OpenAIResponsesShared.parse_streaming_json(json)
      assert is_map(result)
    end

    test "handles string with escaped quotes" do
      json = ~s({"text": "hello \\"world)
      result = OpenAIResponsesShared.parse_streaming_json(json)
      # May not parse correctly, but should not crash
      assert is_map(result)
    end

    test "handles nil input" do
      result = OpenAIResponsesShared.parse_streaming_json(nil)
      assert result == %{}
    end

    test "handles non-string input" do
      result = OpenAIResponsesShared.parse_streaming_json(123)
      assert result == %{}
    end

    test "handles complete valid JSON" do
      json = ~s({"key": "value", "num": 42, "bool": true})
      result = OpenAIResponsesShared.parse_streaming_json(json)
      assert result == %{"key" => "value", "num" => 42, "bool" => true}
    end

    test "handles JSON array at root level" do
      json = "[1, 2, 3]"
      result = OpenAIResponsesShared.parse_streaming_json(json)
      # Not a map, returns empty
      assert result == %{}
    end
  end

  # ============================================================================
  # Service Tier Pricing Tests
  # ============================================================================

  describe "service_tier_cost_multiplier/1" do
    test "flex tier is 0.5x" do
      assert OpenAIResponsesShared.service_tier_cost_multiplier("flex") == 0.5
    end

    test "priority tier is 2.0x" do
      assert OpenAIResponsesShared.service_tier_cost_multiplier("priority") == 2.0
    end

    test "auto tier is 1.0x" do
      assert OpenAIResponsesShared.service_tier_cost_multiplier("auto") == 1.0
    end

    test "nil tier is 1.0x" do
      assert OpenAIResponsesShared.service_tier_cost_multiplier(nil) == 1.0
    end

    test "unknown tier is 1.0x" do
      assert OpenAIResponsesShared.service_tier_cost_multiplier("unknown") == 1.0
    end
  end

  # ============================================================================
  # Response Status Mapping Tests
  # ============================================================================

  describe "stop reason mapping" do
    test "completed maps to :stop" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      assert final.stop_reason == :stop

      EventStream.cancel(stream, :test_cleanup)
    end

    test "cancelled maps to :error" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.completed", "response" => %{"status" => "cancelled"}}
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      assert final.stop_reason == :error

      EventStream.cancel(stream, :test_cleanup)
    end

    test "in_progress maps to :stop" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.completed", "response" => %{"status" => "in_progress"}}
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      assert final.stop_reason == :stop

      EventStream.cancel(stream, :test_cleanup)
    end

    test "queued maps to :stop" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.completed", "response" => %{"status" => "queued"}}
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      assert final.stop_reason == :stop

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Tool Conversion Tests
  # ============================================================================

  describe "convert_tools/2" do
    test "converts single tool" do
      tools = [
        %Ai.Types.Tool{
          name: "read_file",
          description: "Read a file from disk",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string"}
            },
            "required" => ["path"]
          }
        }
      ]

      [converted] = OpenAIResponsesShared.convert_tools(tools)

      assert converted["type"] == "function"
      assert converted["name"] == "read_file"
      assert converted["description"] == "Read a file from disk"
      assert converted["parameters"]["type"] == "object"
    end

    test "converts multiple tools" do
      tools = [
        %Ai.Types.Tool{name: "tool_a", description: "A", parameters: %{}},
        %Ai.Types.Tool{name: "tool_b", description: "B", parameters: %{}},
        %Ai.Types.Tool{name: "tool_c", description: "C", parameters: %{}}
      ]

      converted = OpenAIResponsesShared.convert_tools(tools)
      assert length(converted) == 3
    end

    test "handles empty tools list" do
      tools = []
      converted = OpenAIResponsesShared.convert_tools(tools)
      assert converted == []
    end
  end

  # ============================================================================
  # Text Delta Event Tests
  # ============================================================================

  describe "text delta processing" do
    test "accumulates text deltas" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Hello, "},
        %{"type" => "response.output_text.delta", "delta" => "world!"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hello, world!"}]
          }
        }
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      assert length(final.content) == 1
      [%TextContent{text: text}] = final.content
      assert text == "Hello, world!"

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Refusal Event Tests
  # ============================================================================

  describe "refusal processing" do
    test "handles refusal delta" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.refusal.delta", "delta" => "I cannot "},
        %{"type" => "response.refusal.delta", "delta" => "do that."},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "refusal", "refusal" => "I cannot do that."}]
          }
        }
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      [%TextContent{text: text}] = final.content
      assert text == "I cannot do that."

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Function Call Processing Tests
  # ============================================================================

  describe "function call processing" do
    test "processes function call with streaming arguments" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "id" => "fc_123",
            "name" => "read_file"
          }
        },
        %{"type" => "response.function_call_arguments.delta", "delta" => "{\"path\": \""},
        %{"type" => "response.function_call_arguments.delta", "delta" => "/test.txt\"}"},
        %{
          "type" => "response.function_call_arguments.done",
          "arguments" => "{\"path\": \"/test.txt\"}"
        },
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "id" => "fc_123",
            "name" => "read_file",
            "arguments" => "{\"path\": \"/test.txt\"}"
          }
        }
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      [%ToolCall{} = tc] = final.content
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/test.txt"}

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Reasoning Summary Tests
  # ============================================================================

  describe "reasoning summary processing" do
    test "processes multiple reasoning summary parts" do
      {:ok, stream} = EventStream.start_link()

      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "reasoning"}},
        %{
          "type" => "response.reasoning_summary_part.added",
          "part" => %{"type" => "summary_text"}
        },
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "First, I need to "},
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "analyze the problem."},
        %{"type" => "response.reasoning_summary_part.done"},
        %{
          "type" => "response.reasoning_summary_part.added",
          "part" => %{"type" => "summary_text"}
        },
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "Then solve it."},
        %{"type" => "response.reasoning_summary_part.done"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "reasoning",
            "summary" => [
              %{"text" => "First, I need to analyze the problem."},
              %{"text" => "Then solve it."}
            ]
          }
        }
      ]

      output = base_output()
      model = base_model()

      assert {:ok, final} = OpenAIResponsesShared.process_stream(events, output, stream, model)
      [%ThinkingContent{} = thinking] = final.content
      assert String.contains?(thinking.thinking, "First")
      assert String.contains?(thinking.thinking, "Then")

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Thinking Block Transformation Tests
  # ============================================================================

  describe "thinking block transformation" do
    test "preserves thinking signature for same model" do
      model = base_model()

      assistant = %AssistantMessage{
        role: :assistant,
        content: [
          %ThinkingContent{
            type: :thinking,
            thinking: "Some reasoning",
            thinking_signature: Jason.encode!(%{"type" => "reasoning", "summary" => []})
          }
        ],
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

      [transformed] = messages
      [%ThinkingContent{} = thinking] = transformed.content
      assert thinking.thinking_signature != nil
    end

    test "converts thinking to text for different model" do
      model = %Model{
        id: "gpt-5",
        name: "GPT-5",
        api: :openai_responses,
        provider: :openai,
        base_url: "https://api.openai.com/v1",
        cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0}
      }

      assistant = %AssistantMessage{
        role: :assistant,
        content: [
          %ThinkingContent{
            type: :thinking,
            thinking: "Some reasoning",
            thinking_signature: nil
          }
        ],
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

      [transformed] = messages
      [%TextContent{} = text] = transformed.content
      assert text.text == "Some reasoning"
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp base_output do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :openai_responses,
      provider: :openai,
      model: "gpt-4o",
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp base_model do
    %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0}
    }
  end
end
