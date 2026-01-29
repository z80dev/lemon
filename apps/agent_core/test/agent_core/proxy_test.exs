defmodule AgentCore.ProxyTest do
  use ExUnit.Case, async: true

  alias AgentCore.Proxy

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
  end
end
