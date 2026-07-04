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

  describe "resource and prompt request builders" do
    test "creates resource list and read requests" do
      list = Protocol.resource_list_request(id: "resources-1")
      read = Protocol.resource_read_request(id: "read-1", uri: "file://safe")

      assert list.method == "resources/list"
      assert list.id == "resources-1"
      assert read.method == "resources/read"
      assert read.params.uri == "file://safe"
    end

    test "creates prompt list and get requests" do
      list = Protocol.prompt_list_request(id: "prompts-1")

      get =
        Protocol.prompt_get_request(id: "get-1", name: "review", arguments: %{"topic" => "mcp"})

      assert list.method == "prompts/list"
      assert list.id == "prompts-1"
      assert get.method == "prompts/get"
      assert get.params.name == "review"
      assert get.params.arguments == %{"topic" => "mcp"}
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
      request =
        Protocol.tool_call_request(
          id: "call-1",
          name: "test_tool",
          arguments: %{"key" => "value"}
        )

      {:ok, json} = Protocol.encode(request)

      decoded = Jason.decode!(json)
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "test_tool"
      assert decoded["params"]["arguments"]["key"] == "value"
    end

    test "encodes generic JSON-RPC responses" do
      response = Protocol.create_response("sample-1", %{"role" => "assistant"})

      {:ok, json} = Protocol.encode(response)

      assert %{
               "jsonrpc" => "2.0",
               "id" => "sample-1",
               "result" => %{"role" => "assistant"}
             } = Jason.decode!(json)
    end

    test "encodes resource and prompt requests" do
      {:ok, resource_json} =
        Protocol.resource_read_request(id: "read-1", uri: "file://safe")
        |> Protocol.encode()

      {:ok, prompt_json} =
        Protocol.prompt_get_request(
          id: "prompt-1",
          name: "brief",
          arguments: %{"topic" => "beam"}
        )
        |> Protocol.encode()

      resource = Jason.decode!(resource_json)
      prompt = Jason.decode!(prompt_json)

      assert resource["method"] == "resources/read"
      assert resource["params"]["uri"] == "file://safe"
      assert prompt["method"] == "prompts/get"
      assert prompt["params"]["name"] == "brief"
      assert prompt["params"]["arguments"] == %{"topic" => "beam"}
    end
  end

  describe "encode!/1" do
    test "encodes a request to JSON" do
      request = Protocol.tool_list_request(id: "1")
      json = Protocol.encode!(request)

      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "1"
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
      assert response.result.serverInfo.version == "1.0.0"
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

    test "decodes a null-result response as a raw passthrough instead of crashing" do
      # Some servers ack requests with "result": null; seen in CI as a
      # BadMapError from Map.has_key?("serverInfo", nil).
      json = ~s|{"jsonrpc": "2.0", "id": "ack-1", "result": null}|

      assert {:ok, response} = Protocol.decode(json)
      assert response == %{"jsonrpc" => "2.0", "id" => "ack-1", "result" => nil}
    end

    test "decodes a scalar-result response as a raw passthrough" do
      json = ~s|{"jsonrpc": "2.0", "id": "ack-2", "result": 42}|

      assert {:ok, response} = Protocol.decode(json)
      assert response == %{"jsonrpc" => "2.0", "id" => "ack-2", "result" => 42}
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

    test "decodes resource list and read responses" do
      list_json = ~s|{
        "jsonrpc": "2.0",
        "id": "resources-1",
        "result": {
          "resources": [{"uri": "file://safe", "name": "Safe Resource"}]
        }
      }|

      read_json = ~s|{
        "jsonrpc": "2.0",
        "id": "read-1",
        "result": {
          "contents": [{"uri": "file://safe", "text": "hello"}]
        }
      }|

      {:ok, list_response} = Protocol.decode(list_json)
      {:ok, read_response} = Protocol.decode(read_json)

      assert %Protocol.ResourceListResponse{} = list_response
      assert [%{"uri" => "file://safe"}] = list_response.result.resources
      assert %Protocol.ResourceReadResponse{} = read_response
      assert [%{"text" => "hello"}] = read_response.result.contents
    end

    test "decodes prompt list and get responses" do
      list_json = ~s|{
        "jsonrpc": "2.0",
        "id": "prompts-1",
        "result": {
          "prompts": [{"name": "brief", "description": "Brief prompt"}]
        }
      }|

      get_json = ~s|{
        "jsonrpc": "2.0",
        "id": "get-1",
        "result": {
          "description": "Brief prompt",
          "messages": [{"role": "user", "content": {"type": "text", "text": "hello"}}]
        }
      }|

      {:ok, list_response} = Protocol.decode(list_json)
      {:ok, get_response} = Protocol.decode(get_json)

      assert %Protocol.PromptListResponse{} = list_response
      assert [%{"name" => "brief"}] = list_response.result.prompts
      assert %Protocol.PromptGetResponse{} = get_response
      assert get_response.result.description == "Brief prompt"
      assert [%{"role" => "user"}] = get_response.result.messages
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
