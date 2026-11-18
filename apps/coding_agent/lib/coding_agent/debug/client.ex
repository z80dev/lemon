defmodule CodingAgent.Debug.Client do
  @moduledoc """
  One debug adapter process and its DAP transport.

  The client owns the adapter OS process (an Erlang port) and, for socket-mode
  adapters such as `dlv dap`, the loopback TCP connection the adapter dials back
  into. `LemonCore.Rpc.Client` owns framing buffers, request correlation and
  deadlines; this wrapper owns DAP policy and forwards results to its owner as:

    * `{:dap, client, {:response, request_seq, response_map}}`
    * `{:dap, client, {:request_error, request_seq, reason}}`
    * `{:dap, client, {:event, event_name, body}}`
    * `{:dap, client, {:start_debugging, request}}` (owner must answer)
    * `{:dap, client, {:reverse_request, command}}` (unsupported, already answered)
    * `{:dap, client, {:exit, reason_text}}` (the adapter is gone)

  The session owner handles `startDebugging`; other reverse requests are rejected.

  `request/4` remains asynchronous: it returns the assigned sequence number,
  and the shared engine delivers exactly one response or request error. The
  timeout defaults to 30 seconds. `cancel/2` removes an outstanding request
  without replying; late and unknown responses are ignored. Session-level
  event waits and abort subscriptions remain with `SessionServer`.

  Socket accept/connect waits run in a monitored supervised worker, not in
  callbacks. The client remains inspectable and stoppable during the handshake;
  `start_link/1` waits for readiness in its caller and returns only once requests
  can be sent. Stopping during startup closes the listener, worker and adapter.

  The client links to its owner and traps exits, so the adapter's OS process
  group (adapter, debug server, debuggee) is killed when the owner dies, when
  `stop/1` is called, or when the client itself crashes. Descendants that escape
  that group are not contained by this cleanup.
  """

  use GenServer

  alias CodingAgent.Debug.Protocol
  alias LemonCore.Rpc.Client, as: RpcClient
  alias LemonCore.ProcessGroup

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
    token = make_ref()

    opts =
      opts
      |> Keyword.put_new(:owner, self())
      |> Keyword.put(:startup_notify, {self(), token})

    with {:ok, client} <- GenServer.start_link(__MODULE__, opts) do
      await_startup(client, token)
    end
  end

  @doc "Send a request; returns its sequence number. Its result arrives as a message."
  @spec request(pid(), String.t(), map() | nil, timeout()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  def request(client, command, arguments \\ nil, timeout \\ 30_000) when is_binary(command) do
    GenServer.call(client, {:request, command, arguments, timeout})
  catch
    :exit, _ -> {:error, "debug adapter is not running"}
  end

  @doc "Forget a request without delivering a result. Late responses are ignored."
  @spec cancel(pid(), pos_integer()) :: :ok
  def cancel(client, seq) do
    GenServer.call(client, {:cancel, seq})
  catch
    :exit, _ -> :ok
  end

  @doc "Answer an adapter's startDebugging reverse request."
  def respond(client, request, result) do
    GenServer.call(client, {:respond, request, result})
  catch
    :exit, _ -> {:error, "debug adapter is not running"}
  end

  @doc "Adapter endpoint for a child session (server adapters share their listener)."
  def child_adapter(client), do: GenServer.call(client, :child_adapter)

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

  defp await_startup(client, token) do
    ref = Process.monitor(client)

    result =
      receive do
        {^token, :ok} ->
          {:ok, client}

        {^token, {:error, reason}} ->
          {:error, {:shutdown, reason}}

        {:DOWN, ^ref, :process, ^client, _reason} ->
          {:error, {:shutdown, "debug adapter stopped before connecting"}}
      after
        @socket_ready_timeout_ms + 5_000 ->
          {:error, {:shutdown, "debug adapter startup timed out"}}
      end

    Process.demonitor(ref, [:flush])
    if match?({:error, _}, result), do: stop(client)
    result
  end

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
      rpc: nil,
      listener: nil,
      startup_task: nil,
      startup_notify: Keyword.get(opts, :startup_notify),
      ready?: false,
      rpc_ref: nil,
      stderr: "",
      seq: 0,
      exited?: false
    }

    {:ok, state, {:continue, {:open_transport, cwd, Keyword.get(opts, :env, [])}}}
  end

  @impl true
  def handle_continue({:open_transport, cwd, env}, state) do
    case open_transport(state.adapter, cwd, env) do
      {:ok, port, socket} ->
        finish_startup(%{state | port: port, os_pid: port_os_pid(port)}, socket)

      {:connect, port, listener, connect} ->
        state = %{state | port: port, os_pid: port_os_pid(port), listener: listener}
        start_connection(state, connect)

      {:error, reason} ->
        startup_failed(state, reason)
    end
  end

  @impl true
  def handle_call({:request, _command, _arguments, _timeout}, _from, %{exited?: true} = state) do
    {:reply, {:error, "debug adapter #{state.adapter.name} is not running"}, state}
  end

  def handle_call({:request, _command, _arguments, _timeout}, _from, %{ready?: false} = state) do
    {:reply, {:error, "debug adapter is still connecting"}, state}
  end

  def handle_call({:request, command, arguments, timeout}, {caller, _tag}, state) do
    seq = state.seq + 1

    message =
      %{"seq" => seq, "type" => "request", "command" => command}
      |> maybe_put("arguments", arguments)

    # Launch/attach may create independently owned or external work. Record the
    # uncertainty before writing; a failed write/response does not prove rollback.
    # Exited-client and failed-connect refusals never reach this boundary.
    if command in ["launch", "attach"], do: LemonCore.NativeProcess.unsupported!()

    from = {self(), {:dap_request, seq}}

    case RpcClient.dispatch(state.rpc, seq, message, from, timeout, caller) do
      :ok -> {:reply, {:ok, seq}, %{state | seq: seq}}
      {:error, reason} -> {:reply, {:error, reason}, %{state | seq: seq}}
    end
  end

  def handle_call({:cancel, _seq}, _from, %{ready?: false} = state),
    do: {:reply, :ok, state}

  def handle_call({:cancel, seq}, _from, state) do
    :ok = RpcClient.cancel(state.rpc, seq)
    flush_request(seq)
    {:reply, :ok, state}
  end

  def handle_call({:respond, _request, _result}, _from, %{ready?: false} = state),
    do: {:reply, {:error, "debug adapter is still connecting"}, state}

  def handle_call({:respond, request, result}, _from, state) do
    response = %{
      "seq" => state.seq + 1,
      "type" => "response",
      "request_seq" => request["seq"],
      "command" => request["command"],
      "success" => result == :ok
    }

    response =
      case result do
        :ok -> response
        {:error, message} -> Map.put(response, "message", message)
      end

    {:reply, RpcClient.send_message(state.rpc, response), %{state | seq: state.seq + 1}}
  end

  def handle_call(:child_adapter, _from, %{ready?: false} = state),
    do: {:reply, {:error, "debug adapter is still connecting"}, state}

  def handle_call(:child_adapter, _from, state) do
    adapter =
      if state.adapter[:connect_mode] == :socket_server do
        {:ok, {host, port}} = :inet.peername(state.socket)

        Map.merge(state.adapter, %{
          connect_mode: :remote,
          host: List.to_string(:inet.ntoa(host)),
          port: port
        })
      else
        state.adapter
      end

    {:reply, adapter, state}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_info({ref, result}, %{startup_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if state.listener, do: :gen_tcp.close(state.listener)
    state = %{state | startup_task: nil, listener: nil}

    case result do
      {:ok, socket} -> finish_startup(state, socket)
      {:error, reason} -> startup_failed(state, reason)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{startup_task: %Task{ref: ref}} = state) do
    startup_failed(%{state | startup_task: nil}, "debug adapter connection worker stopped")
  end

  def handle_info({:rpc_message, message}, state), do: {:noreply, dispatch(message, state)}

  def handle_info({{:dap_request, seq}, result}, state) do
    deliver_result(state, seq, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{rpc_ref: ref} = state) do
    adapter_gone(drain_inbound(state), "debug adapter RPC connection closed")
  end

  def handle_info({port, {:data, data}}, %{port: port, ready?: false} = state) do
    {:noreply, append_stderr(state, data)}
  end

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
    # Drain already-fed frames and the diagnostic tail before reporting exit.
    state = sync_inbound(state)
    if state.os_pid, do: ProcessGroup.terminate(state.os_pid, signal: :sigkill)
    stderr = String.trim(state.stderr)

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
    close_rpc(state)
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
    {:connect, nil, nil,
     fn ->
       case :gen_tcp.connect(
              String.to_charlist(adapter.host),
              adapter.port,
              [:binary, packet: :raw, active: false],
              @socket_ready_timeout_ms
            ) do
         {:ok, socket} -> {:ok, socket}
         {:error, reason} -> {:error, "cannot connect to debug adapter: #{inspect(reason)}"}
       end
     end}
  end

  # Standalone adapters listen on loopback; unlike Delve they do not dial back.
  defp open_server_transport(adapter, cwd, env) do
    with {:ok, listener} <- :gen_tcp.listen(0, ip: {127, 0, 0, 1}),
         {:ok, number} <- :inet.port(listener) do
      :gen_tcp.close(listener)
      args = Enum.map(adapter.args, &String.replace(&1, "{port}", Integer.to_string(number)))

      with {:ok, port} <- open_port(adapter.command, args, cwd, env) do
        deadline = System.monotonic_time(:millisecond) + @socket_ready_timeout_ms

        {:connect, port, nil, fn -> connect_server(number, deadline) end}
      end
    else
      {:error, reason} -> {:error, "cannot allocate debug adapter port: #{inspect(reason)}"}
    end
  end

  defp connect_server(number, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, number, [:binary, packet: :raw, active: false], 100) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error,
           "debug adapter did not listen within #{@socket_ready_timeout_ms}ms: #{inspect(reason)}"}
        else
          Process.sleep(50)
          connect_server(number, deadline)
        end
    end
  end

  # The adapter dials back into a loopback listener (`dlv dap --client-addr`).
  defp open_socket_transport(adapter, cwd, env) do
    listen_opts = [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]

    with {:ok, listener} <- :gen_tcp.listen(0, listen_opts),
         {:ok, listen_port} <- :inet.port(listener) do
      args = adapter.args ++ ["--client-addr=127.0.0.1:#{listen_port}"]

      case open_port(adapter.command, args, cwd, env) do
        {:ok, port} ->
          {:connect, port, listener,
           fn ->
             case :gen_tcp.accept(listener, @socket_ready_timeout_ms) do
               {:ok, socket} ->
                 {:ok, socket}

               {:error, :timeout} ->
                 {:error, "debug adapter did not connect within #{@socket_ready_timeout_ms}ms"}

               {:error, reason} ->
                 {:error, "debug adapter connection failed: #{inspect(reason)}"}
             end
           end}

        {:error, reason} ->
          :gen_tcp.close(listener)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, "cannot open debug adapter listener: #{inspect(reason)}"}
    end
  end

  defp start_connection(state, connect) do
    client = self()

    try do
      task =
        Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
          with {:ok, socket} <- connect.() do
            case :gen_tcp.controlling_process(socket, client) do
              :ok ->
                {:ok, socket}

              {:error, _reason} ->
                :gen_tcp.close(socket)
                {:error, "debug adapter connection ownership transfer failed"}
            end
          end
        end)

      {:noreply, %{state | startup_task: task}}
    rescue
      _ -> startup_failed(state, "debug adapter connection worker unavailable")
    catch
      :exit, _ -> startup_failed(state, "debug adapter connection worker unavailable")
    end
  end

  defp finish_startup(state, socket) do
    state = %{state | socket: socket}
    transport = %{port: state.port, socket: socket}

    case RpcClient.start_link(
           owner: self(),
           framing: Protocol.Framing,
           send: fn encoded -> write(transport, encoded) end
         ) do
      {:ok, rpc} ->
        state = %{state | rpc: rpc, rpc_ref: Process.monitor(rpc)}

        case if(socket, do: :inet.setopts(socket, active: true), else: :ok) do
          :ok ->
            notify_startup(state, :ok)
            {:noreply, %{state | ready?: true, startup_notify: nil}}

          {:error, _reason} ->
            startup_failed(state, "debug adapter connection closed during startup")
        end

      {:error, _reason} ->
        startup_failed(state, "debug adapter RPC connection could not start")
    end
  end

  defp startup_failed(state, reason) do
    notify_startup(state, {:error, reason})
    {:stop, :normal, %{state | startup_notify: nil, exited?: true}}
  end

  defp notify_startup(%{startup_notify: {starter, token}}, result),
    do: send(starter, {token, result})

  defp notify_startup(_state, _result), do: :ok

  defp open_port(command, args, cwd, env) do
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :use_stdio, :hide, {:args, args}]
      |> maybe_cd(cwd)
      |> then(&[{:env, LemonCore.ChildEnv.port_env(env)} | &1])

    {:ok, LemonCore.NativeProcess.open({:spawn_executable, command}, port_opts)}
  rescue
    error -> {:error, "cannot start debug adapter #{command}: #{Exception.message(error)}"}
  end

  defp maybe_cd(opts, cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: [{:cd, cwd} | opts], else: opts
  end

  defp maybe_cd(opts, _cwd), do: opts

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
    RpcClient.feed(state.rpc, data)
    state
  end

  defp dispatch({:diagnostic, bytes}, state), do: append_stderr(state, bytes)

  defp dispatch(%{"type" => "response", "request_seq" => seq} = message, state) do
    try do
      RpcClient.complete(state.rpc, seq, {:ok, message})
    catch
      :exit, _ -> :ok
    end

    # complete/3 has delivered its reply before returning. Relay it now so
    # subsequent events keep their wire ordering without a local pending map.
    drain_results(state)
  end

  defp dispatch(%{"type" => "event", "event" => event} = message, state) do
    notify(state, {:event, event, Map.get(message, "body") || %{}})
    state
  end

  defp dispatch(%{"type" => "request", "command" => "startDebugging"} = message, state) do
    notify(state, {:start_debugging, message})
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

    _ = RpcClient.send_message(state.rpc, response)
    notify(state, {:reverse_request, command})
    %{state | seq: state.seq + 1}
  end

  defp dispatch(_message, state), do: state

  defp reverse_request_error("runInTerminal"),
    do: "runInTerminal is not supported by Lemon; the debuggee must use the adapter's console"

  defp reverse_request_error(command), do: "Unsupported DAP reverse request: #{command}"

  defp notify(state, payload), do: send(state.owner, {:dap, self(), payload})

  defp deliver_result(state, seq, {:ok, response}), do: notify(state, {:response, seq, response})

  defp deliver_result(state, seq, {:error, reason}),
    do: notify(state, {:request_error, seq, reason})

  defp drain_results(state) do
    receive do
      {{:dap_request, seq}, result} ->
        deliver_result(state, seq, result)
        drain_results(state)
    after
      0 -> state
    end
  end

  defp flush_request(seq) do
    receive do
      {{:dap_request, ^seq}, _result} -> flush_request(seq)
    after
      0 -> :ok
    end
  end

  defp sync_inbound(%{rpc: nil} = state), do: state

  defp sync_inbound(state) do
    # Taking the tail also synchronizes all preceding feed casts. Drain their
    # decoded messages before appending any unfinished frame as exit diagnostics.
    tail =
      try do
        RpcClient.take_buffer(state.rpc)
      catch
        :exit, _ -> ""
      end

    state |> drain_inbound() |> append_stderr(tail)
  end

  defp drain_inbound(state) do
    receive do
      {:rpc_message, message} -> drain_inbound(dispatch(message, state))
    after
      0 -> drain_results(state)
    end
  end

  defp append_stderr(state, ""), do: state
  defp append_stderr(state, data), do: %{state | stderr: bounded(state.stderr <> data)}

  defp bounded(text) when byte_size(text) > @max_stderr_bytes do
    binary_part(text, byte_size(text) - @max_stderr_bytes, @max_stderr_bytes)
  end

  defp bounded(text), do: text

  defp adapter_gone(%{ready?: false} = state, reason), do: startup_failed(state, reason)

  defp adapter_gone(%{exited?: true} = state, _reason), do: {:stop, :normal, state}

  defp adapter_gone(state, reason) do
    state = sync_inbound(state)
    notify(state, {:exit, reason})
    close_rpc(state)
    {:stop, :normal, %{state | exited?: true}}
  end

  # ── Teardown ─────────────────────────────────────────────────────────────

  defp close_rpc(%{rpc: rpc} = state) when is_pid(rpc) do
    try do
      RpcClient.fail_all(rpc, {:error, :connection_closed})
      drain_results(state)
      :gen_statem.stop(rpc)
    catch
      :exit, _ -> :ok
    end
  end

  defp close_rpc(_state), do: :ok

  defp shutdown(state) do
    if state.startup_task, do: Process.exit(state.startup_task.pid, :kill)
    if state.listener, do: :gen_tcp.close(state.listener)
    if state.os_pid, do: ProcessGroup.terminate(state.os_pid, signal: :sigkill)
    if state.socket, do: :gen_tcp.close(state.socket)

    if is_port(state.port) do
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      end
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
