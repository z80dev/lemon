defmodule LemonMCP do
  @moduledoc """
  LemonMCP provides client and server implementations for the Model Context Protocol (MCP).

  MCP is an open protocol that enables seamless integration between LLM applications
  and external data sources and tools. This library provides:

  ## Client Components

  - `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
  - `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
  - `LemonMCP.Client` - GenServer client for managing MCP connections

  ## Server Components

  - `LemonMCP.Server` - MCP server GenServer for hosting tools
  - `LemonMCP.Server.Handler` - Request handler for MCP protocol messages
  - `LemonMCP.Transport.HTTP` - HTTP transport for MCP server
  - `LemonMCP.ToolAdapter` - Adapter for exposing CodingAgent tools via MCP

  ## Quick Start - Client

      # Start a client connection to an MCP server
      {:ok, client} = LemonMCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
      )

      # List available tools
      {:ok, tools} = LemonMCP.Client.list_tools(client)

      # Call a tool
      {:ok, result} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/path/to/file.txt"})

  ## Quick Start - Server

      # Start an HTTP server with Lemon tools
      {:ok, pid} = LemonMCP.Transport.HTTP.start_link(
        port: 4048,
        tool_provider: MyToolProvider
      )

      # Or create a simple server programmatically
      {:ok, server} = LemonMCP.Server.start_link(
        name: :my_server,
        server_name: "My MCP Server",
        server_version: "1.0.0",
        tools: [
          %LemonMCP.Protocol.Tool{
            name: "echo",
            description: "Echoes the input",
            inputSchema: %{
              "type" => "object",
              "properties" => %{
                "message" => %{"type" => "string", "description" => "Message to echo"}
              },
              "required" => ["message"]
            }
          }
        ],
        tool_handler: fn name, args ->
          case name do
            "echo" ->
              result = %LemonMCP.Protocol.ToolCallResult{
                content: [%{type: "text", text: args["message"]}],
                isError: false
              }

              {:ok, result}

            _ ->
              {:error, :unknown_tool}
          end
        end
      )

  ## Using Lemon Tools via MCP

      # Create a tool adapter for your project
      adapter = LemonMCP.ToolAdapter.new("/path/to/project")

      # List tools
      tools = LemonMCP.ToolAdapter.list_tools(adapter)

      # Call tools
      {:ok, result} = LemonMCP.ToolAdapter.call_tool(adapter, "read", %{"path" => "README.md"})

  ## Protocol Version

  This implementation targets MCP protocol version "2024-11-05".
  """

  alias LemonMCP.Protocol

  @doc """
  Returns the supported MCP protocol version.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: Protocol.protocol_version()

  @doc """
  Parses a JSON-RPC request from a decoded JSON payload.

  ## Examples

      iex> LemonMCP.parse_request(%{"jsonrpc" => "2.0", "id" => "1", "method" => "initialize"})
      {:ok, %LemonMCP.Protocol.JSONRPCRequest{...}}

  """
  @spec parse_request(map()) :: {:ok, Protocol.JSONRPCRequest.t()} | {:error, term()}
  def parse_request(payload) do
    Protocol.parse_request(payload)
  end

  @doc """
  Creates a JSON-RPC success response.

  ## Examples

      iex> LemonMCP.create_response("1", %{tools: []})
      %LemonMCP.Protocol.JSONRPCResponse{...}

  """
  @spec create_response(Protocol.request_id(), any()) :: Protocol.JSONRPCResponse.t()
  def create_response(id, result) do
    Protocol.create_response(id, result)
  end

  @doc """
  Creates a JSON-RPC error response.

  ## Examples

      iex> LemonMCP.create_error("1", -32600, "Invalid request")
      %LemonMCP.Protocol.JSONRPCResponse{...}

  """
  @spec create_error(Protocol.request_id(), integer(), String.t(), any()) ::
          Protocol.JSONRPCResponse.t()
  def create_error(id, code, message, data \\ nil) do
    Protocol.create_error(id, code, message, data)
  end

  @doc """
  Encodes an MCP message to JSON string.

  ## Examples

      iex> response = LemonMCP.create_response("1", %{tools: []})
      iex> LemonMCP.encode!(response)
      ~s|{"jsonrpc":"2.0","id":"1","result":{"tools":[]}}|

  """
  @spec encode!(struct()) :: String.t()
  def encode!(message) do
    Protocol.encode!(message)
  end
end
