defmodule LemonMCP.Server.Handler do
  @moduledoc """
  Request handler for MCP server protocol messages.

  Handles JSON-RPC requests according to the MCP specification:
  - `initialize` - Client/server handshake
  - `initialized` - Client notification of initialization complete
  - `tools/list` - List available tools
  - `tools/call` - Invoke a tool

  ## Usage

      request = %LemonMCP.Protocol.JSONRPCRequest{
        id: "1",
        method: "initialize",
        params: %{"protocolVersion" => "2024-11-05", ...}
      }

      response = LemonMCP.Server.Handler.handle_request(request, server_pid)

  """

  require Logger

  alias LemonMCP.Protocol
  alias LemonMCP.Server

  @doc """
  Handles an MCP JSON-RPC request and returns a response.

  The request is routed to the appropriate handler based on the method.
  """
  @spec handle_request(Protocol.JSONRPCRequest.t(), GenServer.server()) ::
          Protocol.JSONRPCResponse.t()
  def handle_request(%Protocol.JSONRPCRequest{} = request, server) do
    case request.method do
      "initialize" ->
        handle_initialize(request, server)

      "initialized" ->
        handle_initialized(request, server)

      "tools/list" ->
        handle_tools_list(request, server)

      "tools/call" ->
        handle_tools_call(request, server)

      _ ->
        Protocol.create_error_response(
          request.id,
          Protocol.error_code(:method_not_found),
          "Method not found: #{request.method}"
        )
    end
  end

  @doc """
  Handles the initialize request (MCP handshake).

  Validates the protocol version and returns server capabilities.
  """
  @spec handle_initialize(Protocol.JSONRPCRequest.t(), GenServer.server()) ::
          Protocol.JSONRPCResponse.t()
  def handle_initialize(%Protocol.JSONRPCRequest{id: id, params: params}, server) do
    client_version = get_in(params, ["protocolVersion"]) || get_in(params, [:protocolVersion])

    # Check protocol version compatibility
    if compatible_version?(client_version) do
      result = Server.get_initialize_result(server)

      response_data = %{
        protocolVersion: result.result.protocolVersion,
        capabilities: result.result.capabilities,
        serverInfo: result.result.serverInfo
      }

      Protocol.create_response(id, response_data)
    else
      Protocol.create_error_response(
        id,
        Protocol.error_code(:invalid_request),
        "Unsupported protocol version: #{client_version}"
      )
    end
  end

  @doc """
  Handles the initialized notification.

  Marks the server as ready for normal operations.
  """
  @spec handle_initialized(Protocol.JSONRPCRequest.t(), GenServer.server()) ::
          Protocol.JSONRPCResponse.t()
  def handle_initialized(%Protocol.JSONRPCRequest{id: id}, server) do
    :ok = Server.mark_initialized(server)

    # Return null result for notifications (id may be nil)
    Protocol.create_response(id, nil)
  end

  @doc """
  Handles the tools/list request.

  Returns the list of available tools from the server.
  Requires the server to be initialized first.
 """
  @spec handle_tools_list(Protocol.JSONRPCRequest.t(), GenServer.server()) ::
          Protocol.JSONRPCResponse.t()
  def handle_tools_list(%Protocol.JSONRPCRequest{id: id} = _request, server) do
    if Server.initialized?(server) do
      tools = Server.list_tools(server)
      tool_maps = Enum.map(tools, &Protocol.tool_to_map/1)

      Protocol.create_response(id, %{tools: tool_maps})
    else
      Protocol.create_error_response(
        id,
        Protocol.error_code(:server_not_initialized),
        "Server not initialized"
      )
    end
  end

  @doc """
  Handles the tools/call request.

  Invokes the specified tool with the provided arguments.
  Requires the server to be initialized first.
  """
  @spec handle_tools_call(Protocol.JSONRPCRequest.t(), GenServer.server()) ::
          Protocol.JSONRPCResponse.t()
  def handle_tools_call(%Protocol.JSONRPCRequest{id: id, params: params}, server) do
    if Server.initialized?(server) do
      tool_name = get_in(params, ["name"]) || get_in(params, [:name])
      arguments = get_in(params, ["arguments"]) || get_in(params, [:arguments]) || %{}

      if is_binary(tool_name) do
        case Server.call_tool(server, tool_name, arguments) do
          {:ok, %Protocol.ToolCallResult{} = result} ->
            Protocol.create_response(id, Protocol.tool_result_to_map(result))

          {:ok, result} when is_map(result) ->
            Protocol.create_response(id, result)

          {:error, reason} ->
            error_message =
              if is_binary(reason) do
                reason
              else
                "Tool execution failed: #{inspect(reason)}"
              end

            Protocol.create_error_response(
              id,
              Protocol.error_code(:tool_execution_error),
              error_message
            )
        end
      else
        Protocol.create_error_response(
          id,
          Protocol.error_code(:invalid_params),
          "Missing or invalid 'name' parameter"
        )
      end
    else
      Protocol.create_error_response(
        id,
        Protocol.error_code(:server_not_initialized),
        "Server not initialized"
      )
    end
  end

  @doc """
  Handles a raw JSON-RPC request (decoded JSON map).

  This is a convenience function for the HTTP transport layer.
  """
  @spec handle_json_request(map(), GenServer.server()) ::
          {:ok, Protocol.JSONRPCResponse.t()} | {:error, term()}
  def handle_json_request(json_payload, server) do
    case Protocol.parse_request(json_payload) do
      {:ok, request} ->
        {:ok, handle_request(request, server)}

      {:error, reason} ->
        error =
          Protocol.create_error_response(
            nil,
            Protocol.error_code(:parse_error),
            "Failed to parse request: #{inspect(reason)}"
          )

        {:ok, error}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp compatible_version?(client_version) when is_binary(client_version) do
    # For now, we accept exact match or known compatible versions
    # In production, this could use semantic versioning
    client_version == LemonMCP.protocol_version() or
      client_version in supported_versions()
  end

  defp compatible_version?(_), do: false

  defp supported_versions do
    [
      "2024-11-05"
    ]
  end
end
