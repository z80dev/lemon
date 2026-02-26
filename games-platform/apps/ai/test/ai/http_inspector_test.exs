defmodule Ai.HttpInspectorTest do
  use ExUnit.Case, async: true

  alias Ai.HttpInspector

  describe "capture_request/7" do
    test "creates a dump struct with all fields" do
      dump =
        HttpInspector.capture_request(
          "openai",
          "chat",
          "gpt-4",
          "POST",
          "https://api.openai.com/v1/chat/completions",
          [{"authorization", "Bearer sk-secret"}, {"content-type", "application/json"}],
          ~s({"model":"gpt-4"})
        )

      assert dump.provider == "openai"
      assert dump.api == "chat"
      assert dump.model == "gpt-4"
      assert dump.method == "POST"
      assert dump.url == "https://api.openai.com/v1/chat/completions"
      assert length(dump.headers) == 2
      assert dump.body == ~s({"model":"gpt-4"})
      assert is_binary(dump.timestamp)
    end
  end

  describe "sanitize_dump/1" do
    test "redacts sensitive headers" do
      dump =
        HttpInspector.capture_request(
          "anthropic",
          "messages",
          "claude-3",
          "POST",
          "https://api.anthropic.com/v1/messages",
          [
            {"Authorization", "Bearer sk-secret-key"},
            {"x-api-key", "ant-key-123"},
            {"Cookie", "session=abc"},
            {"Proxy-Authorization", "Basic creds"},
            {"content-type", "application/json"}
          ],
          ""
        )

      sanitized = HttpInspector.sanitize_dump(dump)

      headers_map = Map.new(sanitized.headers)
      assert headers_map["Authorization"] == "[REDACTED]"
      assert headers_map["x-api-key"] == "[REDACTED]"
      assert headers_map["Cookie"] == "[REDACTED]"
      assert headers_map["Proxy-Authorization"] == "[REDACTED]"
      assert headers_map["content-type"] == "application/json"
    end

    test "preserves non-sensitive headers" do
      dump =
        HttpInspector.capture_request(
          "openai",
          "chat",
          "gpt-4",
          "POST",
          "https://example.com",
          [{"content-type", "application/json"}, {"accept", "text/event-stream"}],
          ""
        )

      sanitized = HttpInspector.sanitize_dump(dump)

      headers_map = Map.new(sanitized.headers)
      assert headers_map["content-type"] == "application/json"
      assert headers_map["accept"] == "text/event-stream"
    end
  end

  describe "get_status_code/1" do
    test "extracts from map with :status key" do
      assert HttpInspector.get_status_code(%{status: 401}) == 401
    end

    test "extracts from map with :status_code key" do
      assert HttpInspector.get_status_code(%{status_code: 429}) == 429
    end

    test "extracts from string-keyed map with status" do
      assert HttpInspector.get_status_code(%{"status" => 400}) == 400
    end

    test "extracts from string-keyed map with status_code" do
      assert HttpInspector.get_status_code(%{"status_code" => 422}) == 422
    end

    test "extracts from {:error, %{status: _}} tuple" do
      assert HttpInspector.get_status_code({:error, %{status: 403}}) == 403
    end

    test "extracts from bare integer" do
      assert HttpInspector.get_status_code(500) == 500
    end

    test "returns nil for unrecognized shapes" do
      assert HttpInspector.get_status_code("unknown") == nil
      assert HttpInspector.get_status_code(nil) == nil
      assert HttpInspector.get_status_code(%{}) == nil
    end
  end

  describe "handle_error/3" do
    setup do
      dump =
        HttpInspector.capture_request(
          "openai",
          "chat",
          "gpt-4",
          "POST",
          "https://api.openai.com/v1/chat/completions",
          [{"authorization", "Bearer sk-secret"}],
          ~s({"model":"gpt-4"})
        )

      %{dump: dump}
    end

    test "returns enhanced message on 400-level errors", %{dump: dump} do
      result = HttpInspector.handle_error("Request failed", %{status: 400}, dump)

      assert result =~ "Request failed"
      assert result =~ "[HTTP 400]"
      assert result =~ "request_dump:"
      # Sensitive header should be redacted in the dump
      refute result =~ "sk-secret"
      assert result =~ "[REDACTED]"
    end

    test "returns enhanced message on 422 error", %{dump: dump} do
      result = HttpInspector.handle_error("Validation error", %{status: 422}, dump)

      assert result =~ "Validation error"
      assert result =~ "[HTTP 422]"
    end

    test "returns original message on 500 server error", %{dump: dump} do
      result = HttpInspector.handle_error("Server error", %{status: 500}, dump)

      assert result == "Server error"
    end

    test "returns original message on 200 success", %{dump: dump} do
      result = HttpInspector.handle_error("OK", %{status: 200}, dump)

      assert result == "OK"
    end

    test "returns original message when status is nil", %{dump: dump} do
      result = HttpInspector.handle_error("Unknown error", "some string", dump)

      assert result == "Unknown error"
    end
  end
end
