defmodule LemonMCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP servers.

  This transport spawns an MCP server as a child process and communicates
  with it via stdin/stdout using JSON-RPC 2.0 messages over newline-delimited
  JSON (JSONL).

  ## Usage

  Start a transport connection:

      {:ok, transport} = LemonMCP.Transport.Stdio.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]
      )

  Send a message:

      :ok = LemonMCP.Transport.Stdio.send_message(transport, json_message)

  Receive messages via the message handler callback.

  ## Message Format

  Messages are sent as newline-delimited JSON:

      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{...}}\n
  """

  use GenServer

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "Transport state"
  @type state :: %{
          port: port() | nil,
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          message_handler: (String.t() -> any()) | nil,
          buffer: String.t(),
          pending: map()
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
  - `:message_handler` - Callback function for received messages `(String.t() -> any())`
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
    GenServer.call(server, {:send, message})
  end

  @doc """
  Closes the transport connection.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.call(server, :close)
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
      env: normalize_env(env),
      message_handler: message_handler,
      buffer: "",
      pending: %{}
    }

    # Start the port
    case spawn_server(state) do
      {:ok, port} ->
        {:ok, %{state | port: port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, _message}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call({:send, message}, _from, %{port: port} = state) do
    # Ensure message ends with newline
    message_with_nl = if String.ends_with?(message, "\n"), do: message, else: message <> "\n"

    case Port.command(port, message_with_nl) do
      true ->
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :send_failed}, state}
    end
  end

  @impl true
  def handle_call(:close, _from, %{port: nil} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:close, _from, %{port: port} = state) do
    Port.close(port)
    {:reply, :ok, %{state | port: nil}}
  end

  @impl true
  def handle_call(:connected?, _from, %{port: port} = state) do
    {:reply, port != nil, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, buffer: buffer} = state) do
    # Accumulate data in buffer and process complete lines
    new_buffer = buffer <> data
    {messages, remaining} = extract_messages(new_buffer)

    # Handle each complete message
    Enum.each(messages, &handle_message(&1, state))

    {:noreply, %{state | buffer: remaining}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("MCP server exited with status #{status}")
    {:noreply, %{state | port: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when port != nil do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp spawn_server(state) do
    port_options = [
      :binary,
      :eof,
      :exit_status,
      :stderr_to_stdout,
      args: state.args,
      env: state.env
    ]

    case Port.open({:spawn_executable, find_executable(state.command)}, port_options) do
      port when is_port(port) ->
        {:ok, port}

      error ->
        {:error, {:port_open_failed, error}}
    end
  rescue
    e ->
      {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil ->
        raise "Executable not found: #{command}"

      path ->
        path
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

  defp extract_messages(buffer) do
    buffer
    |> String.split("\n")
    |> extract_messages_acc([])
  end

  defp extract_messages_acc([last], acc) do
    # Last element is the incomplete line (or empty if buffer ended with newline)
    {Enum.reverse(acc), last}
  end

  defp extract_messages_acc([line | rest], acc) do
    line = String.trim(line)

    if line == "" do
      extract_messages_acc(rest, acc)
    else
      extract_messages_acc(rest, [line | acc])
    end
  end

  defp handle_message(message, %{message_handler: nil}) do
    Logger.debug("Received MCP message (no handler): #{inspect(message)}")
  end

  defp handle_message(message, %{message_handler: handler}) when is_function(handler, 1) do
    try do
      handler.(message)
    rescue
      e ->
        Logger.error("Message handler failed: #{Exception.message(e)}")
    end
  end
end
