defmodule LemonSkills.McpSource do
  @moduledoc """
  MCP (Model Context Protocol) source for discovering and caching tools from MCP servers.

  This module manages connections to external MCP servers, caches discovered tools,
  and provides a unified interface for tool discovery and invocation.
  """

  use GenServer

  require Logger

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @default_cache_ttl_ms :timer.minutes(5)
  @default_refresh_interval_ms :timer.minutes(1)
  @default_tool_timeout_ms :timer.seconds(30)

  @typedoc "MCP server configuration"
  @type server_config ::
          {:stdio, command :: String.t(), args :: [String.t()]}
          | {:http, url :: String.t(), opts :: keyword()}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the MCP source GenServer.
  """
  def start_link(opts \\ []) do
    if mcp_enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      GenServer.start_link(__MODULE__, [disabled: true], name: __MODULE__)
    end
  end

  @doc """
  Discover all tools from configured MCP servers.
  """
  @spec discover_tools(keyword()) :: [AgentTool.t()]
  def discover_tools(opts \\ []) do
    GenServer.call(__MODULE__, {:discover_tools, opts}, :infinity)
  end

  @doc """
  Get a specific tool by name from MCP sources.
  """
  @spec get_tool(String.t()) :: {:ok, AgentTool.t()} | :error
  def get_tool(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end

  @doc """
  Call a tool from an MCP server.
  """
  @spec call_tool(String.t(), map(), keyword()) ::
          {:ok, AgentToolResult.t()} | {:error, term()}
  def call_tool(tool_name, params, opts \\ []) do
    GenServer.call(__MODULE__, {:call_tool, tool_name, params, opts}, :infinity)
  end

  @doc """
  Refresh the tool cache from all MCP servers.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :refresh, :infinity)
  end

  @doc """
  Get the status of all configured MCP servers.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Validate an MCP server configuration.
  """
  @spec validate_config(server_config()) :: :ok | {:error, String.t()}
  def validate_config({:stdio, command, args})
      when is_binary(command) and is_list(args) do
    if String.trim(command) == "" do
      {:error, "stdio command cannot be empty"}
    else
      :ok
    end
  end

  def validate_config({:http, url, _opts}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        :ok
      _ ->
        {:error, "invalid HTTP URL: #{url}"}
    end
  end

  def validate_config({:http, url}) when is_binary(url) do
    validate_config({:http, url, []})
  end

  def validate_config(config) do
    {:error, "invalid MCP server config: #{inspect(config)}"}
  end

  @doc """
  Check if MCP support is available and enabled.
  """
  @spec mcp_enabled?() :: boolean()
  def mcp_enabled? do
    disabled = Application.get_env(:lemon_skills, :mcp_disabled, false)

    if disabled do
      false
    else
      Code.ensure_loaded?(LemonMCP.Client)
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    disabled = Keyword.get(opts, :disabled, false)

    if disabled do
      {:ok, %{disabled: true, tool_cache: %{}, servers: %{}}}
    else
      cache_ttl = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
      refresh_interval = Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)

      state = %{
        disabled: false,
        servers: %{},
        tool_cache: %{},
        cache_ttl_ms: cache_ttl,
        refresh_interval_ms: refresh_interval,
        refresh_timer: nil
      }

      state = initialize_servers(state)
      state = schedule_refresh(state)

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:discover_tools, _opts}, _from, %{disabled: true} = state) do
    {:reply, [], state}
  end

  @impl true
  def handle_call({:discover_tools, opts}, _from, state) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    {tools, state} =
      if force_refresh or cache_expired?(state) do
        refresh_tools(state)
      else
        {cached_tools(state), state}
      end

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:get_tool, _name}, _from, %{disabled: true} = state) do
    {:reply, :error, state}
  end

  @impl true
  def handle_call({:get_tool, name}, _from, state) do
    result =
      case Map.get(state.tool_cache, name) do
        nil -> :error
        %{tool: tool} -> {:ok, tool}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _params, _opts}, _from, %{disabled: true} = state) do
    {:reply, {:error, :mcp_disabled}, state}
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _params, _opts}, _from, state) do
    # Since LemonMCP.Client is not fully implemented yet, return not_found
    {:reply, {:error, :mcp_client_not_available}, state}
  end

  @impl true
  def handle_call(:refresh, _from, %{disabled: true} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {_tools, state} = refresh_tools(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, %{disabled: true} = state) do
    {:reply, %{disabled: true, servers: %{}, cached_tools: 0}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      disabled: false,
      servers:
        Map.new(state.servers, fn {name, server} ->
          {name,
           %{
             connected: server.connected,
             tool_count: length(server.tools),
             last_error: server.last_error
           }}
        end),
      cached_tools: map_size(state.tool_cache),
      cache_ttl_ms: state.cache_ttl_ms
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:periodic_refresh, %{disabled: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_refresh, state) do
    state =
      if cache_expired?(state) do
        {_, new_state} = refresh_tools(state)
        new_state
      else
        state
      end

    state = schedule_refresh(state)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp initialize_servers(state) do
    config = LemonSkills.Config.mcp_config()

    if config.enabled do
      configs = config.servers

      servers =
        Enum.reduce(configs, %{}, fn cfg, acc ->
          name = server_name(cfg)

          server = %{
            config: cfg,
            client: nil,
            connected: false,
            last_error: nil,
            tools: []
          }

          Map.put(acc, name, server)
        end)

      %{state | servers: servers}
    else
      %{state | servers: %{}}
    end
  end

  defp server_name({:stdio, command, args}) do
    :crypto.hash(:md5, :erlang.term_to_binary({:stdio, command, args}))
    |> Base.encode16(case: :lower)
    |> String.to_atom()
  end

  defp server_name({:http, url, _opts}) do
    :crypto.hash(:md5, url)
    |> Base.encode16(case: :lower)
    |> String.to_atom()
  end

  defp server_name({:http, url}) do
    server_name({:http, url, []})
  end

  defp cache_expired?(state) do
    if map_size(state.tool_cache) == 0 do
      true
    else
      now = System.monotonic_time(:millisecond)

      Enum.any?(state.tool_cache, fn {_name, cached} ->
        now - cached.cached_at > state.cache_ttl_ms
      end)
    end
  end

  defp cached_tools(state) do
    state.tool_cache
    |> Map.values()
    |> Enum.map(& &1.tool)
    |> Enum.sort_by(& &1.name)
  end

  defp refresh_tools(state) do
    # Since LemonMCP.Client is not fully implemented, return empty tools
    {[], %{state | tool_cache: %{}}}
  end

  defp schedule_refresh(state) do
    if state.refresh_timer do
      Process.cancel_timer(state.refresh_timer)
    end

    timer = Process.send_after(self(), :periodic_refresh, state.refresh_interval_ms)
    %{state | refresh_timer: timer}
  end
end
