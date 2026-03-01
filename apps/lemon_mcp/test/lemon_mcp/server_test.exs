defmodule LemonMCP.ServerTest do
  @moduledoc """
  Tests for the LemonMCP.Server module.
  """

  use ExUnit.Case, async: true

  alias LemonMCP.Protocol
  alias LemonMCP.Server

  @moduletag :capture_log

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Start a test server
    {:ok, server} =
      Server.start_link(
        server_name: "Test Server",
        server_version: "1.0.0",
        tools: [
          %Protocol.Tool{
            name: "echo",
            description: "Echoes the input",
            inputSchema: %{
              "type" => "object",
              "properties" => %{
                "message" => %{
                  "type" => "string",
                  "description" => "Message to echo"
                }
              },
              "required" => ["message"]
            }
          }
        ],
        tool_handler: fn name, args ->
          case name do
            "echo" ->
              result = %Protocol.ToolCallResult{
                content: [%{type: "text", text: args["message"]}],
                isError: false
              }

              {:ok, result}

            _ ->
              {:error, :unknown_tool}
          end
        end
      )

    %{server: server}
  end

  # ============================================================================
  # Initialization Tests
  # ============================================================================

  describe "initialization" do
    test "starts with correct server info", %{server: server} do
      result = Server.get_initialize_result(server)

      assert result.result.protocolVersion == LemonMCP.protocol_version()
      assert result.result.serverInfo.name == "Test Server"
      assert result.result.serverInfo.version == "1.0.0"
    end

    test "starts uninitialized", %{server: server} do
      assert Server.initialized?(server) == false
    end

    test "can be marked as initialized", %{server: server} do
      assert :ok = Server.mark_initialized(server)
      assert Server.initialized?(server) == true
    end
  end

  # ============================================================================
  # Tool Management Tests
  # ============================================================================

  describe "tool management" do
    test "lists available tools", %{server: server} do
      tools = Server.list_tools(server)

      assert length(tools) == 1
      [tool] = tools
      assert tool.name == "echo"
      assert tool.description == "Echoes the input"
    end

    test "lists tools with correct schema", %{server: server} do
      tools = Server.list_tools(server)
      [tool] = tools

      assert tool.inputSchema["type"] == "object"
      assert tool.inputSchema["properties"]["message"]["type"] == "string"
      assert "message" in tool.inputSchema["required"]
    end
  end

  # ============================================================================
  # Tool Execution Tests
  # ============================================================================

  describe "tool execution" do
    test "calls tool and returns result", %{server: server} do
      {:ok, result} = Server.call_tool(server, "echo", %{"message" => "hello"})

      assert result.isError == false
      assert length(result.content) == 1
      [content] = result.content
      assert content.type == "text"
      assert content.text == "hello"
    end

    test "returns error for unknown tool", %{server: server} do
      result = Server.call_tool(server, "unknown", %{})
      assert result == {:error, :unknown_tool}
    end
  end

  # ============================================================================
  # Capability Tests
  # ============================================================================

  describe "capabilities" do
    test "returns default capabilities", %{server: server} do
      caps = Server.get_capabilities(server)

      assert caps[:tools] == true
    end

    test "initialize result includes capabilities", %{server: server} do
      result = Server.get_initialize_result(server)

      assert result.result.capabilities["tools"] == %{}
    end
  end

  # ============================================================================
  # Tool Provider Behaviour Tests
  # ============================================================================

  describe "with tool provider module" do
    defmodule TestToolProvider do
      @behaviour LemonMCP.Server

      alias LemonMCP.Protocol

      @impl true
      def list_tools do
        [
          %Protocol.Tool{
            name: "test_tool",
            description: "A test tool",
            inputSchema: %{"type" => "object", "properties" => %{}}
          }
        ]
      end

      @impl true
      def call_tool("test_tool", _args) do
        {:ok,
         %Protocol.ToolCallResult{
           content: [%{type: "text", text: "test result"}],
           isError: false
         }}
      end

      @impl true
      def call_tool(_name, _args) do
        {:error, :unknown_tool}
      end
    end

    test "uses tool provider module" do
      {:ok, server} =
        Server.start_link(
          server_name: "Provider Test Server",
          tool_provider: TestToolProvider
        )

      tools = Server.list_tools(server)
      assert length(tools) == 1
      [tool] = tools
      assert tool.name == "test_tool"

      {:ok, result} = Server.call_tool(server, "test_tool", %{"arg" => "value"})
      assert result.isError == false
      [content] = result.content
      assert content.text == "test result"
    end
  end

  # ============================================================================
  # Named Server Tests
  # ============================================================================

  describe "named servers" do
    test "can register with a name" do
      name = :test_named_server

      {:ok, server} =
        Server.start_link(
          name: name,
          server_name: "Named Server",
          tools: []
        )

      assert Process.whereis(name) == server

      # Clean up
      Process.exit(server, :normal)
    end
  end
end
