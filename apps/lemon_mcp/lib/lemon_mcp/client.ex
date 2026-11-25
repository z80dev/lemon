defmodule LemonMCP.Client do
  @moduledoc """
  MCP Client GenServer for managing connections to MCP servers.

  This module provides a high-level client interface for interacting with
  MCP servers over stdio transport. It handles:

  - Connection lifecycle (spawn, initialize handshake, close)
  - Request/response correlation and deadlines through `LemonCore.Rpc.Client`
  - Tool listing and invocation
  - Resource listing/reading and prompt listing/getting
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

  alias LemonCore.Rpc.Client, as: RpcClient
  alias LemonMCP.Client.StdioHandler
  alias LemonMCP.Framing.Stdio, as: StdioFraming
  alias LemonMCP.Protocol
  alias LemonMCP.Transport.Stdio

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
          port_open: (term(), list() -> port()),
          client_name: String.t(),
          client_version: String.t(),
          capabilities: map(),
          timeout_ms: timeout()
        }

  @typedoc "Server state struct"
  @type t :: %{
          state: client_state(),
          transport: pid() | nil,
          config: config(),
          server_info: map() | nil,
          server_capabilities: map() | nil,
          rpc: pid() | nil,
          task_supervisor: pid() | nil,
          initialize_id: String.t() | nil
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
  - `:port_open` - Host stdio opener `(spec, options -> port)`, defaulting to
    `&Port.open/2`. Invalid callbacks and host refusals fail startup without fallback.
  - `:client_name` - Client name for handshake (default: "lemon-mcp")
  - `:client_version` - Client version for handshake (default: "0.1.0")
  - `:capabilities` - Client capabilities map (default: %{}). Lemon answers no
    server-to-client requests, so a `sampling` entry is never advertised.
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
    request(server, Protocol.tool_list_request(), timeout)
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
    request(server, Protocol.tool_call_request(name: tool_name, arguments: arguments), timeout)
  end

  @doc """
  Lists resources exposed by the MCP server.
  """
  @spec list_resources(GenServer.server(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def list_resources(server, timeout \\ 30_000) do
    request(server, Protocol.resource_list_request(), timeout)
  end

  @doc """
  Reads a resource by URI from the MCP server.
  """
  @spec read_resource(GenServer.server(), String.t(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def read_resource(server, uri, timeout \\ 30_000) do
    request(server, Protocol.resource_read_request(uri: uri), timeout)
  end

  @doc """
  Lists prompt templates exposed by the MCP server.
  """
  @spec list_prompts(GenServer.server(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def list_prompts(server, timeout \\ 30_000) do
    request(server, Protocol.prompt_list_request(), timeout)
  end

  @doc """
  Gets a prompt template rendering from the MCP server.
  """
  @spec get_prompt(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(server, prompt_name, arguments \\ %{}, timeout \\ 30_000) do
    request(server, Protocol.prompt_get_request(name: prompt_name, arguments: arguments), timeout)
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

  defp request(server, request, timeout) do
    GenServer.call(server, {:request, request, timeout}, :infinity)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config = %{
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      cwd: Keyword.get(opts, :cwd),
      env: Keyword.get(opts, :env, []),
      port_open: Keyword.get(opts, :port_open, &Port.open/2),
      client_name: Keyword.get(opts, :client_name, "lemon-mcp"),
      client_version: Keyword.get(opts, :client_version, "0.1.0"),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      notification_handler: Protocol.notification_handler(opts),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }

    state = %{
      state: :disconnected,
      transport: nil,
      config: config,
      server_info: nil,
      server_capabilities: nil,
      rpc: nil,
      task_supervisor: nil,
      initialize_id: nil
    }

    Process.flag(:trap_exit, true)

    case start_transport(state) do
      {:ok, transport} ->
        {:ok, task_supervisor} = Task.Supervisor.start_link()
        owner = self()
        handlers = Map.take(config, [:notification_handler])

        {:ok, rpc} =
          RpcClient.start_link(
            owner: owner,
            framing: StdioFraming,
            transport: Stdio,
            transport_state: transport,
            ready: false,
            connect_timeout: config.timeout_ms,
            task_supervisor: task_supervisor,
            handler: &StdioHandler.handle(&1, &2, owner, handlers)
          )

        Process.monitor(rpc)

        state = %{
          state
          | transport: transport,
            rpc: rpc,
            task_supervisor: task_supervisor,
            state: :initializing
        }

        case send_initialize(state) do
          {:ok, state} ->
            {:ok, state}

          {:error, reason} ->
            _ = do_close(state)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call({:request, request, timeout}, from, %{state: :ready} = state) do
    timeout = min(timeout, state.config.timeout_ms)

    case RpcClient.dispatch(state.rpc, request.id, request, from, timeout) do
      :ok ->
        {:noreply, state}

      {:error, {:encode_failed, _reason}} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:reply, {:error, {:send_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call({:request, _request, _timeout}, _from, state) do
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
    {:stop, {:transport_died, reason}, %{state | transport: nil, state: :disconnected}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{rpc: pid} = state) do
    {:stop, {:rpc_died, reason}, %{state | rpc: nil, state: :disconnected}}
  end

  def handle_info({:EXIT, pid, reason}, %{transport: pid} = state) when reason != :normal do
    {:stop, {:transport_died, reason}, %{state | transport: nil, state: :disconnected}}
  end

  def handle_info({:EXIT, pid, reason}, %{task_supervisor: pid} = state) do
    {:stop, {:handler_supervisor_died, reason}, %{state | task_supervisor: nil}}
  end

  def handle_info({:mcp_data, bytes}, %{rpc: rpc} = state) when is_pid(rpc) do
    RpcClient.feed(rpc, bytes)
    {:noreply, state}
  end

  def handle_info({:rpc_message, message}, %{rpc: rpc} = state) when is_pid(rpc) do
    handle_mcp_message(message, state)
  end

  def handle_info({:rpc_finished, _id, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = do_close(state)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_transport(state) do
    client = self()
    handler = fn bytes -> send(client, {:mcp_data, bytes}) end

    transport_opts = [
      command: state.config.command,
      args: state.config.args,
      cwd: state.config.cwd,
      env: state.config.env,
      port_open: state.config.port_open,
      message_handler: handler
    ]

    case Stdio.start_link(transport_opts) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp send_initialize(state) do
    request =
      Protocol.initialize_request(
        client_name: state.config.client_name,
        client_version: state.config.client_version,
        capabilities: Protocol.client_capabilities(state.config.capabilities)
      )

    case RpcClient.send_message(state.rpc, request) do
      :ok -> {:ok, %{state | initialize_id: request.id}}
      {:error, reason} -> {:error, {:init_failed, reason}}
    end
  end

  defp send_initialized_notification(state) do
    RpcClient.send_message(state.rpc, Protocol.initialized_notification())
  end

  defp handle_mcp_message(message, state) do
    case Protocol.decode_map(message) do
      {:ok, message} ->
        process_message(message, state)

      {:error, _reason} ->
        Logger.warning("Ignoring invalid MCP protocol message")
        {:noreply, state}
    end
  end

  defp process_message(
         %Protocol.InitializeResponse{id: id, result: result},
         %{state: :initializing, initialize_id: id} = state
       ) do
    with :ok <- send_initialized_notification(state),
         :ok <- RpcClient.ready(state.rpc) do
      {:noreply,
       %{
         state
         | state: :ready,
           initialize_id: nil,
           server_info: result.serverInfo,
           server_capabilities: result.capabilities
       }}
    else
      {:error, reason} -> {:stop, {:init_failed, reason}, state}
    end
  end

  defp process_message(
         %{id: id, error: error},
         %{state: :initializing, initialize_id: id} = state
       )
       when error != nil do
    {:stop, {:init_failed, error}, state}
  end

  defp process_message(%Protocol.InitializeResponse{}, state) do
    # Unexpected initialize response in non-initializing state
    Logger.warning("Received unexpected initialize response")
    {:noreply, state}
  end

  defp process_message(%Protocol.ToolListResponse{id: id, result: result, error: nil}, state) do
    reply_pending(id, {:ok, result.tools}, state)
  end

  defp process_message(%Protocol.ToolCallResponse{id: id, result: result, error: nil}, state) do
    response =
      if result.isError do
        {:error, {:tool_error, result.content}}
      else
        {:ok, result.content}
      end

    reply_pending(id, response, state)
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

  defp process_message(%{id: id, error: error}, state) when error != nil do
    reply_pending(id, {:error, {:rpc_error, error}}, state)
  end

  defp process_message(_message, state), do: {:noreply, state}

  defp reply_pending(id, response, state) do
    RpcClient.complete(state.rpc, id, response)
    {:noreply, state}
  end

  defp do_close(state) do
    if state.rpc && Process.alive?(state.rpc) do
      try do
        RpcClient.fail_all(state.rpc, {:error, :connection_closed})
      catch
        :exit, _ -> :ok
      end
    end

    if state.rpc && Process.alive?(state.rpc) do
      try do
        :gen_statem.stop(state.rpc)
      catch
        :exit, _ -> :ok
      end
    end

    stop_process(state.task_supervisor)

    stop_process(state.transport)

    %{
      state
      | transport: nil,
        rpc: nil,
        task_supervisor: nil,
        initialize_id: nil,
        state: :disconnected
    }
  end

  defp stop_process(nil), do: :ok

  defp stop_process(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
