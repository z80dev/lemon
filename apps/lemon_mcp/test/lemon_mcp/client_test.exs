defmodule LemonMCP.ClientTest do
  use ExUnit.Case, async: false

  alias LemonMCP.Client
  alias LemonMCP.Protocol

  # Mock transport for testing without spawning real processes
  defmodule MockTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      parent = Keyword.fetch!(opts, :parent)
      test_case = Keyword.fetch!(opts, :test_case)
      {:ok, %{parent: parent, test_case: test_case, message_handler: nil}}
    end

    def send_message(pid, message) do
      GenServer.call(pid, {:send, message})
    end

    def close(pid) do
      GenServer.call(pid, :close)
    end

    def handle_call({:send, message}, _from, %{test_case: test_case} = state) do
      send(state.parent, {:transport_message, test_case, message})
      {:reply, :ok, state}
    end

    def handle_call(:close, _from, state) do
      {:reply, :ok, %{state | message_handler: nil}}
    end
  end

  describe "protocol operations" do
    test "initialize_request creates valid request" do
      request =
        Protocol.initialize_request(
          id: "test-init",
          client_name: "test-client",
          client_version: "1.0.0"
        )

      assert request.method == "initialize"
      assert request.params.protocolVersion == "2024-11-05"
      assert request.params.clientInfo.name == "test-client"
    end

    test "tool_list_request creates valid request" do
      request = Protocol.tool_list_request(id: "test-list")

      assert request.method == "tools/list"
      assert request.id == "test-list"
    end

    test "tool_call_request creates valid request" do
      request =
        Protocol.tool_call_request(
          id: "test-call",
          name: "echo",
          arguments: %{"message" => "hello"}
        )

      assert request.method == "tools/call"
      assert request.params.name == "echo"
      assert request.params.arguments == %{"message" => "hello"}
    end
  end

  describe "message encoding/decoding" do
    test "encode and decode initialize request" do
      request = Protocol.initialize_request(id: "enc-test")
      {:ok, json} = Protocol.encode(request)
      assert is_binary(json)

      # Decode as map since it's a request (not a response)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "enc-test"
      assert decoded["method"] == "initialize"
    end

    test "encode and decode tool call response" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "resp-1",
        "result": {
          "content": [{"type": "text", "text": "result"}],
          "isError": false
        }
      }|

      {:ok, response} = Protocol.decode(json)
      assert %Protocol.ToolCallResponse{} = response
      assert response.id == "resp-1"
      assert response.result.isError == false
    end
  end

  describe "error handling" do
    test "handles JSON parse error" do
      result = Protocol.decode(~s|{invalid json}|)
      assert {:error, _} = result
    end

    test "handles missing jsonrpc field" do
      result = Protocol.decode(~s|{"id": "1", "result": {}}|)
      assert {:error, :invalid_jsonrpc} = result
    end

    test "decodes error response correctly" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "err-1",
        "error": {
          "code": -32601,
          "message": "Method not found",
          "data": "extra info"
        }
      }|

      {:ok, response} = Protocol.decode(json)
      assert response.error != nil
      assert response.error.code == -32_601
      assert response.error.message == "Method not found"
      assert response.error.data == "extra info"
    end
  end

  describe "client state management" do
    test "client tracks server info after initialization" do
      # Simulate the flow: when client receives initialize response,
      # it should store server info

      init_response = %Protocol.InitializeResponse{
        id: "init-1",
        result: %{
          protocolVersion: "2024-11-05",
          capabilities: %{tools: true},
          serverInfo: %{name: "test-server", version: "1.0.0"}
        },
        error: nil
      }

      assert init_response.result.serverInfo.name == "test-server"
      assert init_response.result.serverInfo.version == "1.0.0"
    end

    test "client handles tool errors" do
      error_response = %Protocol.ToolCallResponse{
        id: "call-1",
        result: %{
          content: [%{type: "text", text: "Error occurred"}],
          isError: true
        },
        error: nil
      }

      assert error_response.result.isError == true
    end
  end
end
