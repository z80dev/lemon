defmodule Ai.Providers.GoogleSharedComprehensiveTest do
  @moduledoc """
  Comprehensive tests for the Ai.Providers.GoogleShared module.

  Tests shared utilities for Google Generative AI, Vertex AI, and Gemini CLI providers,
  including content conversion, tool formatting, stop reason mapping, and more.
  """
  use ExUnit.Case, async: true

  alias Ai.Providers.GoogleShared
  alias Ai.Types.{Model, Context, UserMessage, AssistantMessage, TextContent, ImageContent, Tool}

  # ============================================================================
  # Thinking Part Detection
  # ============================================================================

  describe "thinking_part?/1" do
    test "returns true when thought is true" do
      assert GoogleShared.thinking_part?(%{"thought" => true})
    end

    test "returns false when thought is false" do
      refute GoogleShared.thinking_part?(%{"thought" => false})
    end

    test "returns false when thought key is missing" do
      refute GoogleShared.thinking_part?(%{"text" => "hello"})
    end

    test "returns false for empty map" do
      refute GoogleShared.thinking_part?(%{})
    end
  end

  # ============================================================================
  # Thought Signature Handling
  # ============================================================================

  describe "retain_thought_signature/2" do
    test "returns incoming when incoming is non-empty binary" do
      assert GoogleShared.retain_thought_signature(nil, "new_sig") == "new_sig"
      assert GoogleShared.retain_thought_signature("old_sig", "new_sig") == "new_sig"
    end

    test "returns existing when incoming is nil" do
      assert GoogleShared.retain_thought_signature("existing_sig", nil) == "existing_sig"
    end

    test "returns existing when incoming is empty string" do
      assert GoogleShared.retain_thought_signature("existing_sig", "") == "existing_sig"
    end

    test "returns nil when both are nil" do
      assert GoogleShared.retain_thought_signature(nil, nil) == nil
    end
  end

  describe "valid_thought_signature?/1" do
    test "returns true for valid base64 strings" do
      assert GoogleShared.valid_thought_signature?("SGVsbG8=")
      assert GoogleShared.valid_thought_signature?("YWJj")
      assert GoogleShared.valid_thought_signature?("dGVzdA==")
    end

    test "returns false for nil" do
      refute GoogleShared.valid_thought_signature?(nil)
    end

    test "returns false for non-base64 strings" do
      refute GoogleShared.valid_thought_signature?("not-base64!!!")
      refute GoogleShared.valid_thought_signature?("hello world")
    end

    test "returns false for strings not divisible by 4" do
      refute GoogleShared.valid_thought_signature?("abc")
      refute GoogleShared.valid_thought_signature?("a")
    end

    test "returns false for empty string" do
      # Empty string is not a valid thought signature
      refute GoogleShared.valid_thought_signature?("")
    end
  end

  describe "resolve_thought_signature/2" do
    test "returns signature when same provider/model and valid" do
      sig = "SGVsbG8="
      assert GoogleShared.resolve_thought_signature(true, sig) == sig
    end

    test "returns nil when different provider/model" do
      sig = "SGVsbG8="
      assert GoogleShared.resolve_thought_signature(false, sig) == nil
    end

    test "returns nil when signature is invalid" do
      assert GoogleShared.resolve_thought_signature(true, "invalid!!!") == nil
      assert GoogleShared.resolve_thought_signature(true, nil) == nil
    end
  end

  # ============================================================================
  # Tool Call ID Requirements
  # ============================================================================

  describe "requires_tool_call_id?/1" do
    test "returns true for Claude models" do
      assert GoogleShared.requires_tool_call_id?("claude-3-opus")
      assert GoogleShared.requires_tool_call_id?("claude-3-sonnet")
      assert GoogleShared.requires_tool_call_id?("claude-3-haiku")
    end

    test "returns true for GPT-OSS models" do
      assert GoogleShared.requires_tool_call_id?("gpt-oss-20b")
      assert GoogleShared.requires_tool_call_id?("gpt-oss-120b")
    end

    test "returns false for Gemini models" do
      refute GoogleShared.requires_tool_call_id?("gemini-1.5-pro")
      refute GoogleShared.requires_tool_call_id?("gemini-2.5-flash")
    end

    test "returns false for other models" do
      refute GoogleShared.requires_tool_call_id?("gpt-4")
      refute GoogleShared.requires_tool_call_id?("unknown-model")
    end
  end

  # ============================================================================
  # Content Conversion
  # ============================================================================

  describe "convert_messages/2" do
    setup do
      model = %Model{
        id: "gemini-2.5-flash",
        name: "Gemini 2.5 Flash",
        api: :google_generative_ai,
        provider: :google,
        reasoning: true,
        input: [:text, :image],
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 1_000_000,
        max_tokens: 8192
      }

      {:ok, model: model}
    end

    test "converts simple user message", %{model: model} do
      context = %Context{
        messages: [%UserMessage{content: "Hello"}],
        system_prompt: nil,
        tools: []
      }

      result = GoogleShared.convert_messages(model, context)

      assert [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}] = result
    end

    test "converts user message with multiple text parts", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{content: [%TextContent{text: "Part 1"}, %TextContent{text: "Part 2"}]}
        ],
        system_prompt: nil,
        tools: []
      }

      result = GoogleShared.convert_messages(model, context)

      assert [%{"role" => "user", "parts" => parts}] = result
      assert length(parts) == 2
    end

    test "converts assistant message with text", %{model: model} do
      context = %Context{
        messages: [
          %AssistantMessage{
            content: [%TextContent{text: "Hello!"}],
            provider: :google,
            model: model.id
          }
        ],
        system_prompt: nil,
        tools: []
      }

      result = GoogleShared.convert_messages(model, context)

      assert [%{"role" => "model", "parts" => [%{"text" => "Hello!"}]}] = result
    end

    test "converts empty message list", %{model: model} do
      context = %Context{
        messages: [],
        system_prompt: nil,
        tools: []
      }

      result = GoogleShared.convert_messages(model, context)
      assert result == []
    end

    test "handles image content when model supports it", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            content: [
              %TextContent{text: "Look at this:"},
              %ImageContent{mime_type: "image/png", data: "base64data"}
            ]
          }
        ],
        system_prompt: nil,
        tools: []
      }

      result = GoogleShared.convert_messages(model, context)

      assert [%{"role" => "user", "parts" => parts}] = result
      assert length(parts) == 2
    end

    test "filters image content when model doesn't support it" do
      model = %Model{
        id: "text-only-model",
        name: "Text Only",
        api: :google_generative_ai,
        provider: :google,
        base_url: "",
        reasoning: false,
        input: [:text],
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 100_000,
        max_tokens: 4096,
        headers: %{},
        compat: nil
      }

      context = %Context{
        messages: [
          %UserMessage{
            content: [
              %TextContent{text: "Look at this:"},
              %ImageContent{mime_type: "image/png", data: "base64data"}
            ]
          }
        ],
        system_prompt: nil,
        tools: []
      }

      result = GoogleShared.convert_messages(model, context)

      assert [%{"role" => "user", "parts" => parts}] = result
      assert length(parts) == 1
      assert %{"text" => "Look at this:"} in parts
    end
  end

  # ============================================================================
  # Tool Conversion
  # ============================================================================

  describe "convert_tools/1" do
    test "returns nil for empty tool list" do
      assert GoogleShared.convert_tools([]) == nil
    end

    test "converts single tool" do
      tools = [
        %Tool{
          name: "get_weather",
          description: "Get weather information",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string"}
            }
          }
        }
      ]

      result = GoogleShared.convert_tools(tools)

      assert [%{"functionDeclarations" => declarations}] = result

      assert [%{"name" => "get_weather", "description" => "Get weather information"}] =
               declarations
    end

    test "converts multiple tools" do
      tools = [
        %Tool{name: "tool1", description: "First tool", parameters: %{}},
        %Tool{name: "tool2", description: "Second tool", parameters: %{}},
        %Tool{name: "tool3", description: "Third tool", parameters: %{}}
      ]

      result = GoogleShared.convert_tools(tools)

      assert [%{"functionDeclarations" => declarations}] = result
      assert length(declarations) == 3
    end

    test "preserves tool parameters" do
      tools = [
        %Tool{
          name: "search",
          description: "Search tool",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Search query"},
              "limit" => %{"type" => "integer", "default" => 10}
            },
            "required" => ["query"]
          }
        }
      ]

      result = GoogleShared.convert_tools(tools)

      assert [%{"functionDeclarations" => [declaration]}] = result
      assert declaration["parameters"]["type"] == "object"
      assert declaration["parameters"]["properties"]["query"]["type"] == "string"
    end
  end

  describe "map_tool_choice/1" do
    test "maps :auto to AUTO" do
      assert GoogleShared.map_tool_choice(:auto) == "AUTO"
    end

    test "maps :none to NONE" do
      assert GoogleShared.map_tool_choice(:none) == "NONE"
    end

    test "maps :any to ANY" do
      assert GoogleShared.map_tool_choice(:any) == "ANY"
    end

    test "defaults to AUTO for unknown values" do
      assert GoogleShared.map_tool_choice(:unknown) == "AUTO"
      assert GoogleShared.map_tool_choice(nil) == "AUTO"
    end
  end

  # ============================================================================
  # Stop Reason Mapping
  # ============================================================================

  describe "map_stop_reason/1" do
    test "maps STOP to :stop" do
      assert GoogleShared.map_stop_reason("STOP") == :stop
    end

    test "maps MAX_TOKENS to :length" do
      assert GoogleShared.map_stop_reason("MAX_TOKENS") == :length
    end

    test "maps unknown reasons to :error" do
      assert GoogleShared.map_stop_reason("SAFETY") == :error
      assert GoogleShared.map_stop_reason("RECITATION") == :error
      assert GoogleShared.map_stop_reason("OTHER") == :error
      assert GoogleShared.map_stop_reason("") == :error
    end
  end

  # ============================================================================
  # Unicode Sanitization
  # ============================================================================

  describe "sanitize_surrogates/1" do
    test "returns valid UTF-8 unchanged" do
      text = "Hello, World!"
      assert GoogleShared.sanitize_surrogates(text) == text
    end

    test "handles empty string" do
      assert GoogleShared.sanitize_surrogates("") == ""
    end

    test "handles unicode characters" do
      text = "Hello 世界 🌍"
      assert GoogleShared.sanitize_surrogates(text) == text
    end

    test "converts non-binary to string" do
      assert GoogleShared.sanitize_surrogates(123) == "123"
      assert GoogleShared.sanitize_surrogates(:atom) == "atom"
    end
  end

  # ============================================================================
  # SSE Helpers
  # ============================================================================

  describe "normalize_sse_message/1" do
    test "normalizes {:data, binary} tuple" do
      assert GoogleShared.normalize_sse_message({:data, "hello"}) == {:data, "hello"}
    end

    test "normalizes nested data tuple" do
      assert GoogleShared.normalize_sse_message({:something, {:data, "hello"}}) ==
               {:data, "hello"}
    end

    test "normalizes :done messages" do
      assert GoogleShared.normalize_sse_message({:done, nil}) == :done
      assert GoogleShared.normalize_sse_message({:something, :done}) == :done
      assert GoogleShared.normalize_sse_message({:something, {:done, nil}}) == :done
    end

    test "normalizes :DOWN messages" do
      assert GoogleShared.normalize_sse_message({:DOWN, :ref, :process, :pid, :reason}) == :down
    end

    test "returns :ignore for unknown messages" do
      assert GoogleShared.normalize_sse_message(:unknown) == :ignore
      assert GoogleShared.normalize_sse_message({:other, "data"}) == :ignore
    end
  end

  # ============================================================================
  # Thinking Budget Helpers
  # ============================================================================

  describe "default_budgets_2_5_pro/0" do
    test "returns expected budget map" do
      budgets = GoogleShared.default_budgets_2_5_pro()

      assert budgets[:minimal] == 128
      assert budgets[:low] == 2048
      assert budgets[:medium] == 8192
      assert budgets[:high] == 32768
    end
  end

  describe "default_budgets_2_5_flash/0" do
    test "returns expected budget map" do
      budgets = GoogleShared.default_budgets_2_5_flash()

      assert budgets[:minimal] == 128
      assert budgets[:low] == 2048
      assert budgets[:medium] == 8192
      assert budgets[:high] == 24576
    end
  end

  describe "get_thinking_budget/3" do
    setup do
      model = %Model{
        id: "gemini-2.5-pro",
        name: "Gemini 2.5 Pro",
        api: :google_generative_ai,
        provider: :google,
        reasoning: true,
        input: [:text],
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 1_000_000,
        max_tokens: 8192
      }

      {:ok, model: model}
    end

    test "returns custom budget when provided", %{model: model} do
      custom_budgets = %{low: 5000, medium: 10000}
      assert GoogleShared.get_thinking_budget(model, :low, custom_budgets) == 5000
    end

    test "returns default budget for 2.5-pro", %{model: model} do
      assert GoogleShared.get_thinking_budget(model, :high, %{}) == 32768
    end

    test "returns -1 for unknown model" do
      unknown_model = %Model{
        id: "unknown-model",
        name: "Unknown",
        api: :test,
        provider: :test,
        base_url: "",
        reasoning: false,
        input: [:text],
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 100_000,
        max_tokens: 4096,
        headers: %{},
        compat: nil
      }

      assert GoogleShared.get_thinking_budget(unknown_model, :medium, %{}) == -1
    end

    test "returns -1 for unknown effort level", %{model: model} do
      assert GoogleShared.get_thinking_budget(model, :unknown, %{}) == -1
    end
  end

  describe "gemini_3_pro?/1" do
    test "returns true for gemini-3-pro models" do
      assert GoogleShared.gemini_3_pro?("gemini-3-pro")
      assert GoogleShared.gemini_3_pro?("gemini-3-pro-latest")
    end

    test "returns false for non-gemini-3-pro models" do
      refute GoogleShared.gemini_3_pro?("gemini-2.5-pro")
      refute GoogleShared.gemini_3_pro?("gemini-3-flash")
    end
  end

  describe "gemini_3_flash?/1" do
    test "returns true for gemini-3-flash models" do
      assert GoogleShared.gemini_3_flash?("gemini-3-flash")
      assert GoogleShared.gemini_3_flash?("gemini-3-flash-latest")
    end

    test "returns false for non-gemini-3-flash models" do
      refute GoogleShared.gemini_3_flash?("gemini-2.5-flash")
      refute GoogleShared.gemini_3_flash?("gemini-3-pro")
    end
  end

  describe "get_gemini_3_thinking_level/2" do
    test "returns LOW for pro model with minimal/low effort" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-pro") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:low, "gemini-3-pro") == "LOW"
    end

    test "returns HIGH for pro model with medium/high effort" do
      assert GoogleShared.get_gemini_3_thinking_level(:medium, "gemini-3-pro") == "HIGH"
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-pro") == "HIGH"
    end

    test "returns all levels for flash model" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-flash") == "MINIMAL"
      assert GoogleShared.get_gemini_3_thinking_level(:low, "gemini-3-flash") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:medium, "gemini-3-flash") == "MEDIUM"
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-flash") == "HIGH"
    end
  end

  describe "clamp_reasoning/1" do
    test "returns nil for nil input" do
      assert GoogleShared.clamp_reasoning(nil) == nil
    end

    test "returns :high for :xhigh" do
      assert GoogleShared.clamp_reasoning(:xhigh) == :high
    end

    test "returns level for valid levels" do
      assert GoogleShared.clamp_reasoning(:minimal) == :minimal
      assert GoogleShared.clamp_reasoning(:low) == :low
      assert GoogleShared.clamp_reasoning(:medium) == :medium
      assert GoogleShared.clamp_reasoning(:high) == :high
    end

    test "returns nil for invalid levels" do
      assert GoogleShared.clamp_reasoning(:invalid) == nil
      assert GoogleShared.clamp_reasoning("string") == nil
    end
  end

  # ============================================================================
  # Retry Helpers
  # ============================================================================

  describe "extract_retry_delay/2" do
    test "extracts delay from retry-after header" do
      headers = %{"retry-after" => "5"}
      delay = GoogleShared.extract_retry_delay("", headers)

      # Should be ~6000ms (5s + 1000ms buffer)
      assert delay >= 5000
      assert delay <= 7000
    end

    test "extracts delay from x-ratelimit-reset-after header" do
      headers = %{"x-ratelimit-reset-after" => "2.5"}
      delay = GoogleShared.extract_retry_delay("", headers)

      assert delay >= 2500
      assert delay <= 4000
    end

    test "extracts delay from quota reset message" do
      text = "Your quota will reset after 39s"
      delay = GoogleShared.extract_retry_delay(text, %{})

      assert delay >= 39000
      assert delay <= 41000
    end

    test "extracts delay from complex duration" do
      text = "Your quota will reset after 1h30m45s"
      delay = GoogleShared.extract_retry_delay(text, %{})

      expected_ms = (1 * 3600 + 30 * 60 + 45) * 1000 + 1000
      assert delay == expected_ms
    end

    test "extracts delay from 'Please retry in' message" do
      text = "Please retry in 5s"
      delay = GoogleShared.extract_retry_delay(text, %{})

      assert delay >= 5000
      assert delay <= 6500
    end

    test "extracts delay from retryDelay JSON field" do
      text = ~s({"error": {"retryDelay": "34.074824224s"}})
      delay = GoogleShared.extract_retry_delay(text, %{})

      assert delay >= 34000
      assert delay <= 36000
    end

    test "returns nil when no delay can be extracted" do
      assert GoogleShared.extract_retry_delay("Some error message", %{}) == nil
    end

    test "prioritizes headers over body text" do
      headers = %{"retry-after" => "10"}
      text = "Your quota will reset after 5s"

      delay = GoogleShared.extract_retry_delay(text, headers)

      # Should use header value (10s + buffer)
      assert delay >= 10000
    end
  end

  describe "retryable_error?/2" do
    test "returns true for rate limit status code" do
      assert GoogleShared.retryable_error?(429, "")
    end

    test "returns true for server error status codes" do
      assert GoogleShared.retryable_error?(500, "")
      assert GoogleShared.retryable_error?(502, "")
      assert GoogleShared.retryable_error?(503, "")
      assert GoogleShared.retryable_error?(504, "")
    end

    test "returns true for rate limit text" do
      assert GoogleShared.retryable_error?(400, "Rate limit exceeded")
      assert GoogleShared.retryable_error?(400, "Resource exhausted")
    end

    test "returns true for overloaded text" do
      assert GoogleShared.retryable_error?(400, "Service overloaded")
    end

    test "returns false for client errors" do
      refute GoogleShared.retryable_error?(400, "Bad request")
      refute GoogleShared.retryable_error?(401, "Unauthorized")
      refute GoogleShared.retryable_error?(404, "Not found")
    end
  end

  describe "extract_error_message/1" do
    test "extracts message from JSON error" do
      json = ~s({"error": {"message": "Something went wrong"}})
      assert GoogleShared.extract_error_message(json) == "Something went wrong"
    end

    test "returns original text for non-JSON" do
      text = "Plain error message"
      assert GoogleShared.extract_error_message(text) == text
    end

    test "returns original text for JSON without error message" do
      json = ~s({"status": "error"})
      assert GoogleShared.extract_error_message(json) == json
    end
  end

  describe "normalize_http_error_body/1" do
    test "returns binary bodies unchanged" do
      body = ~s({"error":{"message":"Not found"}})
      assert GoogleShared.normalize_http_error_body(body) == body
    end

    test "encodes map bodies as JSON" do
      body = %{"error" => %{"message" => "No access"}}
      assert GoogleShared.normalize_http_error_body(body) == Jason.encode!(body)
    end

    test "collects Req.Response.Async chunks into a string body" do
      ref = make_ref()
      async = %Req.Response.Async{ref: ref, pid: self()}

      send(self(), {ref, {:data, "{\"error\":{"}})
      send(self(), {ref, {:data, "\"message\":\"No access\"}}"}})
      send(self(), {ref, :done})

      assert GoogleShared.normalize_http_error_body(async, 50) ==
               ~s({"error":{"message":"No access"}})
    end

    test "falls back to async inspect when no chunks arrive before timeout" do
      async = %Req.Response.Async{ref: make_ref(), pid: self()}
      text = GoogleShared.normalize_http_error_body(async, 0)
      assert String.contains?(text, "Req.Response.Async")
    end
  end

  # ============================================================================
  # Cost Calculation
  # ============================================================================

  describe "calculate_cost/2" do
    setup do
      model = %Model{
        id: "test-model",
        name: "Test",
        api: :test,
        provider: :test,
        reasoning: false,
        input: [:text],
        cost: %{
          input: 1.0,
          output: 2.0,
          cache_read: 0.5,
          cache_write: 1.5
        },
        context_window: 100_000,
        max_tokens: 4096
      }

      {:ok, model: model}
    end

    test "calculates cost for input tokens", %{model: model} do
      usage = %{input: 1000, output: 0, cache_read: 0, cache_write: 0}
      result = GoogleShared.calculate_cost(model, usage)

      # 1000 tokens * $1.00 / 1M = $0.001
      assert result.cost.input == 0.001
    end

    test "calculates cost for output tokens", %{model: model} do
      usage = %{input: 0, output: 500, cache_read: 0, cache_write: 0}
      result = GoogleShared.calculate_cost(model, usage)

      # 500 tokens * $2.00 / 1M = $0.001
      assert result.cost.output == 0.001
    end

    test "calculates cost for cache operations", %{model: model} do
      usage = %{input: 0, output: 0, cache_read: 2000, cache_write: 1000}
      result = GoogleShared.calculate_cost(model, usage)

      # 2000 * $0.50 / 1M = $0.001
      assert result.cost.cache_read == 0.001
      # 1000 * $1.50 / 1M = $0.0015
      assert result.cost.cache_write == 0.0015
    end

    test "calculates total cost correctly", %{model: model} do
      usage = %{input: 1_000_000, output: 500_000, cache_read: 2_000_000, cache_write: 1_000_000}
      result = GoogleShared.calculate_cost(model, usage)

      # input: $1.00, output: $1.00, cache_read: $1.00, cache_write: $1.50
      assert result.cost.total == 4.5
    end

    test "returns zero for zero usage", %{model: model} do
      usage = %{input: 0, output: 0, cache_read: 0, cache_write: 0}
      result = GoogleShared.calculate_cost(model, usage)

      assert result.cost.input == 0.0
      assert result.cost.output == 0.0
      assert result.cost.total == 0.0
    end
  end
end
