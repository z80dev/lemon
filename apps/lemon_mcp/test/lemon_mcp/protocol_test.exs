defmodule LemonMCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Protocol

  describe "protocol_version/0" do
    test "returns expected version" do
      assert LemonMCP.protocol_version() == "2024-11-05"
    end
  end

  describe "initialize_request/1" do
    test "creates request with default values" do
      request = Protocol.initialize_request()

      assert request.jsonrpc == "2.0"
      assert request.method == "initialize"
      assert request.id != nil
      assert request.params.protocolVersion == "2024-11-05"
      assert request.params.clientInfo.name == "lemon-mcp"
      assert request.params.clientInfo.version == "0.1.0"
      assert request.params.capabilities == %{}
    end

    test "creates request with custom values" do
      request =
        Protocol.initialize_request(
          id: "custom-id",
          protocol_version: "2025-01-01",
          client_name: "my-client",
          client_version: "2.0.0",
          capabilities: %{tools: true}
        )

      assert request.id == "custom-id"
      assert request.params.protocolVersion == "2025-01-01"
      assert request.params.clientInfo.name == "my-client"
      assert request.params.clientInfo.version == "2.0.0"
      assert request.params.capabilities == %{tools: true}
    end
  end

  describe "initialized_notification/0" do
    test "creates notification" do
      notification = Protocol.initialized_notification()

      assert notification.jsonrpc == "2.0"
      assert notification.method == "notifications/initialized"
      assert notification.params == %{}
    end
  end

  describe "tool_list_request/1" do
    test "creates request with default id" do
      request = Protocol.tool_list_request()

      assert request.jsonrpc == "2.0"
      assert request.method == "tools/list"
      assert request.id != nil
      assert request.params == %{}
    end

    test "creates request with custom id" do
      request = Protocol.tool_list_request(id: "my-id")

      assert request.id == "my-id"
    end
  end

  describe "tool_call_request/1" do
    test "creates request with tool name and arguments" do
      request =
        Protocol.tool_call_request(
          id: "call-1",
          name: "read_file",
          arguments: %{"path" => "/tmp/test.txt"}
        )

      assert request.jsonrpc == "2.0"
      assert request.method == "tools/call"
      assert request.id == "call-1"
      assert request.params.name == "read_file"
      assert request.params.arguments == %{"path" => "/tmp/test.txt"}
    end

    test "raises without name" do
      assert_raise ArgumentError, "tool name is required", fn ->
        Protocol.tool_call_request(id: "call-1")
      end
    end

    test "uses empty arguments by default" do
      request = Protocol.tool_call_request(name: "echo")

      assert request.params.arguments == %{}
    end
  end

  describe "encode/1" do
    test "encodes initialize request" do
      request = Protocol.initialize_request(id: "init-1")
      {:ok, json} = Protocol.encode(request)

      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "init-1"
      assert decoded["method"] == "initialize"
      assert decoded["params"]["protocolVersion"] == "2024-11-05"
    end

    test "encodes tool call request" do
      request = Protocol.tool_call_request(id: "call-1", name: "test_tool", arguments: %{"key" => "value"})
      {:ok, json} = Protocol.encode(request)

      decoded = Jason.decode!(json)
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "test_tool"
      assert decoded["params"]["arguments"]["key"] == "value"
    end

    test "encode! raises on error" do
      # Create a struct that can't be encoded
      bad_struct = %{__struct__: Protocol.InitializeRequest, id: self()}

      assert_raise Jason.EncodeError, fn ->
        Protocol.encode!(bad_struct)
      end
    end
  end

  describe "decode/1" do
    test "decodes initialize response" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "init-1",
        "result": {
          "protocolVersion": "2024-11-05",
          "capabilities": {"tools": true},
          "serverInfo": {"name": "test-server", "version": "1.0.0"}
        }
      }|

      {:ok, response} = Protocol.decode(json)

      assert %Protocol.InitializeResponse{} = response
      assert response.id == "init-1"
      assert response.result.protocolVersion == "2024-11-05"
      assert response.result.capabilities == %{"tools" => true}
      assert response.result.serverInfo.name == "test-server"
      assert response.error == nil
    end

    test "decodes tool list response" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "list-1",
        "result": {
          "tools": [
            {"name": "read_file", "description": "Read a file", "inputSchema": {"type": "object"}}
          ]
        }
      }|

      {:ok, response} = Protocol.decode(json)

      assert %Protocol.ToolListResponse{} = response
      assert response.id == "list-1"
      assert length(response.result.tools) == 1
      [tool] = response.result.tools
      assert tool["name"] == "read_file"
    end

    test "decodes tool call response" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "call-1",
        "result": {
          "content": [{"type": "text", "text": "Hello"}],
          "isError": false
        }
      }|

      {:ok, response} = Protocol.decode(json)

      assert %Protocol.ToolCallResponse{} = response
      assert response.id == "call-1"
      assert length(response.result.content) == 1
      assert response.result.isError == false
    end

    test "decodes error response" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "call-1",
        "error": {
          "code": -32601,
          "message": "Method not found"
        }
      }|

      {:ok, response} = Protocol.decode(json)

      assert response.id == "call-1"
      assert response.error != nil
      assert response.error.code == -32_601
      assert response.error.message == "Method not found"
    end

    test "returns error for invalid jsonrpc" do
      json = ~s|{"id": "1", "result": {}}|

      assert {:error, :invalid_jsonrpc} = Protocol.decode(json)
    end

    test "returns error for invalid json" do
      json = ~s|{invalid json}|

      assert {:error, _} = Protocol.decode(json)
    end
  end

  describe "decode_map/1" do
    test "decodes unknown response as map" do
      data = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "result" => %{"unknown_field" => "value"}
      }

      {:ok, result} = Protocol.decode_map(data)

      # Returns as-is since type is unknown
      assert result == data
    end
  end

  describe "JSONRPCError" do
    test "has correct error codes" do
      assert Protocol.JSONRPCError.parse_error() == -32_700
      assert Protocol.JSONRPCError.invalid_request() == -32_600
      assert Protocol.JSONRPCError.method_not_found() == -32_601
      assert Protocol.JSONRPCError.invalid_params() == -32_602
      assert Protocol.JSONRPCError.internal_error() == -32_603
    end
  end
end
