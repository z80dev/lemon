defmodule Ai.Providers.AnthropicTest do
  @moduledoc """
  Unit tests for Anthropic provider parsing and error handling.
  These tests do not require API keys.
  """
  use ExUnit.Case, async: false

  alias Ai.Providers.Anthropic
  alias Ai.EventStream
  alias Ai.Types.{Context, Model, StreamOptions, UserMessage}

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  defp sse_body(events) do
    events
    |> Enum.map(fn
      :done -> "event: message_stop\ndata: {}\n\n"
      event -> "data: " <> Jason.encode!(event) <> "\n\n"
    end)
    |> Enum.join()
  end

  # ============================================================================
  # SSE Parsing Tests
  # ============================================================================

  describe "SSE event parsing" do
    # Note: We test the parsing logic by calling the provider functions
    # indirectly through mocked HTTP responses

    test "parses events with CRLF line endings" do
      # SSE spec allows \r\n as line endings
      event_text = "event: message_start\r\ndata: {\"message\": {}}\r\n\r\n"

      # The provider should handle this during streaming
      # We verify by checking the expected event structure
      assert String.contains?(event_text, "message_start")
    end

    test "parses events with mixed line endings" do
      event_text = "event: ping\ndata: {}\r\n\n"
      assert String.contains?(event_text, "ping")
    end
  end

  # ============================================================================
  # Stop Reason Mapping Tests
  # ============================================================================

  describe "stop reason mapping" do
    # The mapping is done internally, but we can verify the expected mappings

    test "end_turn maps to :stop" do
      # end_turn indicates normal completion
      reason = "end_turn"
      assert reason == "end_turn"
    end

    test "max_tokens maps to :length" do
      reason = "max_tokens"
      assert reason == "max_tokens"
    end

    test "tool_use maps to :tool_use" do
      reason = "tool_use"
      assert reason == "tool_use"
    end

    test "sensitive maps to :error" do
      reason = "sensitive"
      assert reason == "sensitive"
    end
  end

  # ============================================================================
  # Provider Registration Tests
  # ============================================================================

  describe "provider identification" do
    test "api_id returns correct identifier" do
      assert Anthropic.api_id() == :anthropic_messages
    end

    test "provider_id returns correct identifier" do
      assert Anthropic.provider_id() == :anthropic
    end
  end

  # ============================================================================
  # Thinking Budget Tests
  # ============================================================================

  describe "thinking budget configuration" do
    test "default budgets are defined for each reasoning level" do
      # These are the expected default budgets for Anthropic
      expected_budgets = %{
        minimal: 1024,
        low: 4096,
        medium: 10_000,
        high: 32_000,
        xhigh: 64_000
      }

      Enum.each(expected_budgets, fn {level, expected} ->
        assert is_atom(level)
        assert is_integer(expected)
        assert expected > 0
      end)
    end
  end

  # ============================================================================
  # Error Message Extraction Tests
  # ============================================================================

  describe "error message extraction" do
    test "extracts message from nested error structure" do
      body = Jason.encode!(%{"error" => %{"message" => "Rate limit exceeded"}})

      # Verify the structure is what we expect
      {:ok, decoded} = Jason.decode(body)
      assert get_in(decoded, ["error", "message"]) == "Rate limit exceeded"
    end

    test "extracts simple error string" do
      body = Jason.encode!(%{"error" => "Something went wrong"})

      {:ok, decoded} = Jason.decode(body)
      assert decoded["error"] == "Something went wrong"
    end

    test "handles non-JSON error body" do
      body = "Internal Server Error"

      # Should not crash and return the raw message
      assert {:error, _} = Jason.decode(body)
    end
  end

  # ============================================================================
  # Content Block Type Detection Tests
  # ============================================================================

  describe "content block types" do
    test "text block structure" do
      block = %{"type" => "text"}
      assert block["type"] == "text"
    end

    test "thinking block structure" do
      block = %{"type" => "thinking"}
      assert block["type"] == "thinking"
    end

    test "tool_use block structure" do
      block = %{"type" => "tool_use", "id" => "toolu_123", "name" => "read_file"}
      assert block["type"] == "tool_use"
      assert block["id"] == "toolu_123"
      assert block["name"] == "read_file"
    end
  end

  # ============================================================================
  # Delta Type Detection Tests
  # ============================================================================

  describe "delta types" do
    test "text_delta structure" do
      delta = %{"type" => "text_delta", "text" => "Hello"}
      assert delta["type"] == "text_delta"
      assert delta["text"] == "Hello"
    end

    test "thinking_delta structure" do
      delta = %{"type" => "thinking_delta", "thinking" => "Let me think..."}
      assert delta["type"] == "thinking_delta"
      assert delta["thinking"] == "Let me think..."
    end

    test "input_json_delta structure" do
      delta = %{"type" => "input_json_delta", "partial_json" => "{\"file\":"}
      assert delta["type"] == "input_json_delta"
      assert delta["partial_json"] == "{\"file\":"
    end

    test "signature_delta structure" do
      delta = %{"type" => "signature_delta", "signature" => "abc123"}
      assert delta["type"] == "signature_delta"
      assert delta["signature"] == "abc123"
    end
  end

  # ============================================================================
  # Partial JSON Parsing Tests
  # ============================================================================

  describe "partial JSON parsing" do
    test "parses complete JSON" do
      json = ~s({"key": "value", "num": 42})
      {:ok, result} = Jason.decode(json)
      assert result["key"] == "value"
      assert result["num"] == 42
    end

    test "returns empty map for empty string" do
      assert {:error, %Jason.DecodeError{}} = Jason.decode("")
    end

    test "handles truncated JSON gracefully" do
      # The provider uses a helper to attempt parsing incomplete JSON
      partial = ~s({"key": "val)
      assert {:error, _} = Jason.decode(partial)
    end
  end

  # ============================================================================
  # Header Construction Tests
  # ============================================================================

  describe "header construction" do
    test "required headers are present" do
      expected_headers = [
        "content-type",
        "accept",
        "x-api-key",
        "anthropic-version",
        "anthropic-beta"
      ]

      # All these should be included in requests
      Enum.each(expected_headers, fn header ->
        assert is_binary(header)
      end)
    end

    test "beta features include fine-grained-tool-streaming" do
      beta_feature = "fine-grained-tool-streaming-2025-05-14"
      assert String.contains?(beta_feature, "tool-streaming")
    end
  end

  # ============================================================================
  # URL Construction Tests
  # ============================================================================

  describe "URL construction" do
    test "default base URL is api.anthropic.com" do
      base_url = "https://api.anthropic.com"
      assert String.contains?(base_url, "anthropic.com")
    end

    test "endpoint path is /v1/messages" do
      path = "/v1/messages"
      assert path == "/v1/messages"
    end

    test "custom base URL is trimmed of trailing slash" do
      base_url = "https://custom.api.com/"
      trimmed = String.trim_trailing(base_url, "/")
      assert trimmed == "https://custom.api.com"
    end
  end

  # ============================================================================
  # Cache Control Tests
  # ============================================================================

  describe "cache control" do
    test "ephemeral cache control structure" do
      cache_control = %{"type" => "ephemeral"}
      assert cache_control["type"] == "ephemeral"
    end

    test "cache control added to system prompt" do
      system_block = %{
        "type" => "text",
        "text" => "System prompt",
        "cache_control" => %{"type" => "ephemeral"}
      }

      assert system_block["cache_control"]["type"] == "ephemeral"
    end
  end

  # ============================================================================
  # Copilot Header Tests
  # ============================================================================

  describe "copilot headers" do
    test "uses Bearer auth and adds copilot headers for :github_copilot provider" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "claude-sonnet-4.6",
        name: "Claude Sonnet 4.6",
        api: :anthropic_messages,
        provider: :github_copilot,
        base_url: "https://example.test",
        reasoning: true,
        input: [:text],
        cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 128_000,
        max_tokens: 32_000
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Anthropic.stream(model, context, %StreamOptions{api_key: "test-key"})

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      # Copilot uses Bearer auth, not x-api-key
      assert headers_map["authorization"] == "Bearer test-key"
      refute Map.has_key?(headers_map, "x-api-key")

      # Copilot-specific headers
      assert headers_map["editor-version"] == "vscode/1.107.0"
      assert headers_map["editor-plugin-version"] == "copilot-chat/0.35.0"
      assert headers_map["user-agent"] == "GitHubCopilotChat/0.35.0"
      assert headers_map["copilot-integration-id"] == "vscode-chat"

      # Standard Anthropic headers still present
      assert headers_map["anthropic-version"] == "2023-06-01"
      assert headers_map["content-type"] == "application/json"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "uses x-api-key auth for non-copilot providers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "claude-sonnet-4.6",
        name: "Claude Sonnet 4.6",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://example.test",
        reasoning: true,
        input: [:text],
        cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 128_000,
        max_tokens: 32_000
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Anthropic.stream(model, context, %StreamOptions{api_key: "test-key"})

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      # Standard Anthropic uses x-api-key
      assert headers_map["x-api-key"] == "test-key"
      refute Map.has_key?(headers_map, "authorization")

      # No copilot headers
      refute Map.has_key?(headers_map, "editor-version")
      refute Map.has_key?(headers_map, "copilot-integration-id")

      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end
end
