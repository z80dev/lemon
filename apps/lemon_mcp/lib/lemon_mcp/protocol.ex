defmodule LemonMCP.Protocol do
  @moduledoc """
  MCP Protocol message types and JSON-RPC handling.

  This module defines the message structures for the Model Context Protocol
  and provides utilities for encoding/decoding JSON-RPC 2.0 messages.

  ## Message Types

  ### Lifecycle
  - `InitializeRequest` / `InitializeResponse` - Protocol initialization
  - `InitializedNotification` - Client confirms initialization

  ### Tools
  - `ToolListRequest` / `ToolListResponse` - List available tools
  - `ToolCallRequest` / `ToolCallResponse` - Invoke a tool

  ### Errors
  - `JSONRPCError` - JSON-RPC 2.0 error response

  ## Protocol Version

  Target protocol version: "2024-11-05"
  """

  alias __MODULE__

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "JSON-RPC 2.0 request id (string, number, or null)"
  @type request_id :: String.t() | integer() | nil

  @typedoc "MCP protocol version string"
  @type protocol_version :: String.t()

  @doc """
  Returns the supported MCP protocol version.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: "2024-11-05"

  @typedoc "Client or server capabilities map"
  @type capabilities :: map()

  @typedoc "Tool definition"
  @type tool :: %{
          name: String.t(),
          description: String.t(),
          inputSchema: map()
        }

  @typedoc "Tool call result content item"
  @type content_item ::
          %{type: String.t(), text: String.t()}
          | %{type: String.t(), data: String.t(), mimeType: String.t()}
          | %{type: String.t(), resource: map()}

  # ============================================================================
  # Message Structs
  # ============================================================================

  defmodule JSONRPCRequest do
    @moduledoc "Generic JSON-RPC 2.0 request"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            method: String.t(),
            params: map()
          }
    defstruct jsonrpc: "2.0", id: nil, method: "", params: %{}
  end

  defmodule JSONRPCResponse do
    @moduledoc "Generic JSON-RPC 2.0 response"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            result: term(),
            error: Protocol.JSONRPCError.t() | nil
          }
    defstruct jsonrpc: "2.0", id: nil, result: nil, error: nil
  end

  defmodule InitializeRequest do
    @moduledoc "MCP initialize request"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            method: String.t(),
            params: %{
              protocolVersion: Protocol.protocol_version(),
              capabilities: Protocol.capabilities(),
              clientInfo: %{
                name: String.t(),
                version: String.t()
              }
            }
          }
    defstruct jsonrpc: "2.0",
              id: nil,
              method: "initialize",
              params: %{}
  end

  defmodule InitializeResponse do
    @moduledoc "MCP initialize response"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            result: %{
              protocolVersion: Protocol.protocol_version(),
              capabilities: Protocol.capabilities(),
              serverInfo: %{
                name: String.t(),
                version: String.t()
              }
            } | nil,
            error: Protocol.JSONRPCError.t() | nil
          }
    defstruct jsonrpc: "2.0", id: nil, result: nil, error: nil
  end

  defmodule InitializedNotification do
    @moduledoc "MCP initialized notification (sent after successful init)"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            method: String.t(),
            params: map()
          }
    defstruct jsonrpc: "2.0", method: "notifications/initialized", params: %{}
  end

  defmodule ToolListRequest do
    @moduledoc "MCP tools/list request"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            method: String.t(),
            params: map()
          }
    defstruct jsonrpc: "2.0", id: nil, method: "tools/list", params: %{}
  end

  defmodule ToolListResponse do
    @moduledoc "MCP tools/list response"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            result: %{tools: [Protocol.tool()]} | nil,
            error: Protocol.JSONRPCError.t() | nil
          }
    defstruct jsonrpc: "2.0", id: nil, result: nil, error: nil
  end

  defmodule ToolCallRequest do
    @moduledoc "MCP tools/call request"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            method: String.t(),
            params: %{
              name: String.t(),
              arguments: map()
            }
          }
    defstruct jsonrpc: "2.0", id: nil, method: "tools/call", params: %{}
  end

  defmodule ToolCallResponse do
    @moduledoc "MCP tools/call response"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            result: %{
              content: [Protocol.content_item()],
              isError: boolean()
            } | nil,
            error: Protocol.JSONRPCError.t() | nil
          }
    defstruct jsonrpc: "2.0", id: nil, result: nil, error: nil
  end

  defmodule JSONRPCRequest do
    @moduledoc "Generic JSON-RPC 2.0 request for server routing"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            method: String.t(),
            params: map() | nil
          }
    defstruct jsonrpc: "2.0", id: nil, method: "", params: nil
  end

  defmodule JSONRPCResponse do
    @moduledoc "Generic JSON-RPC 2.0 response"
    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: Protocol.request_id(),
            result: any()
          }
    defstruct jsonrpc: "2.0", id: nil, result: nil
  end

  defmodule JSONRPCError do
    @moduledoc "JSON-RPC 2.0 error object"
    @type t :: %__MODULE__{
            code: integer(),
            message: String.t(),
            data: term()
          }
    defstruct code: 0, message: "", data: nil

    # Standard JSON-RPC error codes
    def parse_error, do: -32_700
    def invalid_request, do: -32_600
    def method_not_found, do: -32_601
    def invalid_params, do: -32_602
    def internal_error, do: -32_603
    def server_not_initialized, do: -32_002
    def tool_execution_error, do: -32_600
  end

  defmodule Tool do
    @moduledoc "MCP Tool definition"
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            inputSchema: map()
          }
    defstruct name: "", description: "", inputSchema: %{}
  end

  defmodule ToolCallResult do
    @moduledoc "MCP Tool call result"
    @type t :: %__MODULE__{
            content: [Protocol.content_item()],
            isError: boolean()
          }
    defstruct content: [], isError: false
  end

  # ============================================================================
  # Request Builders
  # ============================================================================

  @doc """
  Creates an initialize request.

  ## Options

  - `:id` - Request ID (auto-generated if not provided)
  - `:protocol_version` - Protocol version (defaults to "2024-11-05")
  - `:client_name` - Client name
  - `:client_version` - Client version
  - `:capabilities` - Client capabilities map
  """
  @spec initialize_request(keyword()) :: InitializeRequest.t()
  def initialize_request(opts \\ []) do
    id = opts[:id] || generate_id()
    protocol_version = opts[:protocol_version] || LemonMCP.protocol_version()
    client_name = opts[:client_name] || "lemon-mcp"
    client_version = opts[:client_version] || "0.1.0"
    capabilities = opts[:capabilities] || %{}

    %InitializeRequest{
      id: id,
      params: %{
        protocolVersion: protocol_version,
        capabilities: capabilities,
        clientInfo: %{
          name: client_name,
          version: client_version
        }
      }
    }
  end

  @doc """
  Creates an initialized notification (sent after successful handshake).
  """
  @spec initialized_notification() :: InitializedNotification.t()
  def initialized_notification do
    %InitializedNotification{}
  end

  @doc """
  Creates a tools/list request.

  ## Options

  - `:id` - Request ID (auto-generated if not provided)
  """
  @spec tool_list_request(keyword()) :: ToolListRequest.t()
  def tool_list_request(opts \\ []) do
    id = opts[:id] || generate_id()
    %ToolListRequest{id: id}
  end

  @doc """
  Creates a tools/call request.

  ## Options

  - `:id` - Request ID (auto-generated if not provided)
  - `:name` - Tool name (required)
  - `:arguments` - Tool arguments map
  """
  @spec tool_call_request(keyword()) :: ToolCallRequest.t()
  def tool_call_request(opts \\ []) do
    id = opts[:id] || generate_id()
    name = opts[:name] || raise ArgumentError, "tool name is required"
    arguments = opts[:arguments] || %{}

    %ToolCallRequest{
      id: id,
      params: %{
        name: name,
        arguments: arguments
      }
    }
  end

  # ============================================================================
  # Encoding / Decoding
  # ============================================================================

  @doc """
  Encodes an MCP message to JSON string.
  """
  @spec encode(struct()) :: {:ok, String.t()} | {:error, term()}
  def encode(message) do
    message
    |> struct_to_map()
    |> Jason.encode()
  end

  @doc """
  Encodes an MCP message to JSON string, raising on error.
  """
  @spec encode!(struct()) :: String.t()
  def encode!(message) do
    message
    |> struct_to_map()
    |> Jason.encode!()
  end

  @doc """
  Decodes a JSON-RPC message into the appropriate MCP struct.
  """
  @spec decode(String.t()) ::
          {:ok, InitializeResponse.t() | ToolListResponse.t() | ToolCallResponse.t() | map()}
          | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_map(data)
      {:error, _} = err -> err
    end
  end

  @doc """
  Decodes a parsed JSON map into the appropriate MCP struct.
  """
  @spec decode_map(map()) ::
          {:ok, InitializeResponse.t() | ToolListResponse.t() | ToolCallResponse.t() | map()}
          | {:error, term()}
  def decode_map(%{"jsonrpc" => "2.0"} = data) do
    cond do
      # Response with result
      Map.has_key?(data, "result") ->
        decode_response(data)

      # Response with error
      Map.has_key?(data, "error") ->
        decode_error_response(data)

      # Request/Notification - return as map for now
      true ->
        {:ok, data}
    end
  end

  def decode_map(_), do: {:error, :invalid_jsonrpc}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_id do
    UUID.uuid4()
  end

  defp struct_to_map(%InitializeRequest{} = req) do
    %{
      "jsonrpc" => req.jsonrpc,
      "id" => req.id,
      "method" => req.method,
      "params" => req.params
    }
  end

  defp struct_to_map(%InitializedNotification{} = req) do
    %{
      "jsonrpc" => req.jsonrpc,
      "method" => req.method,
      "params" => req.params
    }
  end

  defp struct_to_map(%ToolListRequest{} = req) do
    %{
      "jsonrpc" => req.jsonrpc,
      "id" => req.id,
      "method" => req.method,
      "params" => req.params
    }
  end

  defp struct_to_map(%ToolCallRequest{} = req) do
    %{
      "jsonrpc" => req.jsonrpc,
      "id" => req.id,
      "method" => req.method,
      "params" => req.params
    }
  end

  defp decode_response(%{"id" => id, "result" => result} = data) do
    # Try to determine response type based on result structure
    response =
      cond do
        # Initialize response has serverInfo
        Map.has_key?(result, "serverInfo") ->
          server_info = result["serverInfo"]
          %InitializeResponse{
            id: id,
            result: %{
              protocolVersion: result["protocolVersion"],
              capabilities: result["capabilities"] || %{},
              serverInfo: %{
                name: server_info["name"],
                version: server_info["version"]
              }
            }
          }

        # Tool list response has tools array
        Map.has_key?(result, "tools") ->
          %ToolListResponse{
            id: id,
            result: %{tools: result["tools"]}
          }

        # Tool call response has content
        Map.has_key?(result, "content") ->
          %ToolCallResponse{
            id: id,
            result: %{
              content: result["content"],
              isError: result["isError"] || false
            }
          }

        # Unknown response type
        true ->
          data
      end

    {:ok, response}
  end

  defp decode_error_response(%{"id" => id, "error" => error}) do
    err = %JSONRPCError{
      code: error["code"] || 0,
      message: error["message"] || "",
      data: error["data"]
    }

    # Return a response struct with error field
    response = %{
      id: id,
      error: err
    }

    {:ok, response}
  end

  defp decode_error_response(_), do: {:error, :invalid_error_response}

  # ============================================================================
  # Server Helper Functions
  # ============================================================================

  @doc """
  Parses a JSON-RPC request from a decoded JSON payload.
  """
  @spec parse_request(map()) :: {:ok, JSONRPCRequest.t()} | {:error, term()}
  def parse_request(%{"jsonrpc" => "2.0", "method" => method} = payload) do
    request = %JSONRPCRequest{
      jsonrpc: "2.0",
      id: Map.get(payload, "id"),
      method: method,
      params: Map.get(payload, "params")
    }

    {:ok, request}
  end

  def parse_request(%{jsonrpc: "2.0", method: method} = payload) do
    request = %JSONRPCRequest{
      jsonrpc: "2.0",
      id: Map.get(payload, :id),
      method: method,
      params: Map.get(payload, :params)
    }

    {:ok, request}
  end

  def parse_request(_), do: {:error, :invalid_request}

  @doc """
  Creates a JSON-RPC success response.
  """
  @spec create_response(request_id(), any()) :: JSONRPCResponse.t()
  def create_response(id, result) do
    %JSONRPCResponse{
      jsonrpc: "2.0",
      id: id,
      result: result
    }
  end

  @doc """
  Creates a JSON-RPC error response.
  """
  @spec create_error(request_id(), integer(), String.t(), any()) :: JSONRPCResponse.t()
  def create_error(id, code, message, data \\ nil) do
    %JSONRPCResponse{
      jsonrpc: "2.0",
      id: id,
      result: %{
        error: %{
          code: code,
          message: message,
          data: data
        }
      }
    }
  end

  @doc """
  Creates a JSON-RPC error response (legacy format with error at top level).
  """
  @spec create_error_response(request_id(), integer(), String.t(), any()) :: map()
  def create_error_response(id, code, message, data \\ nil) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{
        code: code,
        message: message,
        data: data
      }
    }
  end

  @doc """
  Returns the error code for a given error atom.
  """
  @spec error_code(atom()) :: integer()
  def error_code(:parse_error), do: -32_700
  def error_code(:invalid_request), do: -32_600
  def error_code(:method_not_found), do: -32_601
  def error_code(:invalid_params), do: -32_602
  def error_code(:internal_error), do: -32_603
  def error_code(:server_not_initialized), do: -32_002
  def error_code(:unknown_tool), do: -32_601
  def error_code(:tool_execution_error), do: -32_600
  def error_code(_), do: -32_603

  @doc """
  Converts a Tool struct to a plain map for JSON encoding.
  """
  @spec tool_to_map(Tool.t()) :: map()
  def tool_to_map(%Tool{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema
    }
  end

  @doc """
  Converts a ToolCallResult struct to a plain map for JSON encoding.
  """
  @spec tool_result_to_map(ToolCallResult.t()) :: map()
  def tool_result_to_map(%ToolCallResult{} = result) do
    %{
      content: result.content,
      isError: result.isError
    }
  end

  @doc """
  Builds server capabilities for initialize response.
  """
  @spec server_capabilities(keyword()) :: map()
  def server_capabilities(opts \\ []) do
    caps = %{}
    caps = if Keyword.get(opts, :tools, false), do: Map.put(caps, "tools", %{}), else: caps
    caps = if Keyword.get(opts, :resources, false), do: Map.put(caps, "resources", %{}), else: caps
    caps = if Keyword.get(opts, :prompts, false), do: Map.put(caps, "prompts", %{}), else: caps
    caps = if Keyword.get(opts, :logging, false), do: Map.put(caps, "logging", %{}), else: caps
    caps
  end

  @doc """
  Builds an initialize result for the server.
  """
  @spec initialize_result(String.t(), map(), String.t(), String.t()) :: InitializeResponse.t()
  def initialize_result(protocol_version, capabilities, server_name, server_version) do
    %InitializeResponse{
      id: nil,
      result: %{
        protocolVersion: protocol_version,
        capabilities: capabilities,
        serverInfo: %{
          name: server_name,
          version: server_version
        }
      }
    }
  end
end
