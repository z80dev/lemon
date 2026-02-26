defmodule AgentCore.ProxyTest do
  use ExUnit.Case, async: true

  alias AgentCore.Proxy
  alias AgentCore.Proxy.ProxyStreamOptions

  # ============================================================================
  # ProxyStreamOptions Tests
  # ============================================================================

  describe "ProxyStreamOptions struct" do
    test "creates with default values" do
      options = %ProxyStreamOptions{}

      assert options.auth_token == ""
      assert options.proxy_url == ""
      assert options.temperature == nil
      assert options.max_tokens == nil
      assert options.reasoning == nil
      assert options.signal == nil
    end

    test "creates with required fields" do
      options = %ProxyStreamOptions{
        auth_token: "test-token-123",
        proxy_url: "https://proxy.example.com"
      }

      assert options.auth_token == "test-token-123"
      assert options.proxy_url == "https://proxy.example.com"
    end

    test "creates with all fields" do
      signal_ref = make_ref()

      options = %ProxyStreamOptions{
        auth_token: "bearer-token",
        proxy_url: "https://genai.example.com",
        temperature: 0.7,
        max_tokens: 4096,
        reasoning: :medium,
        signal: signal_ref
      }

      assert options.auth_token == "bearer-token"
      assert options.proxy_url == "https://genai.example.com"
      assert options.temperature == 0.7
      assert options.max_tokens == 4096
      assert options.reasoning == :medium
      assert options.signal == signal_ref
    end

    test "reasoning accepts all valid thinking levels" do
      for level <- [:minimal, :low, :medium, :high, :xhigh] do
        options = %ProxyStreamOptions{reasoning: level}
        assert options.reasoning == level
      end
    end

    test "temperature can be float between 0 and 1" do
      options = %ProxyStreamOptions{temperature: 0.0}
      assert options.temperature == 0.0

      options = %ProxyStreamOptions{temperature: 0.5}
      assert options.temperature == 0.5

      options = %ProxyStreamOptions{temperature: 1.0}
      assert options.temperature == 1.0
    end

    test "max_tokens can be any positive integer" do
      options = %ProxyStreamOptions{max_tokens: 100}
      assert options.max_tokens == 100

      options = %ProxyStreamOptions{max_tokens: 100_000}
      assert options.max_tokens == 100_000
    end

    test "signal stores a reference" do
      ref = make_ref()
      options = %ProxyStreamOptions{signal: ref}
      assert is_reference(options.signal)
    end

    test "can be pattern matched" do
      options = %ProxyStreamOptions{
        auth_token: "token",
        proxy_url: "https://example.com"
      }

      assert %ProxyStreamOptions{auth_token: token} = options
      assert token == "token"
    end

    test "struct can be updated" do
      options = %ProxyStreamOptions{auth_token: "old-token"}
      updated = %{options | auth_token: "new-token"}

      assert updated.auth_token == "new-token"
    end

    test "handles empty auth_token gracefully" do
      options = %ProxyStreamOptions{auth_token: "", proxy_url: "https://example.com"}
      assert options.auth_token == ""
    end

    test "handles empty proxy_url gracefully" do
      options = %ProxyStreamOptions{auth_token: "token", proxy_url: ""}
      assert options.proxy_url == ""
    end
  end

  # ============================================================================
  # parse_streaming_json Tests
  # ============================================================================

  describe "parse_streaming_json/1" do
    test "parses complete JSON" do
      assert %{"a" => 1} = Proxy.parse_streaming_json("{\"a\":1}")
    end

    test "completes and parses partial JSON" do
      assert %{"a" => 1} = Proxy.parse_streaming_json("{\"a\":1")
    end

    test "returns empty map for invalid JSON" do
      assert %{} == Proxy.parse_streaming_json("not-json")
    end

    test "parses nested objects" do
      json = ~s({"outer": {"inner": "value"}})
      result = Proxy.parse_streaming_json(json)
      assert result["outer"]["inner"] == "value"
    end

    test "completes partial nested objects" do
      json = ~s({"outer": {"inner": "value")
      result = Proxy.parse_streaming_json(json)
      assert result["outer"]["inner"] == "value"
    end

    test "parses arrays" do
      json = ~s({"items": [1, 2, 3]})
      result = Proxy.parse_streaming_json(json)
      assert result["items"] == [1, 2, 3]
    end

    test "completes partial arrays" do
      json = ~s({"items": [1, 2, 3)
      result = Proxy.parse_streaming_json(json)
      assert result["items"] == [1, 2, 3]
    end

    test "handles empty string" do
      assert %{} == Proxy.parse_streaming_json("")
    end

    test "handles nil input" do
      assert %{} == Proxy.parse_streaming_json(nil)
    end

    test "handles non-string input" do
      assert %{} == Proxy.parse_streaming_json(123)
    end

    test "parses boolean values" do
      json = ~s({"enabled": true, "disabled": false})
      result = Proxy.parse_streaming_json(json)
      assert result["enabled"] == true
      assert result["disabled"] == false
    end

    test "parses null values" do
      json = ~s({"value": null})
      result = Proxy.parse_streaming_json(json)
      assert result["value"] == nil
    end

    test "parses string with escaped quotes" do
      json = ~s({"text": "hello \\"world\\""})
      result = Proxy.parse_streaming_json(json)
      assert result["text"] == "hello \"world\""
    end

    test "handles deeply nested partial JSON" do
      json = ~s({"a": {"b": {"c": {"d": "deep")
      result = Proxy.parse_streaming_json(json)
      assert result["a"]["b"]["c"]["d"] == "deep"
    end

    test "returns empty map for JSON array (not object)" do
      # The function is meant to parse objects for tool arguments
      json = ~s([1, 2, 3])
      result = Proxy.parse_streaming_json(json)
      assert %{} == result
    end
  end
end
