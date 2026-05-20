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
        end,
        resources: [%{"uri" => "fixture://status", "name" => "Status"}],
        resource_handler: fn
          "fixture://status" -> {:ok, [%{"uri" => "fixture://status", "text" => "ok"}]}
          _ -> {:error, :unknown_resource}
        end,
        prompts: [%{"name" => "brief", "description" => "Write a brief"}],
        prompt_handler: fn
          "brief", args ->
            {:ok,
             %{
               "description" => "Write a brief",
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => %{
                     "type" => "text",
                     "text" => "brief:" <> Map.get(args, "topic", "")
                   }
                 }
               ]
             }}

          _, _ ->
            {:error, :unknown_prompt}
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
      assert response.result[:capabilities]["resources"] == %{}
      assert response.result[:capabilities]["prompts"] == %{}
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

    test "rejects non-map params", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "initialize",
        params: nil
      }

      response = Handler.handle_initialize(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_request)
      assert response.error[:message] == "params must be an object"
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

    test "accepts spec notification initialized method", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: nil,
        method: "notifications/initialized",
        params: nil
      }

      response = Handler.handle_request(request, server)

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

    test "returns error for non-map params", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/call",
        params: nil
      }

      response = Handler.handle_tools_call(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_params)
      assert response.error[:message] == "params must be an object"
    end

    test "returns error for non-map arguments", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "tools/call",
        params: %{"name" => "greet", "arguments" => "Alice"}
      }

      response = Handler.handle_tools_call(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_params)
      assert response.error[:message] == "'arguments' must be an object"
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
  # Resources Tests
  # ============================================================================

  describe "resources methods" do
    test "returns error when not initialized", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "resources/list",
        params: nil
      }

      response = Handler.handle_resources_list(request, server)

      assert response.error[:code] == Protocol.error_code(:server_not_initialized)
    end

    test "lists and reads resources when initialized", %{server: server} do
      Server.mark_initialized(server)

      list_request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "resources/list",
        params: nil
      }

      read_request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "2",
        method: "resources/read",
        params: %{"uri" => "fixture://status"}
      }

      list_response = Handler.handle_resources_list(list_request, server)
      read_response = Handler.handle_resources_read(read_request, server)

      assert [%{"uri" => "fixture://status"}] = list_response.result[:resources]
      assert [%{"text" => "ok"}] = read_response.result[:contents]
    end

    test "validates resource read params", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "resources/read",
        params: %{}
      }

      response = Handler.handle_resources_read(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_params)
    end
  end

  # ============================================================================
  # Prompts Tests
  # ============================================================================

  describe "prompts methods" do
    test "returns error when not initialized", %{server: server} do
      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "prompts/list",
        params: nil
      }

      response = Handler.handle_prompts_list(request, server)

      assert response.error[:code] == Protocol.error_code(:server_not_initialized)
    end

    test "lists and gets prompts when initialized", %{server: server} do
      Server.mark_initialized(server)

      list_request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "prompts/list",
        params: nil
      }

      get_request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "2",
        method: "prompts/get",
        params: %{"name" => "brief", "arguments" => %{"topic" => "beam"}}
      }

      list_response = Handler.handle_prompts_list(list_request, server)
      get_response = Handler.handle_prompts_get(get_request, server)

      assert [%{"name" => "brief"}] = list_response.result[:prompts]
      assert [%{"role" => "user"}] = get_response.result["messages"]
    end

    test "validates prompt get arguments", %{server: server} do
      Server.mark_initialized(server)

      request = %Protocol.JSONRPCRequest{
        jsonrpc: "2.0",
        id: "1",
        method: "prompts/get",
        params: %{"name" => "brief", "arguments" => "bad"}
      }

      response = Handler.handle_prompts_get(request, server)

      assert response.error[:code] == Protocol.error_code(:invalid_params)
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
