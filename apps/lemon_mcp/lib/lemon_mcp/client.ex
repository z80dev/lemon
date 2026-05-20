defmodule LemonMCP.Client do
  @moduledoc """
  MCP Client GenServer for managing connections to MCP servers.

  This module provides a high-level client interface for interacting with
  MCP servers over stdio transport. It handles:

  - Connection lifecycle (spawn, initialize handshake, close)
  - Request/response correlation
  - Tool listing and invocation
  - Resource listing/reading and prompt listing/getting
  - Optional server-to-client sampling callbacks
  - Async message handling

  ## Usage

  Start a client:

      {:ok, client} = LemonMCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
      )

  List tools:

      {:ok, tools} = LemonMCP.Client.list_tools(client)

  Call a tool:

      {:ok, result} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/tmp/test.txt"})

  ## State Machine

  The client progresses through these states:
  - `:disconnected` - Initial state, no server connection
  - `:initializing` - Connection established, handshake in progress
  - `:ready` - Handshake complete, ready for tool operations

  """

  use GenServer

  require Logger

  alias LemonMCP.Protocol

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "Client state"
  @type client_state :: :disconnected | :initializing | :ready

  @typedoc "Client configuration"
  @type config :: %{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          client_name: String.t(),
          client_version: String.t(),
          capabilities: map(),
          sampling_handler: (map() -> {:ok, map()} | {:error, term()}) | nil,
          timeout_ms: non_neg_integer()
        }

  @typedoc "Pending request"
  @type pending_request :: %{
          id: String.t(),
          from: GenServer.from(),
          timer: reference()
        }

  @typedoc "Server state struct"
  @type t :: %{
          state: client_state(),
          transport: pid() | nil,
          config: config(),
          server_info: map() | nil,
          server_capabilities: map() | nil,
          pending_requests: %{String.t() => pending_request()},
          message_buffer: [String.t()]
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts an MCP client connection.

  ## Options

  - `:command` - (required) Command to spawn the MCP server
  - `:args` - Arguments to pass to the command (default: [])
  - `:env` - Environment variables as keyword list or map (default: [])
  - `:client_name` - Client name for handshake (default: "lemon-mcp")
  - `:client_version` - Client version for handshake (default: "0.1.0")
  - `:capabilities` - Client capabilities map (default: %{})
  - `:sampling_handler` - Optional callback for `sampling/createMessage` server requests
  - `:sampling_policy` - Optional `LemonMCP.Sampling` policy opts used when no
    raw `:sampling_handler` is provided
  - `:timeout_ms` - Request timeout in milliseconds (default: 30000)
  - `:name` - GenServer name registration

  ## Examples

      {:ok, client} = LemonMCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the current client state.
  """
  @spec state(GenServer.server()) :: client_state()
  def state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Lists available tools from the MCP server.

  Returns `{:ok, [tool()])}` on success or `{:error, reason}` on failure.
  """
  @spec list_tools(GenServer.server(), timeout()) ::
          {:ok, [Protocol.tool()]} | {:error, term()}
  def list_tools(server, timeout \\ 30_000) do
    GenServer.call(server, :list_tools, timeout)
  end

  @doc """
  Calls a tool on the MCP server.

  ## Parameters

  - `server` - Client GenServer reference
  - `tool_name` - Name of the tool to call
  - `arguments` - Tool arguments as a map
  - `timeout` - Timeout in milliseconds

  ## Returns

  - `{:ok, result}` - Tool call succeeded with result content
  - `{:error, reason}` - Tool call failed

  ## Examples

      {:ok, result} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/tmp/test.txt"})
  """
  @spec call_tool(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, [Protocol.content_item()]} | {:error, term()}
  def call_tool(server, tool_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(server, {:call_tool, tool_name, arguments}, timeout)
  end

  @doc """
  Lists resources exposed by the MCP server.
  """
  @spec list_resources(GenServer.server(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def list_resources(server, timeout \\ 30_000) do
    GenServer.call(server, :list_resources, timeout)
  end

  @doc """
  Reads a resource by URI from the MCP server.
  """
  @spec read_resource(GenServer.server(), String.t(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def read_resource(server, uri, timeout \\ 30_000) do
    GenServer.call(server, {:read_resource, uri}, timeout)
  end

  @doc """
  Lists prompt templates exposed by the MCP server.
  """
  @spec list_prompts(GenServer.server(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def list_prompts(server, timeout \\ 30_000) do
    GenServer.call(server, :list_prompts, timeout)
  end

  @doc """
  Gets a prompt template rendering from the MCP server.
  """
  @spec get_prompt(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(server, prompt_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(server, {:get_prompt, prompt_name, arguments}, timeout)
  end

  @doc """
  Closes the client connection.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.call(server, :close)
  end

  @doc """
  Returns information about the connected MCP server.
  """
  @spec server_info(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_info(server) do
    GenServer.call(server, :server_info)
  end

  @doc """
  Returns capabilities advertised by the connected MCP server.
  """
  @spec server_capabilities(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_capabilities(server) do
    GenServer.call(server, :server_capabilities)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config = %{
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, []),
      client_name: Keyword.get(opts, :client_name, "lemon-mcp"),
      client_version: Keyword.get(opts, :client_version, "0.1.0"),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      sampling_handler: sampling_handler(opts),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }

    state = %{
      state: :disconnected,
      transport: nil,
      config: config,
      server_info: nil,
      server_capabilities: nil,
      pending_requests: %{},
      message_buffer: []
    }

    # Start the transport
    case start_transport(state) do
      {:ok, transport_pid, new_state} ->
        new_state = %{new_state | transport: transport_pid, state: :initializing}
        # Send initialize request
        send_initialize(new_state)
        {:ok, new_state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call(:list_tools, from, %{state: :ready} = state) do
    request = Protocol.tool_list_request()
    send_request(request, from, state)
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, %{state: :ready} = state) do
    request = Protocol.tool_call_request(name: tool_name, arguments: arguments)
    send_request(request, from, state)
  end

  @impl true
  def handle_call({:call_tool, _, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:list_resources, from, %{state: :ready} = state) do
    request = Protocol.resource_list_request()
    send_request(request, from, state)
  end

  @impl true
  def handle_call(:list_resources, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:read_resource, uri}, from, %{state: :ready} = state) do
    request = Protocol.resource_read_request(uri: uri)
    send_request(request, from, state)
  end

  @impl true
  def handle_call({:read_resource, _uri}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:list_prompts, from, %{state: :ready} = state) do
    request = Protocol.prompt_list_request()
    send_request(request, from, state)
  end

  @impl true
  def handle_call(:list_prompts, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:get_prompt, prompt_name, arguments}, from, %{state: :ready} = state) do
    request = Protocol.prompt_get_request(name: prompt_name, arguments: arguments)
    send_request(request, from, state)
  end

  @impl true
  def handle_call({:get_prompt, _, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    new_state = do_close(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:server_info, _from, %{state: :ready, server_info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call(:server_info, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call(
        :server_capabilities,
        _from,
        %{state: :ready, server_capabilities: caps} = state
      ) do
    {:reply, {:ok, caps || %{}}, state}
  end

  @impl true
  def handle_call(:server_capabilities, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{transport: pid} = state) do
    Logger.warning("MCP transport process died: #{inspect(reason)}")
    {:stop, {:transport_died, reason}, %{state | transport: nil, state: :disconnected}}
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case pop_in(state.pending_requests[request_id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:mcp_message, raw_message}, state) do
    handle_mcp_message(raw_message, state)
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_close(state)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_transport(state) do
    client = self()
    handler = fn msg -> send(client, {:mcp_message, msg}) end

    transport_opts = [
      command: state.config.command,
      args: state.config.args,
      env: state.config.env,
      message_handler: handler
    ]

    case LemonMCP.Transport.Stdio.start_link(transport_opts) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid, state}

      error ->
        error
    end
  end

  defp send_initialize(state) do
    request =
      Protocol.initialize_request(
        client_name: state.config.client_name,
        client_version: state.config.client_version,
        capabilities: client_capabilities(state.config)
      )

    case Protocol.encode(request) do
      {:ok, json} ->
        :ok = LemonMCP.Transport.Stdio.send_message(state.transport, json)

      {:error, reason} ->
        Logger.error("Failed to encode initialize request: #{inspect(reason)}")
    end
  end

  defp send_initialized_notification(state) do
    notification = Protocol.initialized_notification()

    case Protocol.encode(notification) do
      {:ok, json} ->
        :ok = LemonMCP.Transport.Stdio.send_message(state.transport, json)

      {:error, reason} ->
        Logger.error("Failed to encode initialized notification: #{inspect(reason)}")
    end
  end

  defp send_request(request, from, state) do
    id = request.id

    case Protocol.encode(request) do
      {:ok, json} ->
        timer = Process.send_after(self(), {:timeout, id}, state.config.timeout_ms)
        pending = %{id: id, from: from, timer: timer}
        new_pending = Map.put(state.pending_requests, id, pending)

        case LemonMCP.Transport.Stdio.send_message(state.transport, json) do
          :ok ->
            {:noreply, %{state | pending_requests: new_pending}}

          {:error, reason} ->
            Process.cancel_timer(timer)
            {:reply, {:error, {:send_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:encode_failed, reason}}, state}
    end
  end

  defp handle_mcp_message(raw_message, state) do
    case Protocol.decode(raw_message) do
      {:ok, message} ->
        process_message(message, state)

      {:error, reason} ->
        Logger.warning("Failed to decode MCP message: #{inspect(reason)} - #{raw_message}")
        {:noreply, state}
    end
  end

  defp process_message(%Protocol.InitializeResponse{} = response, %{state: :initializing} = state) do
    if response.error do
      Logger.error("Initialize failed: #{response.error.message}")
      {:stop, {:init_failed, response.error}, state}
    else
      # Send initialized notification
      send_initialized_notification(state)

      # Extract server info
      result = response.result

      new_state = %{
        state
        | state: :ready,
          server_info: result.serverInfo,
          server_capabilities: result.capabilities
      }

      {:noreply, new_state}
    end
  end

  defp process_message(%Protocol.InitializeResponse{}, state) do
    # Unexpected initialize response in non-initializing state
    Logger.warning("Received unexpected initialize response")
    {:noreply, state}
  end

  defp process_message(%Protocol.ToolListResponse{id: id, result: result, error: nil}, state) do
    case pop_in(state.pending_requests[id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:ok, result.tools})
        {:noreply, new_state}
    end
  end

  defp process_message(%Protocol.ToolListResponse{id: id, error: error}, state)
       when error != nil do
    case pop_in(state.pending_requests[id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:error, {:rpc_error, error}})
        {:noreply, new_state}
    end
  end

  defp process_message(%Protocol.ToolCallResponse{id: id, result: result, error: nil}, state) do
    case pop_in(state.pending_requests[id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        Process.cancel_timer(pending.timer)

        response =
          if result.isError do
            {:error, {:tool_error, result.content}}
          else
            {:ok, result.content}
          end

        GenServer.reply(pending.from, response)
        {:noreply, new_state}
    end
  end

  defp process_message(%Protocol.ToolCallResponse{id: id, error: error}, state)
       when error != nil do
    case pop_in(state.pending_requests[id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:error, {:rpc_error, error}})
        {:noreply, new_state}
    end
  end

  defp process_message(%Protocol.ResourceListResponse{id: id, result: result, error: nil}, state) do
    reply_pending(id, {:ok, result.resources}, state)
  end

  defp process_message(%Protocol.ResourceListResponse{id: id, error: error}, state)
       when error != nil do
    reply_pending(id, {:error, {:rpc_error, error}}, state)
  end

  defp process_message(%Protocol.ResourceReadResponse{id: id, result: result, error: nil}, state) do
    reply_pending(id, {:ok, result.contents}, state)
  end

  defp process_message(%Protocol.ResourceReadResponse{id: id, error: error}, state)
       when error != nil do
    reply_pending(id, {:error, {:rpc_error, error}}, state)
  end

  defp process_message(%Protocol.PromptListResponse{id: id, result: result, error: nil}, state) do
    reply_pending(id, {:ok, result.prompts}, state)
  end

  defp process_message(%Protocol.PromptListResponse{id: id, error: error}, state)
       when error != nil do
    reply_pending(id, {:error, {:rpc_error, error}}, state)
  end

  defp process_message(%Protocol.PromptGetResponse{id: id, result: result, error: nil}, state) do
    reply_pending(id, {:ok, result}, state)
  end

  defp process_message(%Protocol.PromptGetResponse{id: id, error: error}, state)
       when error != nil do
    reply_pending(id, {:error, {:rpc_error, error}}, state)
  end

  defp process_message(
         %{"id" => id, "method" => "sampling/createMessage", "params" => params},
         state
       ) do
    handle_sampling_request(id, params || %{}, state)
    {:noreply, state}
  end

  defp process_message(%{id: id, error: error}, state) when error != nil do
    # Generic error response for unknown request types
    case pop_in(state.pending_requests[id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:error, {:rpc_error, error}})
        {:noreply, new_state}
    end
  end

  defp process_message(message, state) do
    Logger.debug("Unhandled MCP message: #{inspect(message)}")
    {:noreply, state}
  end

  defp handle_sampling_request(id, params, state) do
    response =
      case state.config.sampling_handler do
        handler when is_function(handler, 1) ->
          case handler.(params) do
            {:ok, result} when is_map(result) ->
              Protocol.create_response(id, result)

            {:error, reason} ->
              Protocol.create_error_response(
                id,
                -1,
                "Sampling request rejected",
                inspect(reason)
              )

            other ->
              Protocol.create_error_response(
                id,
                Protocol.error_code(:internal_error),
                "Invalid sampling handler response",
                inspect(other)
              )
          end

        _ ->
          Protocol.create_error_response(id, -1, "Sampling is not enabled")
      end

    send_response(response, state)
  end

  defp send_response(response, state) do
    encoded =
      cond do
        is_struct(response) -> Protocol.encode(response)
        is_map(response) -> Jason.encode(response)
        true -> {:error, {:unsupported_response, response}}
      end

    case encoded do
      {:ok, json} ->
        case LemonMCP.Transport.Stdio.send_message(state.transport, json) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to send MCP response: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to encode MCP response: #{inspect(reason)}")
    end
  end

  defp client_capabilities(config) do
    if is_function(config.sampling_handler, 1) do
      Map.put(config.capabilities, "sampling", %{})
    else
      config.capabilities
    end
  end

  defp sampling_handler(opts) do
    case Keyword.fetch(opts, :sampling_handler) do
      {:ok, handler} ->
        handler

      :error ->
        case Keyword.fetch(opts, :sampling_policy) do
          {:ok, policy} -> LemonMCP.Sampling.handler(policy)
          :error -> nil
        end
    end
  end

  defp reply_pending(id, response, state) do
    case pop_in(state.pending_requests[id]) do
      {nil, state} ->
        {:noreply, state}

      {pending, new_state} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, response)
        {:noreply, new_state}
    end
  end

  defp do_close(state) do
    if state.transport do
      LemonMCP.Transport.Stdio.close(state.transport)
    end

    # Cancel all pending requests
    Enum.each(state.pending_requests, fn {_id, pending} ->
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, :connection_closed})
    end)

    %{state | transport: nil, state: :disconnected, pending_requests: %{}}
  end
end
