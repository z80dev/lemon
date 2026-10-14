defmodule LemonAgent.ProxyTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Proxy

  # ============================================================================
  # parse_streaming_json Tests
  # ============================================================================

  describe "parse_streaming_json/1" do
    test "parses complete JSON" do
      assert %{"a" => 1} = Proxy.parse_streaming_json("{\"a\":1}")
    end

    test "parses nested objects" do
      json = ~s({"outer": {"inner": "value"}})
      result = Proxy.parse_streaming_json(json)
      assert result["outer"]["inner"] == "value"
    end

    test "parses arrays" do
      json = ~s({"items": [1, 2, 3]})
      result = Proxy.parse_streaming_json(json)
      assert result["items"] == [1, 2, 3]
    end

    test "handles empty string" do
      assert %{} == Proxy.parse_streaming_json("")
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

    test "completes and parses partial JSON" do
      assert %{"a" => 1} = Proxy.parse_streaming_json("{\"a\":1")
    end

    test "returns empty map for invalid JSON" do
      assert %{} == Proxy.parse_streaming_json("not-json")
    end

    test "completes partial nested objects" do
      json = ~s({"outer": {"inner": "value")
      result = Proxy.parse_streaming_json(json)
      assert result["outer"]["inner"] == "value"
    end

    test "completes partial arrays" do
      json = ~s({"items": [1, 2, 3)
      result = Proxy.parse_streaming_json(json)
      assert result["items"] == [1, 2, 3]
    end

    test "handles nil input" do
      assert %{} == Proxy.parse_streaming_json(nil)
    end

    test "returns empty map for JSON array (not object)" do
      # The function is meant to parse objects for tool arguments
      json = ~s([1, 2, 3])
      result = Proxy.parse_streaming_json(json)
      assert %{} == result
    end
  end
end
