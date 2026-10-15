defmodule CodingAgent.Debug.Client do
  @moduledoc """
  One debug adapter process and its DAP transport.

  The client owns the adapter OS process (an Erlang port) and, for socket-mode
  adapters such as `dlv dap`, the loopback TCP connection the adapter dials back
  into. It frames outgoing requests, correlates nothing itself, and forwards
  every inbound message to its owner as:

    * `{:dap, client, {:response, request_seq, response_map}}`
    * `{:dap, client, {:event, event_name, body}}`
    * `{:dap, client, {:reverse_request, command}}` (already answered)
    * `{:dap, client, {:exit, reason_text}}` (the adapter is gone)

  Reverse requests (`runInTerminal`, `startDebugging`, anything else) are
  answered with an error response: Lemon advertises neither capability and
  never spawns terminals or child debug sessions on an adapter's behalf.

  The client links to its owner and traps exits, so the adapter's whole OS
  process tree (adapter, debug server, debuggee) is killed when the owner dies,
  when `stop/1` is called, or when the client itself crashes.
  """

  use GenServer

  alias CodingAgent.BashExecutor
  alias CodingAgent.Debug.Protocol

  @socket_ready_timeout_ms 10_000
  @max_stderr_bytes 8_192

  @type adapter :: %{
          required(:name) => String.t(),
          required(:command) => String.t(),
          required(:args) => [String.t()],
          optional(:connect_mode) => :stdio | :socket,
          optional(atom()) => term()
        }

  @doc """
  Start an adapter client linked to the caller (the owner).

  Options: `:adapter` (resolved adapter map), `:cwd`, `:owner` (defaults to
  the caller), `:env` (list of `{name, value}` charlist-free string tuples).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts, timeout: @socket_ready_timeout_ms + 5_000)
  end

  @doc "Send a request; returns its sequence number. The response arrives as a message."
  @spec request(pid(), String.t(), map() | nil) :: {:ok, pos_integer()} | {:error, String.t()}
  def request(client, command, arguments \\ nil) when is_binary(command) do
    GenServer.call(client, {:request, command, arguments})
  catch
    :exit, _ -> {:error, "debug adapter is not running"}
  end

  @doc "OS pid of the adapter process, if it is still running."
  @spec os_pid(pid()) :: non_neg_integer() | nil
  def os_pid(client) do
    GenServer.call(client, :os_pid)
  catch
    :exit, _ -> nil
  end

  @doc "Kill the adapter process tree and stop the client. Idempotent."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(client) when is_pid(client) do
    GenServer.stop(client, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    adapter = Keyword.fetch!(opts, :adapter)
    owner = Keyword.fetch!(opts, :owner)
    cwd = Keyword.fetch!(opts, :cwd)

    state = %{
      adapter: adapter,
      owner: owner,
      port: nil,
      os_pid: nil,
      socket: nil,
      buffer: "",
      stderr: "",
      seq: 0,
      exited?: false
    }

    case open_transport(adapter, cwd, Keyword.get(opts, :env, [])) do
      {:ok, port, socket} ->
        {:ok, %{state | port: port, socket: socket, os_pid: port_os_pid(port)}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call({:request, _command, _arguments}, _from, %{exited?: true} = state) do
    {:reply, {:error, "debug adapter #{state.adapter.name} is not running"}, state}
  end

  def handle_call({:request, command, arguments}, _from, state) do
    seq = state.seq + 1

    message =
      %{"seq" => seq, "type" => "request", "command" => command}
      |> maybe_put("arguments", arguments)

    case write(state, Protocol.encode(message)) do
      :ok -> {:reply, {:ok, seq}, %{state | seq: seq}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, socket: nil} = state) do
    {:noreply, ingest(state, data)}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Socket-mode adapters log to stdout; DAP flows over the socket.
    {:noreply, append_stderr(state, data)}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    {:noreply, ingest(state, data)}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    adapter_gone(state, "debug adapter #{state.adapter.name} closed its connection")
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    adapter_gone(state, "debug adapter connection failed: #{inspect(reason)}")
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Unframed bytes still buffered at exit are diagnostics, not protocol.
    if state.os_pid, do: BashExecutor.kill_process_tree(state.os_pid)
    stderr = String.trim(bounded(state.stderr <> state.buffer))

    reason =
      if stderr == "",
        do: "debug adapter #{state.adapter.name} exited (code #{status})",
        else: "debug adapter #{state.adapter.name} exited (code #{status}): #{stderr}"

    adapter_gone(%{state | port: nil, os_pid: nil}, reason)
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) when is_port(port) do
    adapter_gone(%{state | port: nil}, "debug adapter #{state.adapter.name} port closed")
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    shutdown(state)
    :ok
  end

  # ── Transport ────────────────────────────────────────────────────────────

  defp open_transport(adapter, cwd, env) do
    case Map.get(adapter, :connect_mode, :stdio) do
      :remote -> open_remote_transport(adapter)
      :socket -> open_socket_transport(adapter, cwd, env)
      :socket_server -> open_server_transport(adapter, cwd, env)
      _stdio -> open_stdio_transport(adapter, cwd, env)
    end
  end

  defp open_stdio_transport(adapter, cwd, env) do
    with {:ok, port} <- open_port(adapter.command, adapter.args, cwd, env) do
      {:ok, port, nil}
    end
  end

  defp open_remote_transport(adapter) do
    opts = [:binary, packet: :raw, active: true]

    case :gen_tcp.connect(
           String.to_charlist(adapter.host),
           adapter.port,
           opts,
           @socket_ready_timeout_ms
         ) do
      {:ok, socket} -> {:ok, nil, socket}
      {:error, reason} -> {:error, "cannot connect to debug adapter: #{inspect(reason)}"}
    end
  end

  # Standalone adapters listen on loopback; unlike Delve they do not dial back.
  defp open_server_transport(adapter, cwd, env) do
    with {:ok, listener} <- :gen_tcp.listen(0, ip: {127, 0, 0, 1}),
         {:ok, number} <- :inet.port(listener) do
      :gen_tcp.close(listener)
      args = Enum.map(adapter.args, &String.replace(&1, "{port}", Integer.to_string(number)))

      with {:ok, port} <- open_port(adapter.command, args, cwd, env) do
        deadline = System.monotonic_time(:millisecond) + @socket_ready_timeout_ms

        case connect_server(port, number, deadline) do
          {:ok, socket} ->
            {:ok, port, socket}

          {:error, reason} ->
            kill_port_tree(port)
            {:error, reason}
        end
      end
    else
      {:error, reason} -> {:error, "cannot allocate debug adapter port: #{inspect(reason)}"}
    end
  end

  defp connect_server(port, number, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, number, [:binary, packet: :raw, active: true], 100) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error,
           "debug adapter did not listen within #{@socket_ready_timeout_ms}ms: #{inspect(reason)}"}
        else
          receive do
            {^port, {:exit_status, status}} ->
              {:error, "debug adapter exited (code #{status}) before listening"}

            {^port, {:data, _logs}} ->
              connect_server(port, number, deadline)
          after
            50 -> connect_server(port, number, deadline)
          end
        end
    end
  end

  # The adapter dials back into a loopback listener (`dlv dap --client-addr`).
  defp open_socket_transport(adapter, cwd, env) do
    listen_opts = [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]

    with {:ok, listener} <- :gen_tcp.listen(0, listen_opts),
         {:ok, listen_port} <- :inet.port(listener) do
      args = adapter.args ++ ["--client-addr=127.0.0.1:#{listen_port}"]

      result =
        with {:ok, port} <- open_port(adapter.command, args, cwd, env) do
          case accept_adapter(listener, port) do
            {:ok, socket} ->
              :ok = :inet.setopts(socket, active: true)
              {:ok, port, socket}

            {:error, reason} ->
              kill_port_tree(port)
              {:error, reason}
          end
        end

      :gen_tcp.close(listener)
      result
    else
      {:error, reason} -> {:error, "cannot open debug adapter listener: #{inspect(reason)}"}
    end
  end

  defp accept_adapter(listener, port) do
    deadline = System.monotonic_time(:millisecond) + @socket_ready_timeout_ms
    accept_loop(listener, port, deadline, "")
  end

  defp accept_loop(listener, port, deadline, output) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "debug adapter did not connect within #{@socket_ready_timeout_ms}ms"}
    else
      case :gen_tcp.accept(listener, min(remaining, 100)) do
        {:ok, socket} ->
          {:ok, socket}

        {:error, :timeout} ->
          receive do
            {^port, {:exit_status, status}} ->
              {:error, "debug adapter exited (code #{status}) before connecting: #{output}"}

            {^port, {:data, data}} ->
              accept_loop(listener, port, deadline, bounded(output <> data))
          after
            0 -> accept_loop(listener, port, deadline, output)
          end

        {:error, reason} ->
          {:error, "debug adapter connection failed: #{inspect(reason)}"}
      end
    end
  end

  defp open_port(command, args, cwd, env) do
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :use_stdio, :hide, {:args, args}]
      |> maybe_cd(cwd)
      |> maybe_env(env)

    {:ok, Port.open({:spawn_executable, command}, port_opts)}
  rescue
    error -> {:error, "cannot start debug adapter #{command}: #{Exception.message(error)}"}
  end

  defp maybe_cd(opts, cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: [{:cd, cwd} | opts], else: opts
  end

  defp maybe_cd(opts, _cwd), do: opts

  defp maybe_env(opts, []), do: opts

  defp maybe_env(opts, env) do
    [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)} | opts]
  end

  defp write(%{socket: socket}, iodata) when not is_nil(socket) do
    case :gen_tcp.send(socket, iodata) do
      :ok -> :ok
      {:error, reason} -> {:error, "debug adapter write failed: #{inspect(reason)}"}
    end
  end

  defp write(%{port: port}, iodata) when is_port(port) do
    Port.command(port, iodata)
    :ok
  rescue
    ArgumentError -> {:error, "debug adapter is not running"}
  end

  defp write(_state, _iodata), do: {:error, "debug adapter is not running"}

  # ── Inbound ──────────────────────────────────────────────────────────────

  defp ingest(state, data) do
    {messages, rest, junk} = Protocol.decode(state.buffer <> data)
    state = %{append_stderr(state, junk) | buffer: rest}
    Enum.reduce(messages, state, &dispatch/2)
  end

  defp dispatch(%{"type" => "response", "request_seq" => seq} = message, state) do
    notify(state, {:response, seq, message})
    state
  end

  defp dispatch(%{"type" => "event", "event" => event} = message, state) do
    notify(state, {:event, event, Map.get(message, "body") || %{}})
    state
  end

  defp dispatch(%{"type" => "request", "command" => command} = message, state) do
    text = reverse_request_error(command)

    response = %{
      "seq" => state.seq + 1,
      "type" => "response",
      "request_seq" => message["seq"],
      "command" => command,
      "success" => false,
      "message" => text,
      "body" => %{"error" => %{"id" => 1, "format" => text}}
    }

    _ = write(state, Protocol.encode(response))
    notify(state, {:reverse_request, command})
    %{state | seq: state.seq + 1}
  end

  defp dispatch(_message, state), do: state

  defp reverse_request_error("runInTerminal"),
    do: "runInTerminal is not supported by Lemon; the debuggee must use the adapter's console"

  defp reverse_request_error("startDebugging"),
    do: "startDebugging (child debug sessions) is not supported by Lemon"

  defp reverse_request_error(command), do: "Unsupported DAP reverse request: #{command}"

  defp notify(state, payload), do: send(state.owner, {:dap, self(), payload})

  defp append_stderr(state, ""), do: state
  defp append_stderr(state, data), do: %{state | stderr: bounded(state.stderr <> data)}

  defp bounded(text) when byte_size(text) > @max_stderr_bytes do
    binary_part(text, byte_size(text) - @max_stderr_bytes, @max_stderr_bytes)
  end

  defp bounded(text), do: text

  defp adapter_gone(%{exited?: true} = state, _reason), do: {:stop, :normal, state}

  defp adapter_gone(state, reason) do
    notify(state, {:exit, reason})
    {:stop, :normal, %{state | exited?: true}}
  end

  # ── Teardown ─────────────────────────────────────────────────────────────

  defp shutdown(state) do
    if state.os_pid, do: BashExecutor.kill_process_tree(state.os_pid)
    if state.socket, do: :gen_tcp.close(state.socket)

    if is_port(state.port) do
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp kill_port_tree(port) do
    case port_os_pid(port) do
      nil -> :ok
      os_pid -> BashExecutor.kill_process_tree(os_pid)
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp port_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp port_os_pid(_port), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
