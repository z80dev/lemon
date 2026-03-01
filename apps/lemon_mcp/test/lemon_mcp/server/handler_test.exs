defmodule LemonMCP.Server.HandlerTest do
  @moduledoc """
  Tests for the LemonMCP.Server.Handler module.
  """

  use ExUnit.Case, async: true

  alias LemonMCP.Protocol
  alias LemonMCP.Server
  alias LemonMCP.Server.Handler

  @moduletag :capture_log

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    {:ok, server} =
      Server.start_link(
        server_name: "Handler Test Server",
        server_version: "1.0.0",
        tools: [
          %Protocol.Tool{
            name: "greet",
            description: "Greets a person",
            inputSchema: %{
              "type" => "object",
              "properties" => %{
                "name" => %{
                  "type" => "string",
                  "description" => "Name to greet"
                }
              },
              "required" => ["name"]
            }
          }
        ],
        tool_handler: fn name, args ->
          case name do
            "greet" ->
              greeting = "Hello, #{args["name"]}!"

              {:ok,
               %Protocol.ToolCallResult{
                 content: [%{type: "text", text: greeting}],
                 isError: false
               }}

            _ ->
              {:error, :unknown_tool}
          end
        end
      )

    %{server: server}
  end

  # ============================================================================
  # Initialize Tests
  # ============================================================================

  describe "handle_initialize/2" do
    test "returns server capabilities on initialize", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "initialize",
        params: %{
          "protocolVersion" => LemonMCP.protocol_version(),
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        }
      }

      response = Handler.handle_initialize(request, server)

      assert response.__struct__ == Protocol.JSONRPCResponse
      assert response.id == "1"
      assert response.result[:protocolVersion] == LemonMCP.protocol_version()
      assert response.result[:serverInfo][:name] == "Handler Test Server"
      assert response.result[:capabilities]["tools"] == %{}
    end

    test "rejects unsupported protocol version", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "initialize",
        params: %{
          "protocolVersion" => "invalid-version",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        }
      }

      response = Handler.handle_initialize(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_request)
    end
  end

  # ============================================================================
  # Initialized Notification Tests
  # ============================================================================

  describe "handle_initialized/2" do
    test "marks server as initialized", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: nil,
        method: "initialized",
        params: nil
      }

      response = Handler.handle_initialized(request, server)

      assert response.__struct__ == Protocol.JSONRPCResponse
      assert Server.initialized?(server) == true
    end
  end

  # ============================================================================
  # Tools/List Tests
  # ============================================================================

  describe "handle_tools_list/2" do
    test "returns error when not initialized", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/list",
        params: nil
      }

      response = Handler.handle_tools_list(request, server)

      assert response.error[:code] == Protocol.error_code(:server_not_initialized)
    end

    test "returns tools when initialized", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/list",
        params: nil
      }

      response = Handler.handle_tools_list(request, server)

      assert response.__struct__ == Protocol.JSONRPCResponse
      assert response.id == "1"
      assert is_list(response.result[:tools])
      assert length(response.result[:tools]) == 1

      [tool] = response.result[:tools]
      assert tool[:name] == "greet"
      assert tool[:description] == "Greets a person"
    end
  end

  # ============================================================================
  # Tools/Call Tests
  # ============================================================================

  describe "handle_tools_call/2" do
    test "returns error when not initialized", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/call",
        params: %{"name" => "greet", "arguments" => %{"name" => "World"}}
      }

      response = Handler.handle_tools_call(request, server)

      assert response.error[:code] == Protocol.error_code(:server_not_initialized)
    end

    test "returns error for missing tool name", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/call",
        params: %{"arguments" => %{}}
      }

      response = Handler.handle_tools_call(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_params)
    end

    test "successfully calls a tool", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/call",
        params: %{"name" => "greet", "arguments" => %{"name" => "Alice"}}
      }

      response = Handler.handle_tools_call(request, server)

      assert response.__struct__ == Protocol.JSONRPCResponse
      assert response.id == "1"
      assert response.result[:isError] == false
      assert length(response.result[:content]) == 1

      [content] = response.result[:content]
      assert content[:type] == "text"
      assert content[:text] == "Hello, Alice!"
    end

    test "handles tool execution errors", %{server: server} do
      Server.mark_initialized(server)

      # Create server with failing tool
      {:ok, failing_server} =
        Server.start_link(
          tools: [],
          tool_handler: fn _name, _args ->
            {:error, "Tool failed to execute"}
          end
        )

      Server.mark_initialized(failing_server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/call",
        params: %{"name" => "any_tool", "arguments" => %{}}
      }

      response = Handler.handle_tools_call(request, failing_server)

      assert response.error[:code] == Protocol.error_code(:tool_execution_error)
      assert response.error[:message] == "Tool failed to execute"
    end
  end

  # ============================================================================
  # Method Routing Tests
  # ============================================================================

  describe "handle_request/2" do
    test "routes to correct handler based on method", %{server: server} do
      initialize_request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "initialize",
        params: %{
          "protocolVersion" => LemonMCP.protocol_version(),
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"}
        }
      }

      response = Handler.handle_request(initialize_request, server)
      assert response.__struct__ == Protocol.JSONRPCResponse
    end

    test "returns method_not_found for unknown methods", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "unknown/method",
        params: nil
      }

      response = Handler.handle_request(request, server)

      assert response.error[:code] == Protocol.error_code(:method_not_found)
      assert response.error[:message] =~ "unknown/method"
    end
  end

  # ============================================================================
  # JSON Request Handling Tests
  # ============================================================================

  describe "handle_json_request/2" do
    test "parses and handles JSON request", %{server: server} do
      json_payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => LemonMCP.protocol_version(),
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"}
        }
      }

      {:ok, response} = Handler.handle_json_request(json_payload, server)

      assert response.__struct__ == Protocol.JSONRPCResponse
    end

    test "returns error for invalid request", %{server: server} do
      json_payload = %{"invalid" => "request"}

      {:ok, response} = Handler.handle_json_request(json_payload, server)

      assert response.error[:code] == Protocol.error_code(:parse_error)
    end
  end
end
