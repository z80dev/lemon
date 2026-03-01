defmodule LemonMCP.Protocol do
  @moduledoc """
  MCP (Model Context Protocol) message types and JSON-RPC handling.

  This module defines the core protocol types and functions for MCP 2024-11-05.
  """

  @protocol_version "2024-11-05"

  @doc """
  Returns the supported MCP protocol version.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  # ============================================================================
  # JSON-RPC Types
  # ============================================================================

  defmodule JSONRPCRequest do
    @moduledoc "JSON-RPC request structure"
    defstruct [:jsonrpc, :id, :method, :params]

    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: String.t() | integer() | nil,
            method: String.t(),
            params: map() | nil
          }
  end

  defmodule JSONRPCResponse do
    @moduledoc "JSON-RPC success response structure"
    defstruct [:jsonrpc, :id, :result]

    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: String.t() | integer() | nil,
            result: any()
          }
  end

  defmodule JSONRPCError do
    @moduledoc "JSON-RPC error structure"
    defstruct [:jsonrpc, :id, :error]

    @type t :: %__MODULE__{
            jsonrpc: String.t(),
            id: String.t() | integer() | nil,
            error: map()
          }

    @type error_detail :: %{
            code: integer(),
            message: String.t(),
            data: any() | nil
          }
  end

  # ============================================================================
  # MCP Types
  # ============================================================================

  defmodule InitializeParams do
    @moduledoc "Parameters for initialize request"
    defstruct [:protocolVersion, :capabilities, :clientInfo]

    @type t :: %__MODULE__{
            protocolVersion: String.t(),
            capabilities: map(),
            clientInfo: %{name: String.t(), version: String.t()}
          }
  end

  defmodule InitializeResult do
    @moduledoc "Result for initialize request"
    defstruct [:protocolVersion, :capabilities, :serverInfo]

    @type t :: %__MODULE__{
            protocolVersion: String.t(),
            capabilities: map(),
            serverInfo: %{name: String.t(), version: String.t()}
          }
  end

  defmodule Tool do
    @moduledoc "MCP Tool definition"
    defstruct [:name, :description, :inputSchema]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            inputSchema: map()
          }
  end

  defmodule ToolCallParams do
    @moduledoc "Parameters for tools/call request"
    defstruct [:name, :arguments, :meta]

    @type t :: %__MODULE__{
            name: String.t(),
            arguments: map(),
            meta: map() | nil
          }
  end

  defmodule ToolCallResult do
    @moduledoc "Result content for tools/call response"
    defstruct [:content, :isError]

    @type content_item :: %{
            type: String.t(),
            text: String.t() | nil,
            data: any() | nil
          }

    @type t :: %__MODULE__{
            content: [content_item()],
            isError: boolean()
          }
  end

  defmodule ServerCapabilities do
    @moduledoc "Server capability declaration"
    defstruct [:tools, :resources, :prompts, :logging]

    @type t :: %__MODULE__{
            tools: map() | nil,
            resources: map() | nil,
            prompts: map() | nil,
            logging: map() | nil
          }
  end

  # ============================================================================
  # JSON-RPC Functions
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
  @spec create_response(String.t() | integer() | nil, any()) :: JSONRPCResponse.t()
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
  @spec create_error(String.t() | integer() | nil, integer(), String.t(), any()) ::
          JSONRPCError.t()
  def create_error(id, code, message, data \\ nil) do
    %JSONRPCError{
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
  Standard JSON-RPC error codes.
  """
  def error_code(:parse_error), do: -32_700
  def error_code(:invalid_request), do: -32_600
  def error_code(:method_not_found), do: -32_601
  def error_code(:invalid_params), do: -32_602
  def error_code(:internal_error), do: -32_603
  def error_code(:server_not_initialized), do: -32_002
  def error_code(:unknown_tool), do: -32_601
  def error_code(:tool_execution_error), do: -32_600

  @doc """
  Encodes a JSON-RPC message to JSON string.
  """
  @spec encode!(JSONRPCRequest.t() | JSONRPCResponse.t() | JSONRPCError.t()) :: String.t()
  def encode!(message) do
    message
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Jason.encode!()
  end

  @doc """
  Builds server capabilities for initialize response.
  """
  @spec server_capabilities(keyword()) :: ServerCapabilities.t()
  def server_capabilities(opts \\ []) do
    %ServerCapabilities{
      tools: if(Keyword.get(opts, :tools, false), do: %{}, else: nil),
      resources: if(Keyword.get(opts, :resources, false), do: %{}, else: nil),
      prompts: if(Keyword.get(opts, :prompts, false), do: %{}, else: nil),
      logging: if(Keyword.get(opts, :logging, false), do: %{}, else: nil)
    }
  end

  @doc """
  Converts a ServerCapabilities struct to a plain map for JSON encoding.
  """
  @spec capabilities_to_map(ServerCapabilities.t()) :: map()
  def capabilities_to_map(%ServerCapabilities{} = caps) do
    caps
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

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
  Builds an initialize result for the server.
  """
  @spec initialize_result(String.t(), map(), String.t(), String.t()) :: InitializeResult.t()
  def initialize_result(protocol_version, capabilities, server_name, server_version) do
    %InitializeResult{
      protocolVersion: protocol_version,
      capabilities: capabilities,
      serverInfo: %{
        name: server_name,
        version: server_version
      }
    }
  end
end
