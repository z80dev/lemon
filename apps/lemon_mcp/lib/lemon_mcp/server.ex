defmodule LemonMCP.Server do
  @moduledoc """
  MCP Server GenServer that manages tool registration and handles MCP requests.

  ## Usage

      # Start a server with a custom tool provider
      {:ok, pid} = LemonMCP.Server.start_link(
        name: :my_mcp_server,
        server_name: "My Server",
        server_version: "1.0.0",
        tool_provider: MyToolProvider
      )

      # Or with explicit tool list
      {:ok, pid} = LemonMCP.Server.start_link(
        tools: [
          %LemonMCP.Protocol.Tool{
            name: "echo",
            description: "Echoes the input",
            inputSchema: %{"type" => "object", "properties" => %{}}
          }
        ],
        tool_handler: &MyModule.handle_tool_call/2
      )

  ## Tool Provider Behaviour

  Modules implementing the tool provider behaviour must define:

  - `list_tools/0` - Returns a list of `%LemonMCP.Protocol.Tool{}` structs
  - `call_tool/2` - Handles tool calls with `name` and `arguments`, returns `{:ok, result}` or `{:error, reason}`

  """

  use GenServer

  require Logger

  alias LemonMCP.Protocol

  @default_server_name "Lemon MCP Server"
  @default_server_version "0.1.0"

  # ============================================================================
  # Tool Provider Behaviour
  # ============================================================================

  @doc """
  Callback to list available tools.
  """
  @callback list_tools() :: [Protocol.Tool.t()]

  @doc """
  Callback to invoke a tool.
  """
  @callback call_tool(name :: String.t(), arguments :: map()) ::
              {:ok, Protocol.ToolCallResult.t()} | {:error, term()}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the MCP server.

  ## Options

    * `:name` - Optional process name for registration
    * `:server_name` - Server name for initialize response (default: "Lemon MCP Server")
    * `:server_version` - Server version for initialize response (default: "0.1.0")
    * `:tool_provider` - Module implementing the `LemonMCP.Server` behaviour
    * `:tools` - List of tools (used if `:tool_provider` not specified)
    * `:tool_handler` - Function to handle tool calls (used if `:tool_provider` not specified)
    * `:capabilities` - Additional server capabilities beyond tools

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    server_opts = build_server_opts(opts)

    if name do
      GenServer.start_link(__MODULE__, server_opts, name: name)
    else
      GenServer.start_link(__MODULE__, server_opts)
    end
  end

  @doc """
  Returns the server's initialize result.
  """
  @spec get_initialize_result(GenServer.server()) :: Protocol.InitializeResponse.t()
  def get_initialize_result(server) do
    GenServer.call(server, :get_initialize_result)
  end

  @doc """
  Lists available tools from the server.
  """
  @spec list_tools(GenServer.server()) :: [Protocol.Tool.t()]
  def list_tools(server) do
    GenServer.call(server, :list_tools)
  end

  @doc """
  Calls a tool on the server.
  """
  @spec call_tool(GenServer.server(), String.t(), map()) ::
          {:ok, Protocol.ToolCallResult.t()} | {:error, term()}
  def call_tool(server, name, arguments \\ %{}) do
    GenServer.call(server, {:call_tool, name, arguments})
  end

  @doc """
  Returns true if the server has been initialized.
  """
  @spec initialized?(GenServer.server()) :: boolean()
  def initialized?(server) do
    GenServer.call(server, :initialized?)
  end

  @doc """
  Marks the server as initialized (called after successful initialize request).
  """
  @spec mark_initialized(GenServer.server()) :: :ok
  def mark_initialized(server) do
    GenServer.call(server, :mark_initialized)
  end

  @doc """
  Returns server capabilities.
  """
  @spec get_capabilities(GenServer.server()) :: map()
  def get_capabilities(server) do
    GenServer.call(server, :get_capabilities)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %{
      server_name: opts.server_name,
      server_version: opts.server_version,
      tool_provider: opts.tool_provider,
      tools: opts.tools || [],
      tool_handler: opts.tool_handler,
      capabilities: build_capabilities(opts),
      initialized: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_initialize_result, _from, state) do
    caps = Protocol.server_capabilities(tools: true)

    result =
      Protocol.initialize_result(
        LemonMCP.protocol_version(),
        caps,
        state.server_name,
        state.server_version
      )

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools = do_list_tools(state)
    {:reply, tools, state}
  end

  @impl true
  def handle_call({:call_tool, name, arguments}, _from, state) do
    result = do_call_tool(state, name, arguments)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:initialized?, _from, state) do
    {:reply, state.initialized, state}
  end

  @impl true
  def handle_call(:mark_initialized, _from, state) do
    {:reply, :ok, %{state | initialized: true}}
  end

  @impl true
  def handle_call(:get_capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_server_opts(opts) do
    %{
      server_name: Keyword.get(opts, :server_name, @default_server_name),
      server_version: Keyword.get(opts, :server_version, @default_server_version),
      tool_provider: Keyword.get(opts, :tool_provider),
      tools: Keyword.get(opts, :tools),
      tool_handler: Keyword.get(opts, :tool_handler)
    }
  end

  defp build_capabilities(opts) do
    base_caps = %{tools: true}
    additional_caps = Map.get(opts, :capabilities, %{})
    Map.merge(base_caps, additional_caps)
  end

  defp do_list_tools(%{tool_provider: provider}) when not is_nil(provider) do
    provider.list_tools()
  end

  defp do_list_tools(%{tools: tools}) when is_list(tools) do
    tools
  end

  defp do_list_tools(_) do
    []
  end

  defp do_call_tool(%{tool_provider: provider}, name, arguments)
       when not is_nil(provider) do
    provider.call_tool(name, arguments)
  end

  defp do_call_tool(%{tool_handler: handler}, name, arguments)
       when is_function(handler, 2) do
    handler.(name, arguments)
  end

  defp do_call_tool(_state, name, _arguments) do
    Logger.warning("No tool handler configured for tool: #{name}")
    {:error, :no_tool_handler}
  end
end
