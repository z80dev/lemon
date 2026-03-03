defmodule LemonMCP.WasmServer do
  @moduledoc """
  MCP Server implementation that exposes WASM tools via the Model Context Protocol.

  This module bridges Lemon's WASM tool execution with MCP, allowing WASM tools
  to be discovered and invoked by external MCP clients.

  ## Usage

      # Start a WASM MCP server
      {:ok, pid} = LemonMCP.WasmServer.start_link(
        name: :wasm_mcp_server,
        wasm_paths: ["./tools/wasm"],
        server_name: "Lemon WASM Tools"
      )

      # List available WASM tools via MCP
      tools = LemonMCP.WasmServer.list_tools(pid)

      # Call a WASM tool via MCP
      {:ok, result} = LemonMCP.WasmServer.call_tool(pid, "cast_wallet_address", %{"address" => "0x..."})

  """

  use GenServer

  require Logger

  alias LemonMCP.Protocol

  @default_server_name "Lemon WASM Tools"
  @default_server_version "0.1.0"

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the WASM MCP server.

  ## Options

    * `:name` - Optional process name for registration
    * `:server_name` - Server name for initialize response (default: "Lemon WASM Tools")
    * `:server_version` - Server version (default: "0.1.0")
    * `:wasm_paths` - List of paths to WASM tool directories (required)
    * `:capabilities` - Additional server capabilities
    * `:default_memory_limit` - Default memory limit for WASM tools in bytes (default: 10MB)
    * `:default_timeout_ms` - Default execution timeout in milliseconds (default: 60000)

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
  Returns the server's initialize result for MCP handshake.
  """
  @spec get_initialize_result(GenServer.server()) :: Protocol.InitializeResponse.t()
  def get_initialize_result(server) do
    GenServer.call(server, :get_initialize_result)
  end

  @doc """
  Lists available WASM tools as MCP Tool structs.
  """
  @spec list_tools(GenServer.server()) :: [Protocol.Tool.t()]
  def list_tools(server) do
    GenServer.call(server, :list_tools)
  end

  @doc """
  Calls a WASM tool with the given arguments.

  Returns `{:ok, ToolCallResult.t()}` on success or `{:error, reason}` on failure.
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
  Marks the server as initialized.
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

  @doc """
  Refreshes the WASM tool discovery from configured paths.
  """
  @spec refresh_tools(GenServer.server()) :: :ok
  def refresh_tools(server) do
    GenServer.call(server, :refresh_tools)
  end

  @doc """
  Returns statistics about WASM tool execution.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %{
      server_name: opts.server_name,
      server_version: opts.server_version,
      wasm_paths: opts.wasm_paths,
      capabilities: build_capabilities(opts),
      initialized: false,
      sidecar_pid: nil,
      discovered_tools: %{},
      tool_cache: %{},
      stats: %{
        tools_discovered: 0,
        tools_invoked: 0,
        errors: 0,
        total_execution_time_ms: 0
      },
      defaults: %{
        memory_limit: opts.default_memory_limit,
        timeout_ms: opts.default_timeout_ms
      }
    }

    # Start sidecar session for WASM execution
    case start_sidecar(state) do
      {:ok, sidecar_pid, discovered} ->
        {:ok, %{state | sidecar_pid: sidecar_pid, discovered_tools: discovered}}

      {:error, reason} ->
        Logger.error("Failed to start WASM sidecar: #{inspect(reason)}")
        {:stop, reason}
    end
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
    tools =
      state.discovered_tools
      |> Map.values()
      |> Enum.map(&to_mcp_tool/1)

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:call_tool, name, arguments}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_call_tool(state, name, arguments)

    execution_time = System.monotonic_time(:millisecond) - start_time

    # Update stats
    new_stats =
      case result do
        {:ok, _} ->
          %{
            state.stats
            | tools_invoked: state.stats.tools_invoked + 1,
              total_execution_time_ms: state.stats.total_execution_time_ms + execution_time
          }

        {:error, _} ->
          %{
            state.stats
            | tools_invoked: state.stats.tools_invoked + 1,
              errors: state.stats.errors + 1,
              total_execution_time_ms: state.stats.total_execution_time_ms + execution_time
          }
      end

    # Emit telemetry
    :telemetry.execute(
      [:lemon_mcp, :wasm, :tool_call],
      %{
        duration_ms: execution_time,
        success: match?({:ok, _}, result)
      },
      %{tool_name: name}
    )

    {:reply, result, %{state | stats: new_stats}}
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

  @impl true
  def handle_call(:refresh_tools, _from, state) do
    case CodingAgent.Wasm.SidecarSession.discover(state.sidecar_pid) do
      {:ok, %{tools: tools}} ->
        discovered =
          tools
          |> Enum.map(fn tool -> {tool.name, tool} end)
          |> Map.new()

        new_stats = %{state.stats | tools_discovered: map_size(discovered)}
        {:reply, :ok, %{state | discovered_tools: discovered, stats: new_stats}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    avg_execution_time =
      if state.stats.tools_invoked > 0 do
        div(state.stats.total_execution_time_ms, state.stats.tools_invoked)
      else
        0
      end

    stats =
      Map.merge(state.stats, %{
        tools_available: map_size(state.discovered_tools),
        avg_execution_time_ms: avg_execution_time,
        sidecar_alive: Process.alive?(state.sidecar_pid)
      })

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.sidecar_pid && Process.alive?(state.sidecar_pid) do
      CodingAgent.Wasm.SidecarSession.shutdown(state.sidecar_pid)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_server_opts(opts) do
    %{
      server_name: Keyword.get(opts, :server_name, @default_server_name),
      server_version: Keyword.get(opts, :server_version, @default_server_version),
      wasm_paths: Keyword.get(opts, :wasm_paths, []),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      default_memory_limit: Keyword.get(opts, :default_memory_limit, 10 * 1024 * 1024),
      default_timeout_ms: Keyword.get(opts, :default_timeout_ms, 60_000)
    }
  end

  defp build_capabilities(opts) do
    base_caps = %{tools: true}
    Map.merge(base_caps, Map.get(opts, :capabilities, %{}))
  end

  defp start_sidecar(state) do
    cwd = File.cwd!()

    # Build settings manager map for Config.load
    settings = %{
      tools: %{
        wasm: %{
          enabled: true,
          tool_paths: state.wasm_paths,
          default_memory_limit: state.defaults.memory_limit,
          default_timeout_ms: state.defaults.timeout_ms,
          default_fuel_limit: 10_000_000,
          max_tool_invoke_depth: 4
        }
      }
    }

    # Load proper WASM config
    wasm_config = CodingAgent.Wasm.Config.load(cwd, settings)

    # Start sidecar session with required options
    opts = [
      cwd: cwd,
      session_id: "wasm_mcp_server_#{System.unique_integer([:positive])}",
      wasm_config: wasm_config
    ]

    case CodingAgent.Wasm.SidecarSession.start_link(opts) do
      {:ok, pid} ->
        # Trigger discovery
        case CodingAgent.Wasm.SidecarSession.discover(pid) do
          {:ok, %{tools: tools}} ->
            discovered =
              tools
              |> Enum.map(fn tool -> {tool.name, tool} end)
              |> Map.new()

            {:ok, pid, discovered}

          {:error, reason} ->
            CodingAgent.Wasm.SidecarSession.stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_mcp_tool(discovered_tool) do
    # Parse schema to extract parameters
    schema =
      case Jason.decode(discovered_tool.schema_json) do
        {:ok, parsed} -> parsed
        {:error, _} -> %{"type" => "object", "properties" => %{}}
      end

    %Protocol.Tool{
      name: discovered_tool.name,
      description: discovered_tool.description,
      inputSchema: schema
    }
  end

  defp do_call_tool(state, name, arguments) do
    case Map.get(state.discovered_tools, name) do
      nil ->
        {:error, :tool_not_found}

      tool ->
        context = %{
          cwd: File.cwd!(),
          server_name: state.server_name
        }

        params_json = Jason.encode!(arguments)
        context_json = Jason.encode!(context)

        case CodingAgent.Wasm.SidecarSession.invoke(
               state.sidecar_pid,
               name,
               params_json,
               context_json
             ) do
          {:ok, result} ->
            tool_result = %Protocol.ToolCallResult{
              content: [
                %{
                  type: "text",
                  text: format_output(result)
                }
              ],
              isError: result.error != nil && result.error != ""
            }

            {:ok, tool_result}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp format_output(result) do
    cond do
      is_binary(result.error) && result.error != "" ->
        "Error: #{result.error}"

      is_binary(result.output_json) ->
        case Jason.decode(result.output_json) do
          {:ok, value} when is_binary(value) -> value
          {:ok, value} -> Jason.encode_to_iodata!(value, pretty: true)
          {:error, _} -> result.output_json
        end

      true ->
        "null"
    end
  end
end
