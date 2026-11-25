defmodule LemonMCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP servers.

  This transport owns the MCP server's Port and process group. It implements
  `LemonCore.Rpc.Transport`, sending already-framed bytes and forwarding incoming
  chunks to its message handler. JSON-line framing belongs to `LemonMCP.Framing.Stdio`.

  ## Usage

  Start a transport connection:

      {:ok, transport} = LemonMCP.Transport.Stdio.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
      )

  Send already-framed bytes:

      :ok = LemonMCP.Transport.Stdio.send(transport, json_message <> "\\n")

  Receive byte chunks via the message handler callback. Stderr remains merged
  into stdout; the MCP framing module tolerates non-protocol log lines.

  ## Message Format

  Messages are sent as newline-delimited JSON:

      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{...}}\n

  ## Cleanup

  The server is spawned through an Erlang Port, which starts it as the leader of
  its own process group. Closing the Port only delivers stdin EOF, which a server
  or its children may ignore, so `close/1` and `terminate/2` (also reached when
  the owner exits, because the transport traps exits) first terminate the whole
  group: SIGTERM, a bounded grace period, then SIGKILL until the group is empty
  (`LemonCore.ProcessGroup.terminate/2`). Children that deliberately left the
  group (their own `setsid`) are outside this guarantee, and a brutal kill of the
  transport process itself cannot run cleanup.
  """

  use GenServer
  @behaviour LemonCore.Rpc.Transport
  import Kernel, except: [send: 2]

  require Logger

  # Grace between SIGTERM and SIGKILL when stopping the server's process group.
  @term_grace_ms 1_000

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "Transport state"
  @type state :: %{
          port: port() | nil,
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          port_open: (term(), list() -> port()),
          message_handler: (binary() -> any()) | nil,
          os_pid: pos_integer() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a stdio transport connection to an MCP server.

  ## Options

  - `:command` - (required) The command to spawn the MCP server
  - `:args` - Arguments to pass to the command
  - `:env` - Additional environment variables as keyword list or map
  - `:port_open` - Host opener `(spec, options -> port)` (default: `&Port.open/2`).
    Must have arity two and return a port; refusals never fall back to `Port.open/2`.
  - `:message_handler` - Callback for received byte chunks `(binary() -> any())`
  - `:name` - GenServer name registration

  ## Examples

      {:ok, transport} = LemonMCP.Transport.Stdio.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sends a JSON-RPC message to the MCP server.

  The message should be a JSON-encoded string with a trailing newline
  automatically added.
  """
  @spec send_message(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_message(server, message) do
    bytes = if String.ends_with?(message, "\n"), do: message, else: message <> "\n"
    send(server, bytes)
  end

  @doc "Sends already-framed bytes without adding a newline."
  @impl LemonCore.Rpc.Transport
  @spec send(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send(server, bytes) do
    GenServer.call(server, {:send, bytes})
  end

  @doc """
  Closes the transport connection.
  """
  @impl LemonCore.Rpc.Transport
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.call(server, :close, :infinity)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Returns the current connection state.
  """
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server) do
    GenServer.call(server, :connected?)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    message_handler = Keyword.get(opts, :message_handler)

    state = %{
      port: nil,
      command: command,
      args: args,
      cwd: Keyword.get(opts, :cwd),
      env: normalize_env(env),
      port_open: Keyword.get(opts, :port_open, &Port.open/2),
      message_handler: message_handler,
      os_pid: nil
    }

    # Trap exits so `terminate/2` runs (and stops the server's process group)
    # when the owner exits or the supervisor shuts the transport down.
    Process.flag(:trap_exit, true)

    # Start the port
    case spawn_server(state) do
      {:ok, port} ->
        {:ok, %{state | port: port, os_pid: os_pid(port)}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, _message}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call({:send, bytes}, _from, %{port: port} = state) do
    true = Port.command(port, bytes)
    {:reply, :ok, state}
  rescue
    ArgumentError -> {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call(:close, _from, %{port: nil} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    stop_server(state)
    {:reply, :ok, %{state | port: nil, os_pid: nil}}
  end

  @impl true
  def handle_call(:connected?, _from, %{port: port} = state) do
    {:reply, port != nil, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    handle_message(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("MCP server exited with status #{status}")
    {:stop, :normal, %{state | port: nil}}
  end

  # Exits are trapped for cleanup; an abnormal Port failure must still stop the
  # transport (as the link did before) so terminate/2 stops the server group.
  def handle_info({:EXIT, port, reason}, %{port: port} = state) when reason != :normal do
    {:stop, {:port_exit, reason}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_server(state)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp spawn_server(%{port_open: port_open}) when not is_function(port_open, 2),
    do: {:error, :invalid_port_open}

  defp spawn_server(state) do
    port_options = [
      :binary,
      :use_stdio,
      :eof,
      :exit_status,
      :stderr_to_stdout,
      args: state.args,
      # Configured variables overlay the inherited env; Lemon's own
      # credentials are explicitly unset and cannot be re-supplied.
      env: LemonCore.ChildEnv.port_env(state.env)
    ]

    port_options =
      if state.cwd, do: [{:cd, state.cwd} | port_options], else: port_options

    with {:ok, executable} <- find_executable(state.command) do
      case state.port_open.({:spawn_executable, executable}, port_options) do
        port when is_port(port) ->
          {:ok, port}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :invalid_port_open_result}
      end
    end
  rescue
    e ->
      {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp stop_server(state) do
    os_pid = Map.get(state, :os_pid)

    _ =
      if is_integer(os_pid) and match?({:unix, _}, :os.type()),
        do: LemonCore.ProcessGroup.terminate(os_pid, grace_ms: @term_grace_ms)

    close_port(Map.get(state, :port))
    :ok
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_port), do: :ok

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp find_executable(command) do
    cond do
      not is_binary(command) ->
        {:error, {:invalid_command, "command must be a string"}}

      String.trim(command) == "" ->
        {:error, {:invalid_command, "command cannot be empty"}}

      true ->
        case System.find_executable(command) do
          nil -> {:error, {:invalid_command, "Executable not found: #{command}"}}
          path -> {:ok, path}
        end
    end
  end

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        {String.to_charlist(key), String.to_charlist(value)}

      {key, value} when is_atom(key) and is_binary(value) ->
        {String.to_charlist(Atom.to_string(key)), String.to_charlist(value)}
    end)
  end

  defp normalize_env(env) when is_map(env) do
    env
    |> Enum.to_list()
    |> normalize_env()
  end

  defp handle_message(_bytes, %{message_handler: nil}) do
    :ok
  end

  defp handle_message(message, %{message_handler: handler}) when is_function(handler, 1) do
    try do
      handler.(message)
    rescue
      _ ->
        Logger.error("MCP transport message handler failed")
    end
  end
end
