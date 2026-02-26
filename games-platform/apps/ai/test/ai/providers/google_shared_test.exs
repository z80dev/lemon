defmodule Ai.Providers.GoogleSharedTest do
  use ExUnit.Case, async: true

  alias Ai.Providers.GoogleShared

  alias Ai.Types.{
    AssistantMessage,
    Context,
    ImageContent,
    Model,
    ModelCost,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

  # ============================================================================
  # Helpers
  # ============================================================================

  defp model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "gemini-2.5-pro"),
      provider: Keyword.get(opts, :provider, :google_generative_ai),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0})
    }
  end

  defp context(messages) do
    %Context{messages: messages}
  end

  # ============================================================================
  # thinking_part?/1
  # ============================================================================

  describe "thinking_part?/1" do
    test "returns true when thought is true" do
      assert GoogleShared.thinking_part?(%{"thought" => true})
    end

    test "returns false when thought is false" do
      refute GoogleShared.thinking_part?(%{"thought" => false})
    end

    test "returns false for text-only parts" do
      refute GoogleShared.thinking_part?(%{"text" => "hello"})
    end

    test "returns false for parts with thoughtSignature but no thought flag" do
      refute GoogleShared.thinking_part?(%{"text" => "hi", "thoughtSignature" => "abc="})
    end
  end

  # ============================================================================
  # retain_thought_signature/2
  # ============================================================================

  describe "retain_thought_signature/2" do
    test "returns incoming when non-empty binary" do
      assert GoogleShared.retain_thought_signature("old_sig=", "new_sig=") == "new_sig="
    end

    test "returns existing when incoming is nil" do
      assert GoogleShared.retain_thought_signature("existing=", nil) == "existing="
    end

    test "returns existing when incoming is empty string" do
      assert GoogleShared.retain_thought_signature("existing=", "") == "existing="
    end

    test "returns nil when both are nil" do
      assert GoogleShared.retain_thought_signature(nil, nil) == nil
    end
  end

  # ============================================================================
  # valid_thought_signature?/1
  # ============================================================================

  describe "valid_thought_signature?/1" do
    test "returns false for nil" do
      refute GoogleShared.valid_thought_signature?(nil)
    end

    test "returns true for valid base64" do
      assert GoogleShared.valid_thought_signature?("YWJj")
    end

    test "returns true for base64 with padding" do
      assert GoogleShared.valid_thought_signature?("YWI=")
    end

    test "returns false for non-base64 characters" do
      refute GoogleShared.valid_thought_signature?("abc!")
    end

    test "returns false for non-multiple-of-4 length" do
      refute GoogleShared.valid_thought_signature?("abc")
    end
  end

  # ============================================================================
  # resolve_thought_signature/2
  # ============================================================================

  describe "resolve_thought_signature/2" do
    test "returns valid signature when same provider" do
      assert GoogleShared.resolve_thought_signature(true, "YWJj") == "YWJj"
    end

    test "returns nil for invalid signature when same provider" do
      assert GoogleShared.resolve_thought_signature(true, "bad!") == nil
    end

    test "returns nil when not same provider regardless of signature" do
      assert GoogleShared.resolve_thought_signature(false, "YWJj") == nil
    end
  end

  # ============================================================================
  # requires_tool_call_id?/1
  # ============================================================================

  describe "requires_tool_call_id?/1" do
    test "returns true for claude models" do
      assert GoogleShared.requires_tool_call_id?("claude-3.5-sonnet")
    end

    test "returns true for gpt-oss models" do
      assert GoogleShared.requires_tool_call_id?("gpt-oss-4o")
    end

    test "returns false for gemini models" do
      refute GoogleShared.requires_tool_call_id?("gemini-2.5-pro")
    end
  end

  # ============================================================================
  # convert_messages/2
  # ============================================================================

  describe "convert_messages/2 with UserMessage" do
    test "converts simple text user message" do
      messages = [%UserMessage{content: "Hello"}]
      result = GoogleShared.convert_messages(model(), context(messages))
      assert result == [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]
    end

    test "converts multipart user message with text" do
      messages = [%UserMessage{content: [%TextContent{text: "Hello"}]}]
      result = GoogleShared.convert_messages(model(), context(messages))
      assert result == [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]
    end

    test "converts multipart user message with image when model supports images" do
      m = model(input: [:text, :image])
      messages = [%UserMessage{content: [%ImageContent{data: "base64data", mime_type: "image/png"}]}]
      result = GoogleShared.convert_messages(m, context(messages))

      assert [%{"role" => "user", "parts" => [%{"inlineData" => %{"mimeType" => "image/png", "data" => "base64data"}}]}] =
               result
    end

    test "filters out images when model doesn't support them" do
      messages = [%UserMessage{content: [%ImageContent{data: "base64data", mime_type: "image/png"}]}]
      result = GoogleShared.convert_messages(model(input: [:text]), context(messages))
      assert result == []
    end

    test "converts mixed text and image user message" do
      m = model(input: [:text, :image])

      messages = [
        %UserMessage{
          content: [
            %TextContent{text: "Look at this"},
            %ImageContent{data: "imgdata", mime_type: "image/jpeg"}
          ]
        }
      ]

      result = GoogleShared.convert_messages(m, context(messages))

      assert [
               %{
                 "role" => "user",
                 "parts" => [
                   %{"text" => "Look at this"},
                   %{"inlineData" => %{"mimeType" => "image/jpeg", "data" => "imgdata"}}
                 ]
               }
             ] = result
    end
  end

  describe "convert_messages/2 with AssistantMessage" do
    test "converts assistant message with text content" do
      messages = [
        %AssistantMessage{
          content: [%TextContent{text: "Hi there"}],
          provider: :google_generative_ai,
          model: "gemini-2.5-pro"
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))
      assert [%{"role" => "model", "parts" => [%{"text" => "Hi there"}]}] = result
    end

    test "converts assistant message with thinking content from same provider" do
      messages = [
        %AssistantMessage{
          content: [%ThinkingContent{thinking: "Let me think...", thinking_signature: "YWJj"}],
          provider: :google_generative_ai,
          model: "gemini-2.5-pro"
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))

      assert [%{"role" => "model", "parts" => [%{"thought" => true, "text" => "Let me think...", "thoughtSignature" => "YWJj"}]}] =
               result
    end

    test "converts thinking to plain text when different provider" do
      messages = [
        %AssistantMessage{
          content: [%ThinkingContent{thinking: "Let me think...", thinking_signature: "YWJj"}],
          provider: :anthropic,
          model: "claude-3.5-sonnet"
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))
      assert [%{"role" => "model", "parts" => [%{"text" => "Let me think..."}]}] = result
    end

    test "filters out empty text content" do
      messages = [
        %AssistantMessage{
          content: [%TextContent{text: ""}],
          provider: :google_generative_ai,
          model: "gemini-2.5-pro"
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))
      assert result == []
    end

    test "converts tool calls with function call format" do
      messages = [
        %AssistantMessage{
          content: [
            %ToolCall{
              id: "call_1",
              name: "get_weather",
              arguments: %{"city" => "NYC"},
              thought_signature: "YWJj"
            }
          ],
          provider: :google_generative_ai,
          model: "gemini-2.5-pro"
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))

      assert [
               %{
                 "role" => "model",
                 "parts" => [
                   %{
                     "functionCall" => %{"name" => "get_weather", "args" => %{"city" => "NYC"}},
                     "thoughtSignature" => "YWJj"
                   }
                 ]
               }
             ] = result
    end

    test "adds tool call ID for claude models" do
      m = model(id: "claude-3.5-sonnet")

      messages = [
        %AssistantMessage{
          content: [
            %ToolCall{
              id: "call_1",
              name: "get_weather",
              arguments: %{"city" => "NYC"},
              thought_signature: "YWJj"
            }
          ],
          provider: :google_generative_ai,
          model: "claude-3.5-sonnet"
        }
      ]

      result = GoogleShared.convert_messages(m, context(messages))

      assert [
               %{
                 "role" => "model",
                 "parts" => [
                   %{
                     "functionCall" => %{"name" => "get_weather", "args" => %{"city" => "NYC"}, "id" => "call_1"},
                     "thoughtSignature" => "YWJj"
                   }
                 ]
               }
             ] = result
    end

    test "gemini-3 converts unsigned tool calls to text" do
      m = model(id: "gemini-3-pro")

      messages = [
        %AssistantMessage{
          content: [
            %ToolCall{
              id: "call_1",
              name: "get_weather",
              arguments: %{"city" => "NYC"},
              thought_signature: nil
            }
          ],
          provider: :anthropic,
          model: "claude-3.5-sonnet"
        }
      ]

      result = GoogleShared.convert_messages(m, context(messages))

      assert [%{"role" => "model", "parts" => [%{"text" => text}]}] = result
      assert text =~ "Historical context"
      assert text =~ "get_weather"
    end
  end

  describe "convert_messages/2 with ToolResultMessage" do
    test "converts tool result with text content" do
      messages = [
        %ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "get_weather",
          content: [%TextContent{text: "Sunny, 72F"}]
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))

      assert [
               %{
                 "role" => "user",
                 "parts" => [
                   %{
                     "functionResponse" => %{
                       "name" => "get_weather",
                       "response" => %{"output" => "Sunny, 72F"}
                     }
                   }
                 ]
               }
             ] = result
    end

    test "converts error tool result" do
      messages = [
        %ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "run_cmd",
          content: [%TextContent{text: "command not found"}],
          is_error: true
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))

      assert [
               %{
                 "role" => "user",
                 "parts" => [
                   %{
                     "functionResponse" => %{
                       "name" => "run_cmd",
                       "response" => %{"error" => "command not found"}
                     }
                   }
                 ]
               }
             ] = result
    end

    test "merges consecutive tool results into single user turn" do
      messages = [
        %ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "tool_a",
          content: [%TextContent{text: "result A"}]
        },
        %ToolResultMessage{
          tool_call_id: "call_2",
          tool_name: "tool_b",
          content: [%TextContent{text: "result B"}]
        }
      ]

      result = GoogleShared.convert_messages(model(), context(messages))

      assert [%{"role" => "user", "parts" => parts}] = result
      assert length(parts) == 2
      assert Enum.any?(parts, &(&1["functionResponse"]["name"] == "tool_a"))
      assert Enum.any?(parts, &(&1["functionResponse"]["name"] == "tool_b"))
    end

    test "adds image as separate user message for non-gemini-3 model" do
      m = model(id: "gemini-2.5-pro", input: [:text, :image])

      messages = [
        %ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "screenshot",
          content: [%ImageContent{data: "imgdata", mime_type: "image/png"}]
        }
      ]

      result = GoogleShared.convert_messages(m, context(messages))

      assert [
               %{"role" => "user", "parts" => [%{"functionResponse" => _}]},
               %{"role" => "user", "parts" => [%{"text" => "Tool result image:"} | _image_parts]}
             ] = result
    end

    test "nests image parts inside functionResponse for gemini-3" do
      m = model(id: "gemini-3-pro", input: [:text, :image])

      messages = [
        %ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "screenshot",
          content: [%ImageContent{data: "imgdata", mime_type: "image/png"}]
        }
      ]

      result = GoogleShared.convert_messages(m, context(messages))

      assert [%{"role" => "user", "parts" => [%{"functionResponse" => fr}]}] = result
      assert Map.has_key?(fr, "parts")
    end
  end

  # ============================================================================
  # convert_tools/1
  # ============================================================================

  describe "convert_tools/1" do
    test "returns nil for empty list" do
      assert GoogleShared.convert_tools([]) == nil
    end

    test "converts single tool" do
      tools = [%Tool{name: "get_weather", description: "Get weather", parameters: %{"type" => "object"}}]
      result = GoogleShared.convert_tools(tools)

      assert [%{"functionDeclarations" => [%{"name" => "get_weather", "description" => "Get weather", "parameters" => %{"type" => "object"}}]}] =
               result
    end

    test "converts multiple tools" do
      tools = [
        %Tool{name: "tool_a", description: "Tool A", parameters: %{}},
        %Tool{name: "tool_b", description: "Tool B", parameters: %{"type" => "object"}}
      ]

      result = GoogleShared.convert_tools(tools)
      assert [%{"functionDeclarations" => declarations}] = result
      assert length(declarations) == 2
    end
  end

  # ============================================================================
  # map_tool_choice/1
  # ============================================================================

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

    test "defaults unknown to AUTO" do
      assert GoogleShared.map_tool_choice(:something_else) == "AUTO"
    end
  end

  # ============================================================================
  # map_stop_reason/1
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
      assert GoogleShared.map_stop_reason("OTHER") == :error
    end
  end

  # ============================================================================
  # sanitize_surrogates/1
  # ============================================================================

  describe "sanitize_surrogates/1" do
    test "passes through valid UTF-8" do
      assert GoogleShared.sanitize_surrogates("Hello world") == "Hello world"
    end

    test "handles unicode characters" do
      assert GoogleShared.sanitize_surrogates("Hello 🌍") == "Hello 🌍"
    end

    test "converts non-binary to string" do
      assert GoogleShared.sanitize_surrogates(42) == "42"
    end
  end

  # ============================================================================
  # normalize_sse_message/1
  # ============================================================================

  describe "normalize_sse_message/1" do
    test "returns {:data, data} for direct data tuple" do
      assert GoogleShared.normalize_sse_message({:data, "hello"}) == {:data, "hello"}
    end

    test "returns {:data, data} for nested data tuple" do
      assert GoogleShared.normalize_sse_message({:ref, {:data, "hello"}}) == {:data, "hello"}
    end

    test "returns :done for {:done, _}" do
      assert GoogleShared.normalize_sse_message({:done, :ok}) == :done
    end

    test "returns :done for {_, :done}" do
      assert GoogleShared.normalize_sse_message({:ref, :done}) == :done
    end

    test "returns :done for {_, {:done, _}}" do
      assert GoogleShared.normalize_sse_message({:ref, {:done, :ok}}) == :done
    end

    test "returns :down for DOWN message" do
      assert GoogleShared.normalize_sse_message({:DOWN, make_ref(), :process, self(), :normal}) == :down
    end

    test "returns :ignore for unknown messages" do
      assert GoogleShared.normalize_sse_message(:something_else) == :ignore
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

    test "flash high budget differs from pro" do
      assert GoogleShared.default_budgets_2_5_flash()[:high] < GoogleShared.default_budgets_2_5_pro()[:high]
    end
  end

  describe "get_thinking_budget/3" do
    test "uses custom budget when present" do
      m = model(id: "gemini-2.5-pro")
      assert GoogleShared.get_thinking_budget(m, :high, %{high: 99999}) == 99999
    end

    test "uses 2.5 pro defaults for pro model" do
      m = model(id: "gemini-2.5-pro")
      assert GoogleShared.get_thinking_budget(m, :medium, %{}) == 8192
    end

    test "uses 2.5 flash defaults for flash model" do
      m = model(id: "gemini-2.5-flash")
      assert GoogleShared.get_thinking_budget(m, :high, %{}) == 24576
    end

    test "returns -1 for unknown model" do
      m = model(id: "some-other-model")
      assert GoogleShared.get_thinking_budget(m, :high, %{}) == -1
    end

    test "returns -1 for unknown effort level" do
      m = model(id: "gemini-2.5-pro")
      assert GoogleShared.get_thinking_budget(m, :xhigh, %{}) == -1
    end
  end

  # ============================================================================
  # Model Detection
  # ============================================================================

  describe "gemini_3_pro?/1" do
    test "returns true for gemini-3-pro" do
      assert GoogleShared.gemini_3_pro?("gemini-3-pro")
    end

    test "returns true for gemini-3-pro variant" do
      assert GoogleShared.gemini_3_pro?("gemini-3-pro-latest")
    end

    test "returns false for gemini-3-flash" do
      refute GoogleShared.gemini_3_pro?("gemini-3-flash")
    end

    test "returns false for gemini-2.5-pro" do
      refute GoogleShared.gemini_3_pro?("gemini-2.5-pro")
    end
  end

  describe "gemini_3_flash?/1" do
    test "returns true for gemini-3-flash" do
      assert GoogleShared.gemini_3_flash?("gemini-3-flash")
    end

    test "returns false for gemini-3-pro" do
      refute GoogleShared.gemini_3_flash?("gemini-3-pro")
    end

    test "returns false for gemini-2.5-flash" do
      refute GoogleShared.gemini_3_flash?("gemini-2.5-flash")
    end
  end

  # ============================================================================
  # get_gemini_3_thinking_level/2
  # ============================================================================

  describe "get_gemini_3_thinking_level/2" do
    test "pro model maps minimal to LOW" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-pro") == "LOW"
    end

    test "pro model maps low to LOW" do
      assert GoogleShared.get_gemini_3_thinking_level(:low, "gemini-3-pro") == "LOW"
    end

    test "pro model maps medium to HIGH" do
      assert GoogleShared.get_gemini_3_thinking_level(:medium, "gemini-3-pro") == "HIGH"
    end

    test "pro model maps high to HIGH" do
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-pro") == "HIGH"
    end

    test "non-pro model maps minimal to MINIMAL" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-flash") == "MINIMAL"
    end

    test "non-pro model maps each level directly" do
      assert GoogleShared.get_gemini_3_thinking_level(:low, "gemini-3-flash") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:medium, "gemini-3-flash") == "MEDIUM"
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-flash") == "HIGH"
    end
  end

  # ============================================================================
  # clamp_reasoning/1
  # ============================================================================

  describe "clamp_reasoning/1" do
    test "returns nil for nil" do
      assert GoogleShared.clamp_reasoning(nil) == nil
    end

    test "clamps :xhigh to :high" do
      assert GoogleShared.clamp_reasoning(:xhigh) == :high
    end

    test "passes through valid levels" do
      assert GoogleShared.clamp_reasoning(:minimal) == :minimal
      assert GoogleShared.clamp_reasoning(:low) == :low
      assert GoogleShared.clamp_reasoning(:medium) == :medium
      assert GoogleShared.clamp_reasoning(:high) == :high
    end

    test "returns nil for unknown levels" do
      assert GoogleShared.clamp_reasoning(:turbo) == nil
    end
  end

  # ============================================================================
  # extract_retry_delay/2
  # ============================================================================

  describe "extract_retry_delay/2" do
    test "extracts from retry-after header" do
      delay = GoogleShared.extract_retry_delay("some error", %{"retry-after" => "5.0"})
      assert delay == 6000
    end

    test "extracts from x-ratelimit-reset-after header" do
      delay = GoogleShared.extract_retry_delay("some error", %{"x-ratelimit-reset-after" => "10.0"})
      assert delay == 11000
    end

    test "extracts seconds from 'quota will reset after Xs' pattern" do
      delay = GoogleShared.extract_retry_delay("Your quota will reset after 39s")
      assert delay == 40000
    end

    test "extracts hours/minutes/seconds from 'quota will reset after XhYmZs'" do
      delay = GoogleShared.extract_retry_delay("Your quota will reset after 1h2m3s")
      # 1*3600 + 2*60 + 3 = 3723 seconds = 3723000ms, +1000 = 3724000
      assert delay == 3_724_000
    end

    test "extracts from 'Please retry in Xs'" do
      delay = GoogleShared.extract_retry_delay("Please retry in 5s")
      assert delay == 6000
    end

    test "extracts from 'Please retry in Xms'" do
      delay = GoogleShared.extract_retry_delay("Please retry in 500ms")
      assert delay == 1500
    end

    test "extracts from retryDelay JSON field" do
      delay = GoogleShared.extract_retry_delay(~s("retryDelay": "34.074824224s"))
      assert delay == 35_075
    end

    test "returns nil when no pattern matches" do
      assert GoogleShared.extract_retry_delay("some random error") == nil
    end

    test "headers take priority over text patterns" do
      delay = GoogleShared.extract_retry_delay("Please retry in 100s", %{"retry-after" => "5.0"})
      assert delay == 6000
    end
  end

  # ============================================================================
  # retryable_error?/2
  # ============================================================================

  describe "retryable_error?/2" do
    test "returns true for 429 status" do
      assert GoogleShared.retryable_error?(429, "")
    end

    test "returns true for 500 status" do
      assert GoogleShared.retryable_error?(500, "")
    end

    test "returns true for 502 status" do
      assert GoogleShared.retryable_error?(502, "")
    end

    test "returns true for 503 status" do
      assert GoogleShared.retryable_error?(503, "")
    end

    test "returns true for 504 status" do
      assert GoogleShared.retryable_error?(504, "")
    end

    test "returns false for 400 status with no matching text" do
      refute GoogleShared.retryable_error?(400, "bad request")
    end

    test "returns true when error text contains resource exhausted" do
      assert GoogleShared.retryable_error?(400, "RESOURCE_EXHAUSTED: quota exceeded")
    end

    test "returns true when error text contains rate limit" do
      assert GoogleShared.retryable_error?(400, "rate limit exceeded")
    end

    test "returns true when error text contains overloaded" do
      assert GoogleShared.retryable_error?(400, "model is overloaded")
    end

    test "returns true when error text contains service unavailable" do
      assert GoogleShared.retryable_error?(400, "service unavailable")
    end

    test "returns true when error text contains other side closed" do
      assert GoogleShared.retryable_error?(0, "other side closed the connection")
    end
  end

  # ============================================================================
  # extract_error_message/1
  # ============================================================================

  describe "extract_error_message/1" do
    test "extracts message from JSON error" do
      json = Jason.encode!(%{"error" => %{"message" => "Quota exceeded"}})
      assert GoogleShared.extract_error_message(json) == "Quota exceeded"
    end

    test "returns raw text when not JSON" do
      assert GoogleShared.extract_error_message("plain error text") == "plain error text"
    end

    test "returns raw text when JSON has unexpected structure" do
      json = Jason.encode!(%{"errors" => ["something"]})
      assert GoogleShared.extract_error_message(json) == json
    end
  end

  # ============================================================================
  # calculate_cost/2
  # ============================================================================

  describe "calculate_cost/2" do
    test "calculates cost correctly" do
      m = model(cost: %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0})

      usage = %{input: 1_000_000, output: 100_000, cache_read: 500_000, cache_write: 0}
      result = GoogleShared.calculate_cost(m, usage)

      assert result.cost.input == 1.25
      assert result.cost.output == 0.5
      assert result.cost.cache_read == 0.15625
      assert result.cost.cache_write == 0.0
      assert result.cost.total == 1.90625
    end

    test "preserves original usage fields" do
      m = model(cost: %ModelCost{input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 0.0})
      usage = %{input: 100, output: 200, cache_read: 0, cache_write: 0}
      result = GoogleShared.calculate_cost(m, usage)

      assert result.input == 100
      assert result.output == 200
    end

    test "calculates zero cost for zero usage" do
      m = model(cost: %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0})
      usage = %{input: 0, output: 0, cache_read: 0, cache_write: 0}
      result = GoogleShared.calculate_cost(m, usage)

      assert result.cost.total == 0.0
    end
  end
end
