defmodule LemonAi.Providers.GoogleSharedTest do
  use ExUnit.Case, async: true

  alias LemonAi.Providers.{GoogleShared, StreamTransport}

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    ImageContent,
    Model,
    ModelCost,
    StreamOptions,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

  defp model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "gemini-2.5-pro"),
      provider: Keyword.get(opts, :provider, :google_generative_ai),
      input: Keyword.get(opts, :input, [:text]),
      cost:
        Keyword.get(opts, :cost, %ModelCost{
          input: 1.25,
          output: 5.0,
          cache_read: 0.3125,
          cache_write: 0.0
        })
    }
  end

  defp context(messages) do
    %Context{messages: messages}
  end

  test "only the thought flag identifies a thinking part" do
    for {part, thinking?} <- [
          {%{"thought" => true}, true},
          {%{"thought" => false}, false},
          {%{"text" => "hello"}, false},
          {%{"thoughtSignature" => "YWJj"}, false},
          {%{}, false}
        ] do
      assert GoogleShared.thinking_part?(part) == thinking?
    end
  end

  test "retains the last non-empty thought signature" do
    for {existing, incoming, expected} <- [
          {nil, "new", "new"},
          {"old", "new", "new"},
          {"old", nil, "old"},
          {"old", "", "old"},
          {nil, nil, nil}
        ] do
      assert GoogleShared.retain_thought_signature(existing, incoming) == expected
    end
  end

  test "only replays valid thought signatures to the same model" do
    for {signature, valid?} <- [
          {"YWJj", true},
          {"YWI=", true},
          {"dGVzdA==", true},
          {"abc!", false},
          {"abc", false},
          {"", false},
          {nil, false}
        ] do
      assert GoogleShared.valid_thought_signature?(signature) == valid?

      assert GoogleShared.resolve_thought_signature(true, signature) ==
               if(valid?, do: signature, else: nil)

      assert GoogleShared.resolve_thought_signature(false, signature) == nil
    end
  end

  test "requires explicit tool call IDs only for Claude and GPT-OSS models" do
    for {id, required?} <- [
          {"claude-3.5-sonnet", true},
          {"gpt-oss-20b", true},
          {"gemini-2.5-pro", false},
          {"gpt-4", false}
        ] do
      assert GoogleShared.requires_tool_call_id?(id) == required?
    end
  end

  describe "put_thinking_config/3" do
    test "maps declared reasoning levels without inferring from model IDs" do
      model = %Model{reasoning: true, reasoning_efforts: [:low, :medium, :high]}

      for {effort, expected} <- [
            {:minimal, "LOW"},
            {:low, "LOW"},
            {:medium, "MEDIUM"},
            {:high, "HIGH"},
            {:xhigh, "HIGH"},
            {:max, "HIGH"}
          ] do
        opts = %StreamOptions{reasoning: effort}

        assert GoogleShared.put_thinking_config(%{}, model, opts) == %{
                 "thinkingConfig" => %{
                   "includeThoughts" => true,
                   "thinkingLevel" => expected
                 }
               }
      end
    end

    test "uses levels instead of budgets for level-based models" do
      model = %Model{reasoning: true, reasoning_efforts: [:low, :medium, :high]}
      opts = %StreamOptions{reasoning: :medium, thinking_budgets: %{budget_tokens: 8192}}

      assert GoogleShared.put_thinking_config(%{}, model, opts) == %{
               "thinkingConfig" => %{"includeThoughts" => true, "thinkingLevel" => "MEDIUM"}
             }
    end

    test "normalizes explicit levels and clamps them to the model capabilities" do
      model = %Model{reasoning: true, reasoning_efforts: [:low, :medium, :high]}

      for override <- [:minimal, "minimal", "MINIMAL"] do
        opts = %StreamOptions{reasoning: :high, thinking_budgets: %{level: override}}

        assert GoogleShared.put_thinking_config(%{}, model, opts) == %{
                 "thinkingConfig" => %{"includeThoughts" => true, "thinkingLevel" => "LOW"}
               }
      end
    end

    test "keeps fixed OAuth model tiers rather than changing their reasoning level" do
      model = %Model{reasoning: true, reasoning_efforts: [:medium]}
      opts = %StreamOptions{reasoning: :max, thinking_budgets: %{level: "HIGH"}}

      assert GoogleShared.put_thinking_config(%{}, model, opts) == %{
               "thinkingConfig" => %{"includeThoughts" => true, "thinkingLevel" => "MEDIUM"}
             }
    end

    test "preserves budget configuration for models without declared levels" do
      model = %Model{reasoning: true}

      for opts <- [
            %StreamOptions{reasoning: :medium, thinking_budgets: %{budget_tokens: 8192}},
            %StreamOptions{reasoning: :max, thinking_budgets: %{high: 8192}}
          ] do
        assert GoogleShared.put_thinking_config(%{}, model, opts) == %{
                 "thinkingConfig" => %{"includeThoughts" => true, "thinkingBudget" => 8192}
               }
      end
    end

    test "does not enable thinking for none, nil, or a non-reasoning model" do
      config = %{"maxOutputTokens" => 1024}
      model = %Model{reasoning: true, reasoning_efforts: [:low, :medium, :high]}

      for effort <- [nil, :none] do
        assert GoogleShared.put_thinking_config(config, model, %StreamOptions{reasoning: effort}) ==
                 config
      end

      assert GoogleShared.put_thinking_config(config, %Model{}, %StreamOptions{reasoning: :max}) ==
               config
    end
  end

  describe "convert_messages/2 with UserMessage" do
    test "converts plain text and preserves the order of multipart text" do
      for {content, parts} <- [
            {"Hello", [%{"text" => "Hello"}]},
            {[%TextContent{text: "Part 1"}, %TextContent{text: "Part 2"}],
             [%{"text" => "Part 1"}, %{"text" => "Part 2"}]}
          ] do
        assert GoogleShared.convert_messages(model(), context([%UserMessage{content: content}])) ==
                 [%{"role" => "user", "parts" => parts}]
      end
    end

    test "converts user images only when supported and retains adjacent text" do
      text = %TextContent{text: "Look at this"}
      image = %ImageContent{data: "imgdata", mime_type: "image/jpeg"}
      text_part = %{"text" => "Look at this"}
      image_part = %{"inlineData" => %{"mimeType" => "image/jpeg", "data" => "imgdata"}}

      for {content, input, parts} <- [
            {[], [:text], []},
            {[image], [:text], []},
            {[image], [:text, :image], [image_part]},
            {[text, image], [:text], [text_part]},
            {[text, image], [:text, :image], [text_part, image_part]}
          ] do
        expected = if parts == [], do: [], else: [%{"role" => "user", "parts" => parts}]

        assert GoogleShared.convert_messages(
                 model(input: input),
                 context([%UserMessage{content: content}])
               ) ==
                 expected
      end

      assert GoogleShared.convert_messages(model(), context([])) == []
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

      assert [
               %{
                 "role" => "model",
                 "parts" => [
                   %{"thought" => true, "text" => "Let me think...", "thoughtSignature" => "YWJj"}
                 ]
               }
             ] =
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
                     "functionCall" => %{
                       "name" => "get_weather",
                       "args" => %{"city" => "NYC"},
                       "id" => "call_1"
                     },
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

  describe "convert_tools/1" do
    test "returns nil for empty list" do
      assert GoogleShared.convert_tools([]) == nil
    end

    test "converts tools in order and preserves their schemas" do
      schema = %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }

      tools = [
        %Tool{name: "search", description: "Search tool", parameters: schema},
        %Tool{name: "list", description: "List tool", parameters: %{}}
      ]

      assert [
               %{
                 "functionDeclarations" => [
                   %{"name" => "search", "description" => "Search tool", "parameters" => ^schema},
                   %{"name" => "list", "description" => "List tool", "parameters" => empty}
                 ]
               }
             ] = GoogleShared.convert_tools(tools)

      assert empty == %{}
    end
  end

  test "maps tool choices to Gemini modes and defaults to AUTO" do
    for {choice, mode} <- [
          {:auto, "AUTO"},
          {:none, "NONE"},
          {:any, "ANY"},
          {:unknown, "AUTO"},
          {nil, "AUTO"}
        ] do
      assert GoogleShared.map_tool_choice(choice) == mode
    end
  end

  test "maps stop reasons and treats unknown values as errors" do
    for {reason, expected} <- [
          {"STOP", :stop},
          {"MAX_TOKENS", :length},
          {"SAFETY", :error},
          {"RECITATION", :error},
          {"OTHER", :error},
          {"", :error}
        ] do
      assert GoogleShared.map_stop_reason(reason) == expected
    end
  end

  test "uses the configured Gemini 2.5 budget for each family and effort" do
    for {id, high} <- [{"gemini-2.5-pro", 32_768}, {"gemini-2.5-flash", 24_576}],
        {effort, expected} <- [minimal: 128, low: 2048, medium: 8192, high: high] do
      assert GoogleShared.get_thinking_budget(model(id: id), effort, %{}) == expected
    end
  end

  test "explicit budgets override defaults; unknown model or effort otherwise leaves budget unset" do
    for {id, effort, custom, expected} <- [
          {"gemini-2.5-pro", :high, %{high: 99_999}, 99_999},
          {"gemini-2.5-pro", :low, %{low: 5_000}, 5_000},
          {"gemini-2.5-pro", :xhigh, %{}, -1},
          {"some-other-model", :medium, %{}, -1}
        ] do
      assert GoogleShared.get_thinking_budget(model(id: id), effort, custom) == expected
    end
  end

  test "distinguishes Gemini 3 Pro and Flash model variants from older models" do
    for {id, pro?, flash?} <- [
          {"gemini-3-pro", true, false},
          {"gemini-3-pro-latest", true, false},
          {"gemini-3-flash", false, true},
          {"gemini-3-flash-latest", false, true},
          {"gemini-2.5-pro", false, false},
          {"gemini-2.5-flash", false, false}
        ] do
      assert GoogleShared.gemini_3_pro?(id) == pro?
      assert GoogleShared.gemini_3_flash?(id) == flash?
    end
  end

  test "maps Gemini 3 Pro and Flash thinking levels to their wire values" do
    for {effort, pro, flash} <- [
          {:minimal, "LOW", "MINIMAL"},
          {:low, "LOW", "LOW"},
          {:medium, "HIGH", "MEDIUM"},
          {:high, "HIGH", "HIGH"}
        ] do
      assert GoogleShared.get_gemini_3_thinking_level(effort, "gemini-3-pro") == pro
      assert GoogleShared.get_gemini_3_thinking_level(effort, "gemini-3-flash") == flash
    end
  end

  test "clamps reasoning to supported efforts and drops unknown values" do
    for {effort, expected} <- [
          {nil, nil},
          {:xhigh, :high},
          {:minimal, :minimal},
          {:low, :low},
          {:medium, :medium},
          {:high, :high},
          {:turbo, nil},
          {"string", nil}
        ] do
      assert GoogleShared.clamp_reasoning(effort) == expected
    end
  end

  test "calculates each token cost without modifying the reported usage counters" do
    cost = %ModelCost{input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 1.5}

    for {usage, expected_cost} <- [
          {%{input: 1_000_000, output: 500_000, cache_read: 2_000_000, cache_write: 1_000_000},
           %{input: 1.0, output: 1.0, cache_read: 1.0, cache_write: 1.5, total: 4.5}},
          {%{input: 0, output: 0, cache_read: 0, cache_write: 0},
           %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}},
          {%{input: nil, output: 500, cache_read: 0, cache_write: nil},
           %{input: nil, output: 0.001, cache_read: 0.0, cache_write: nil, total: nil}}
        ] do
      result = GoogleShared.calculate_cost(model(cost: cost), usage)
      assert Map.pop!(result, :cost) == {expected_cost, usage}
    end
  end

  describe "StreamTransport.error_body/1 with safe_http_error/4" do
    test "normalizes both binary and decoded map error bodies for classification" do
      wire_body = ~s({"error":{"message":"Prompt is too long"}})
      decoded_body = %{"error" => %{"message" => "Prompt is too long"}}
      assert StreamTransport.error_body(wire_body) == wire_body

      for body <- [wire_body, decoded_body] do
        normalized = StreamTransport.error_body(body)
        assert Jason.decode!(normalized) == decoded_body

        assert %{status: 400, category: :context_length, retryable: false} =
                 GoogleShared.safe_http_error(400, normalized)
      end
    end

    test "collects async chunks and closes the transport after completion" do
      async = error_body_transport()
      ref = async.ref

      send(self(), {ref, {:data, "{\"error\":{"}})
      send(self(), {ref, {:data, "\"message\":\"Prompt is too long\"}}"}})
      send(self(), {ref, :done})

      text = StreamTransport.error_body(async)

      assert %{status: 400, category: :context_length, retryable: false} =
               GoogleShared.safe_http_error(400, text)

      assert_receive {:transport_canceled, ^ref}
      refute_receive {^ref, _}
    end

    test "timeout closes the transport without inspecting or exposing its state" do
      async = error_body_transport()
      ref = async.ref
      send(self(), :unrelated_message)

      text = StreamTransport.error_body(async, 0)
      assert byte_size(text) <= 16_384
      details = GoogleShared.safe_http_error(401, text)
      assert %{status: 401, category: :auth, retryable: false} = details
      assert byte_size(details.message) in 1..512
      assert details.provider_message == nil
      refute Jason.encode!(details) =~ "Req.Response"
      assert_receive {:transport_canceled, ^ref}
      assert_receive :unrelated_message
    end

    test "oversized bodies stop at the byte bound and clean remaining response messages" do
      async = error_body_transport()
      ref = async.ref
      send(self(), {ref, {:data, "Prompt is too long. " <> String.duplicate("x", 32_768)}})
      send(self(), {ref, {:data, "credential-that-must-not-be-collected"}})
      send(self(), {ref, :done})

      text = StreamTransport.error_body(async)
      assert byte_size(text) <= 16_384
      refute text =~ "credential-that-must-not-be-collected"
      assert %{status: 400, category: :context_length} = GoogleShared.safe_http_error(400, text)
      assert_receive {:transport_canceled, ^ref}
      refute_receive {^ref, _}
    end

    test "transport failure stops collection and closes without inspecting the failure" do
      async = error_body_transport()
      ref = async.ref
      send(self(), {ref, {:data, "Invalid request"}})
      send(self(), {ref, {:error, %{credentials: "private-upstream-token"}}})
      send(self(), {ref, {:data, "private-upstream-token"}})

      text = StreamTransport.error_body(async)
      details = GoogleShared.safe_http_error(400, text)
      assert %{status: 400, category: :client, retryable: false} = details
      refute Jason.encode!(details) =~ "private-upstream-token"
      assert_receive {:transport_canceled, ^ref}
      refute_receive {^ref, _}
    end

    test "the total deadline is not extended by incoming chunks" do
      async = error_body_transport()
      ref = async.ref
      parser = async.stream_fun

      async = %{
        async
        | stream_fun: fn message_ref, message ->
            # Advance beyond the deadline while processing the first chunk.
            # A per-chunk timeout would incorrectly read the queued suffix.
            Process.sleep(100)
            parser.(message_ref, message)
          end
      }

      send(self(), {ref, {:data, "Prompt is too long"}})
      send(self(), {ref, {:data, "suffix-after-deadline"}})
      send(self(), {ref, :done})

      text = StreamTransport.error_body(async, 50)
      refute text =~ "suffix-after-deadline"
      assert %{status: 400, category: :context_length} = GoogleShared.safe_http_error(400, text)
      assert_receive {:transport_canceled, ^ref}
      refute_receive {^ref, _}
    end

    test "byte truncation preserves valid UTF-8 for error classification" do
      text =
        "Prompt is too long. " <>
          String.duplicate("x", 16_364) <> "🌍" <> String.duplicate("x", 32_768)

      normalized = StreamTransport.error_body(text)
      assert byte_size(normalized) <= 16_384
      assert String.valid?(normalized)

      assert %{status: 400, category: :context_length} =
               GoogleShared.safe_http_error(400, normalized)
    end

    test "unknown response structs never become public error details" do
      body = %Req.Response{body: "private-response-credential"}
      normalized = StreamTransport.error_body(body)
      details = GoogleShared.safe_http_error(403, normalized)
      assert %{status: 403, category: :auth, retryable: false} = details
      assert byte_size(details.message) in 1..512
      refute Jason.encode!(details) =~ "private-response-credential"
      refute Jason.encode!(details) =~ "Req.Response"
    end

    test "safe errors preserve rate-limit hints and permanent quota classification" do
      for {body, retryable} <- [
            {"Rate limit exceeded. token=private-retry-token", true},
            {"insufficient_quota. token=private-quota-token", false}
          ] do
        details = GoogleShared.safe_http_error(429, body, %{"retry-after" => ["2"]})
        assert %{status: 429, category: :rate_limit, retryable: ^retryable} = details
        assert details.rate_limit_info.retry_after == 2_000
        assert LemonAi.Error.failover_action(details) == :next_credential
        assert byte_size(details.message) in 1..512
        assert details.provider_message == nil
        refute Jason.encode!(details) =~ "private-"
      end
    end
  end

  defp error_body_transport do
    ref = make_ref()

    %Req.Response.Async{
      ref: ref,
      pid: self(),
      stream_fun: fn
        ^ref, {^ref, {:data, data}} -> {:ok, [data: data]}
        ^ref, {^ref, :done} -> {:ok, [:done]}
        ^ref, {^ref, {:error, reason}} -> {:error, reason}
      end,
      cancel_fun: fn ^ref ->
        drain_error_body(ref)
        send(self(), {:transport_canceled, ref})
        :ok
      end
    }
  end

  defp drain_error_body(ref) do
    receive do
      {^ref, _} -> drain_error_body(ref)
    after
      0 -> :ok
    end
  end
end
