defmodule CodingAgent.Wasm.ProtocolTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Wasm.Protocol

  describe "next_id/1" do
    test "generates unique IDs with given prefix" do
      id1 = Protocol.next_id("custom")
      id2 = Protocol.next_id("custom")

      assert String.starts_with?(id1, "custom_")
      assert String.starts_with?(id2, "custom_")
      assert id1 != id2
    end
  end

  describe "next_id/0" do
    test "generates unique IDs with default prefix" do
      id1 = Protocol.next_id()
      id2 = Protocol.next_id()

      assert String.starts_with?(id1, "req_")
      assert String.starts_with?(id2, "req_")
      assert id1 != id2
    end
  end

  describe "encode_request/3" do
    test "creates proper JSONL format with type, id, and payload" do
      result = Protocol.encode_request("test_type", "test_id", %{"key" => "value"})
      json = IO.iodata_to_binary(result)

      assert String.ends_with?(json, "\n")

      decoded = Jason.decode!(json)
      assert decoded["type"] == "test_type"
      assert decoded["id"] == "test_id"
      assert decoded["key"] == "value"
    end

    test "creates proper JSONL format with empty payload" do
      result = Protocol.encode_request("ping", "req_123", %{})
      json = IO.iodata_to_binary(result)

      assert String.ends_with?(json, "\n")

      decoded = Jason.decode!(json)
      assert decoded["type"] == "ping"
      assert decoded["id"] == "req_123"
      assert map_size(decoded) == 2
    end

    test "creates proper JSONL format with default empty payload" do
      result = Protocol.encode_request("init", "req_456")
      json = IO.iodata_to_binary(result)

      assert String.ends_with?(json, "\n")

      decoded = Jason.decode!(json)
      assert decoded["type"] == "init"
      assert decoded["id"] == "req_456"
      assert map_size(decoded) == 2
    end
  end

  describe "decode_line/1" do
    test "parses valid JSON lines" do
      line = ~s({"type":"response","id":"req_123","data":"hello"})

      assert {:ok, %{"type" => "response", "id" => "req_123", "data" => "hello"}} =
               Protocol.decode_line(line)
    end

    test "handles empty JSON object" do
      assert {:ok, %{}} = Protocol.decode_line("{}")
    end

    test "handles invalid JSON" do
      assert {:error, _} = Protocol.decode_line("not valid json")
    end

    test "handles invalid JSON with unclosed brace" do
      assert {:error, _} = Protocol.decode_line(~s({"key":))
    end

    test "handles non-map JSON values - array" do
      assert {:error, {:invalid_message, [1, 2, 3]}} =
               Protocol.decode_line("[1, 2, 3]")
    end

    test "handles non-map JSON values - string" do
      assert {:error, {:invalid_message, "hello"}} =
               Protocol.decode_line(~s("hello"))
    end

    test "handles non-map JSON values - number" do
      assert {:error, {:invalid_message, 42}} =
               Protocol.decode_line("42")
    end

    test "handles non-map JSON values - boolean" do
      assert {:error, {:invalid_message, true}} =
               Protocol.decode_line("true")
    end

    test "handles non-map JSON values - null" do
      assert {:error, {:invalid_message, nil}} =
               Protocol.decode_line("null")
    end
  end
end
