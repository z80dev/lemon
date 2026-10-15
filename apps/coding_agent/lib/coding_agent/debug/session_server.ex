defmodule CodingAgent.Debug.SessionServer do
  @moduledoc """
  Per-coding-session Debug Adapter Protocol session owner.

  One server runs per coding session (registered in `CodingAgent.Debug.Registry`
  under the session id and started under `CodingAgent.Debug.Supervisor`). It
  holds one root debug session and adapter-requested child sessions. Breakpoint
  lists persist across root relaunches and may be set before `launch`.

  The server owns a linked `CodingAgent.Debug.Client` for the adapter and
  processes every operation synchronously: DAP responses and events arrive as
  messages, so handshake ordering, stop waits and abort polling are a single
  receive loop. Event-driven state (stop location, threads, exit code, output
  ring buffer) is applied in arrival order whether it arrives during an
  operation or between operations.

  Lifecycle: the adapter process tree is killed on `terminate`, when the
  debuggee terminates, when a launch/attach handshake fails or is aborted, when
  the owning coding session process exits (monitored `:session_pid`), when the
  server idles past its timeout, and when the server itself stops for any
  reason (linked client with trapped exits).
  """

  use GenServer

  alias CodingAgent.BashExecutor
  alias CodingAgent.Debug.Adapters
  alias CodingAgent.Debug.Client
  alias LemonAgent.AbortSignal

  @registry CodingAgent.Debug.Registry
  @supervisor CodingAgent.Debug.Supervisor

  @idle_timeout_ms 10 * 60 * 1000
  @max_output_bytes 128 * 1024
  @dispose_timeout_ms 2_000
  @poll_ms 50
  @call_slack_ms 15_000

  @start_actions ~w(launch attach set_breakpoint remove_breakpoint set_function_breakpoint remove_function_breakpoint)

  # ── Public API ───────────────────────────────────────────────────────────

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 10_000
    }
  end

  @doc false
  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    value = %{session_key: Keyword.get(opts, :session_key), started_at: System.monotonic_time()}
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, key, value}})
  end

  @doc "Server pid for a session key, if one is running."
  @spec whereis(term()) :: pid() | nil
  def whereis(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Run one debug action for the session `key`.

  `request` is `%{action: String.t(), ...}` with action-specific fields.
  `opts`: `:owner` (coding session pid to monitor), `:timeout_ms`, `:signal`,
  `:idle_timeout_ms`.

  Returns `{:ok, data}`, `{:error, message}` or `{:aborted, message}`.
  `{:none, message}` means there is no server/session for a read-only action.
  """
  @spec call(term(), map(), keyword()) ::
          {:ok, map()} | {:error, String.t()} | {:aborted, String.t()} | {:none, String.t()}
  def call(key, %{action: action} = request, opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    ctx = %{
      timeout_ms: timeout_ms,
      deadline: System.monotonic_time(:millisecond) + timeout_ms,
      signal: Keyword.get(opts, :signal)
    }

    with {:ok, pid} <- ensure_server(key, action, opts) do
      try do
        GenServer.call(pid, {:op, request, ctx}, timeout_ms + @call_slack_ms)
      catch
        :exit, {:timeout, _} -> {:error, "debug session did not respond in time"}
        :exit, _ -> {:error, "debug session stopped while handling the request"}
      end
    end
  end

  defp ensure_server(key, action, opts) do
    case whereis(key) do
      pid when is_pid(pid) ->
        case CodingAgent.ToolResources.bind(pid, Keyword.get(opts, :owner)) do
          :ok -> {:ok, pid}
          {:error, _} -> {:error, "debug session belongs to another active turn"}
        end

      nil when action in @start_actions ->
        spec =
          {__MODULE__,
           key: key,
           owner: Keyword.get(opts, :owner),
           session_key: Keyword.get(opts, :session_key),
           idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, "cannot start debug session: #{inspect(reason)}"}
        end

      nil ->
        {:none, "No active debug session. Launch or attach first."}
    end
  end

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner_ref =
      case Keyword.get(opts, :owner) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    state =
      %{
        key: Keyword.fetch!(opts, :key),
        owner_ref: owner_ref,
        owner_pid: Keyword.get(opts, :owner),
        idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms),
        idle_token: nil,
        breakpoints: Keyword.get(opts, :breakpoints, %{}),
        function_breakpoints: Keyword.get(opts, :function_breakpoints, []),
        session: nil,
        children: %{},
        id_prefix: Keyword.get(opts, :id_prefix, "debug"),
        next_id: 1
      }
      |> schedule_idle()

    {:ok, state}
  end

  @impl true
  def handle_call({operation, owner}, _from, state)
      when operation in [:bind_owner, :detach_owner],
      do: CodingAgent.ToolResources.owner_reply(operation, owner, state)

  def handle_call({:op, %{debug_session_id: id} = request, ctx}, _from, state)
      when is_binary(id) do
    cond do
      state.session && state.session.id == id ->
        handle_call({:op, Map.delete(request, :debug_session_id), ctx}, nil, state)

      true ->
        child =
          Enum.find(state.children, fn {child_id, _} ->
            id == child_id or String.starts_with?(id, child_id <> "-")
          end)

        reply =
          case child do
            {_, pid} ->
              try do
                GenServer.call(pid, {:op, request, ctx}, ctx.timeout_ms + @call_slack_ms)
              catch
                :exit, _ -> {:error, "Child debug session is no longer running"}
              end

            nil ->
              {:error, "Unknown debug session: #{id}"}
          end

        {:reply, reply, schedule_idle(state)}
    end
  end

  def handle_call({:op, request, ctx}, _from, state) do
    {reply, state} =
      try do
        run(request, ctx, state)
      catch
        {:owner_down, state} -> {:owner_down, state}
      end

    case reply do
      :owner_down ->
        {:stop, :normal, {:error, "coding session ended"}, state}

      reply ->
        state = state |> dispose_if_terminated() |> schedule_idle()
        {:reply, reply, state}
    end
  end

  @impl true
  def handle_info({:start_child, request}, state) do
    ctx = %{
      timeout_ms: 30_000,
      deadline: System.monotonic_time(:millisecond) + 30_000,
      signal: nil
    }

    {reply, state} = run(request, ctx, state)

    state =
      case reply do
        {:error, message} ->
          session =
            new_session(
              %{state | next_id: 1},
              String.to_existing_atom(request.action),
              request.adapter,
              nil,
              request
            )

          %{state | session: %{session | status: :terminated, error: message}}

        _ ->
          state
      end

    {:noreply, dispose_if_terminated(state)}
  end

  def handle_info({:dap, client, payload}, %{session: %{client: client}} = state)
      when is_pid(client) do
    state = state |> apply_payload(payload) |> dispose_if_terminated()
    {:noreply, state}
  end

  def handle_info({:dap, _stale_client, _payload}, state), do: {:noreply, state}

  def handle_info({:EXIT, client, reason}, %{session: %{client: client}} = state)
      when is_pid(client) do
    state = apply_payload(state, {:exit, "debug adapter client stopped: #{inspect(reason)}"})
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:idle, token}, %{idle_token: token} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_children(state)

    case state.session do
      %{client: client} when is_pid(client) -> Client.stop(client)
      _ -> :ok
    end
  end

  # ── Operations ───────────────────────────────────────────────────────────

  defp run(%{action: "launch"} = request, ctx, state),
    do: start_session(:launch, request, ctx, state)

  defp run(%{action: "attach"} = request, ctx, state),
    do: start_session(:attach, request, ctx, state)

  defp run(%{action: "set_breakpoint", file: file} = request, ctx, state) do
    sync_source_breakpoints(file, with_source_breakpoint(state, request), ctx, state)
  end

  defp run(%{action: "remove_breakpoint", file: file, line: line}, ctx, state) do
    entries = state.breakpoints |> Map.get(file, []) |> Enum.reject(&(&1.line == line))
    sync_source_breakpoints(file, entries, ctx, state)
  end

  defp run(%{action: "set_function_breakpoint"} = request, ctx, state) do
    sync_function_breakpoints(with_function_breakpoint(state, request), ctx, state)
  end

  defp run(%{action: "remove_function_breakpoint", function: name}, ctx, state) do
    entries = Enum.reject(state.function_breakpoints, &(&1.name == name))
    sync_function_breakpoints(entries, ctx, state)
  end

  defp run(%{action: action}, _ctx, state) when action in ["status", "sessions"] do
    {{:ok, %{snapshot: snapshot(state)}}, state}
  end

  defp run(%{action: "output"}, _ctx, %{session: nil} = state) do
    {{:error, "No debug session. Launch or attach first."}, state}
  end

  defp run(%{action: "output"}, _ctx, state) do
    output = state.session.output
    text = output.queue |> :queue.to_list() |> IO.iodata_to_binary()
    {{:ok, %{snapshot: snapshot(state), output: text}}, state}
  end

  defp run(%{action: "terminate"}, ctx, state) do
    case state.session do
      nil ->
        {{:ok, %{snapshot: nil}}, state}

      _session ->
        state = terminate_session(state, ctx)
        {{:ok, %{snapshot: snapshot(state)}}, state}
    end
  end

  defp run(request, ctx, state) do
    case live_session(state) do
      {:ok, _session} -> run_live(request, ctx, state)
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp run_live(%{action: action} = req, ctx, state)
       when action in ["continue", "step_over", "step_in", "step_out"] do
    command =
      case action do
        "continue" -> "continue"
        "step_over" -> "next"
        "step_in" -> "stepIn"
        "step_out" -> "stepOut"
      end

    with_thread(state, req[:thread_id], ctx, fn thread_id, state ->
      previous = state.session
      state = update_session(state, &%{&1 | status: :running, stop: %{}, frames: []})

      case dap_request(state, command, %{"threadId" => thread_id}, ctx) do
        {:ok, _body, state} ->
          await_outcome(state, ctx)

        {status, message, state} when status in [:error, :aborted] ->
          state = restore_after_failed_resume(state, previous)
          {{status, message}, state}
      end
    end)
  end

  defp run_live(%{action: "pause"} = req, ctx, state) do
    if state.session.status == :stopped do
      {{:ok, %{snapshot: snapshot(state), state: :stopped, timed_out: false}}, state}
    else
      with_thread(state, req[:thread_id], ctx, fn thread_id, state ->
        case dap_request(state, "pause", %{"threadId" => thread_id}, ctx) do
          {:ok, _body, state} -> await_outcome(state, ctx)
          {status, message, state} -> {{status, message}, state}
        end
      end)
    end
  end

  defp run_live(%{action: "threads"}, ctx, state) do
    case dap_request(state, "threads", nil, ctx) do
      {:ok, body, state} ->
        threads = list(body, "threads")
        state = update_session(state, &%{&1 | threads: threads})
        {{:ok, %{snapshot: snapshot(state), threads: threads}}, state}

      {status, message, state} ->
        {{status, message}, state}
    end
  end

  defp run_live(%{action: "stack_trace"} = req, ctx, state) do
    with_thread(state, req[:thread_id], ctx, fn thread_id, state ->
      args = %{"threadId" => thread_id, "levels" => req[:levels] || 20}

      case dap_request(state, "stackTrace", args, ctx) do
        {:ok, body, state} ->
          frames = list(body, "stackFrames")

          state =
            update_session(state, &apply_top_frame(%{&1 | frames: frames}, List.first(frames)))

          {{:ok,
            %{snapshot: snapshot(state), stack_frames: frames, total_frames: body["totalFrames"]}},
           state}

        {status, message, state} ->
          {{status, message}, state}
      end
    end)
  end

  defp run_live(%{action: "scopes"} = req, ctx, state) do
    case resolve_frame(req[:frame_id], ctx, state) do
      {:ok, frame_id, state} ->
        case dap_request(state, "scopes", %{"frameId" => frame_id}, ctx) do
          {:ok, body, state} ->
            {{:ok,
              %{snapshot: snapshot(state), scopes: list(body, "scopes"), frame_id: frame_id}},
             state}

          {status, message, state} ->
            {{status, message}, state}
        end

      {status, message, state} ->
        {{status, message}, state}
    end
  end

  defp run_live(%{action: "variables", variable_ref: ref}, ctx, state) do
    case dap_request(state, "variables", %{"variablesReference" => ref}, ctx) do
      {:ok, body, state} ->
        {{:ok, %{snapshot: snapshot(state), variables: list(body, "variables")}}, state}

      {status, message, state} ->
        {{status, message}, state}
    end
  end

  defp run_live(%{action: "evaluate", expression: expression} = req, ctx, state) do
    frame_id = req[:frame_id] || state.session.stop[:frame_id]

    args =
      %{"expression" => expression, "context" => req[:context] || "repl"}
      |> put_present("frameId", frame_id)

    case dap_request(state, "evaluate", args, ctx) do
      {:ok, body, state} ->
        {{:ok, %{snapshot: snapshot(state), evaluation: body || %{}}}, state}

      {status, message, state} ->
        {{status, message}, state}
    end
  end

  defp run_live(%{action: action, arguments: args}, ctx, state)
       when action in [
              "data_breakpoint_info",
              "set_data_breakpoints",
              "set_instruction_breakpoints",
              "read_memory",
              "disassemble"
            ] do
    {command, capability} =
      case action do
        "data_breakpoint_info" ->
          {"dataBreakpointInfo", "supportsDataBreakpoints"}

        "set_data_breakpoints" ->
          {"setDataBreakpoints", "supportsDataBreakpoints"}

        "set_instruction_breakpoints" ->
          {"setInstructionBreakpoints", "supportsInstructionBreakpoints"}

        "read_memory" ->
          {"readMemory", "supportsReadMemoryRequest"}

        "disassemble" ->
          {"disassemble", "supportsDisassembleRequest"}
      end

    if state.session.capabilities[capability] == true do
      case bounded_arguments(action, args) do
        {:ok, args} ->
          case dap_request(state, command, args, ctx) do
            {:ok, body, state} ->
              if byte_size(Jason.encode!(body)) <= @max_output_bytes,
                do: {{:ok, %{snapshot: snapshot(state), body: body}}, state},
                else: {{:error, "#{command} response exceeds the 128 KB limit"}, state}

            {status, message, state} ->
              {{status, message}, state}
          end

        {:error, message} ->
          {{:error, message}, state}
      end
    else
      {{:error, "Adapter does not advertise #{capability}; #{action} is unsupported"}, state}
    end
  end

  defp run_live(%{action: "custom_request", command: command} = req, ctx, state) do
    case dap_request(state, command, req[:arguments], ctx) do
      {:ok, body, state} -> {{:ok, %{snapshot: snapshot(state), body: body}}, state}
      {status, message, state} -> {{status, message}, state}
    end
  end

  defp run_live(%{action: action}, _ctx, state) do
    {{:error, "Unsupported debug action: #{action}"}, state}
  end

  defp bounded_arguments(action, args) when action in ["read_memory", "disassemble"] do
    key = if action == "read_memory", do: "count", else: "instructionCount"

    if is_integer(args[key]) and args[key] > 0 do
      {:ok, Map.put(args, key, min(args[key], @max_output_bytes))}
    else
      {:error, "#{action} requires a positive integer #{key} in arguments"}
    end
  end

  defp bounded_arguments(_action, args), do: {:ok, args}

  # ── Launch / attach ──────────────────────────────────────────────────────

  defp start_session(kind, request, ctx, state) do
    case state.session do
      %{client: client, status: status, id: id} when is_pid(client) and status != :terminated ->
        {{:error, "Debug session #{id} is still active. Terminate it before starting another."},
         state}

      _ ->
        state = add_launch_breakpoints(%{state | session: nil}, request)

        adapter =
          if request.adapter.name == "rdbg" and kind == :launch do
            %{
              request.adapter
              | args: request.adapter.args ++ ["ruby", request.program] ++ request.args
            }
          else
            request.adapter
          end

        case Client.start_link(adapter: adapter, cwd: request.cwd, owner: self()) do
          {:ok, client} ->
            session = new_session(state, kind, adapter, client, request)
            state = %{state | session: session, next_id: state.next_id + 1}
            handshake(kind, request, ctx, state)

          {:error, reason} ->
            {{:error, start_error(adapter, reason)}, state}
        end
    end
  end

  defp add_launch_breakpoints(state, request) do
    state =
      case request[:breakpoint] do
        %{file: file} = bp ->
          entries = with_source_breakpoint(state, bp)
          pending = Enum.map(entries, &%{&1 | verified: false, id: nil, message: nil})
          %{state | breakpoints: Map.put(state.breakpoints, file, pending)}

        nil ->
          state
      end

    case request[:function_breakpoint] do
      %{function: _} = bp -> %{state | function_breakpoints: with_function_breakpoint(state, bp)}
      nil -> state
    end
  end

  defp with_source_breakpoint(state, %{file: file, line: line} = request) do
    entry = %{
      line: line,
      condition: request[:condition],
      hit_condition: request[:hit_condition],
      log_message: request[:log_message],
      verified: false,
      message: nil,
      id: nil
    }

    state.breakpoints
    |> Map.get(file, [])
    |> Enum.reject(&(&1.line == line))
    |> Kernel.++([entry])
    |> Enum.sort_by(& &1.line)
  end

  defp with_function_breakpoint(state, %{function: name} = request) do
    entry = %{
      name: name,
      condition: request[:condition],
      hit_condition: request[:hit_condition],
      verified: false,
      message: nil,
      id: nil
    }

    state.function_breakpoints
    |> Enum.reject(&(&1.name == name))
    |> Kernel.++([entry])
    |> Enum.sort_by(& &1.name)
  end

  defp handshake(kind, request, ctx, state) do
    with {:ok, capabilities, state} <-
           dap_request(state, "initialize", initialize_args(request.adapter), ctx),
         state = update_session(state, &%{&1 | capabilities: capabilities || %{}}),
         {:ok, start_seq, state} <-
           send_async(state, Atom.to_string(kind), start_args(kind, request, state)),
         {:ok, state} <- await_initialized(state, start_seq, ctx),
         {:ok, state} <- configure(state, ctx),
         {:ok, _body, state} <- await_response(state, start_seq, ctx) do
      case await_outcome(state, ctx) do
        {{:ok, data}, state} ->
          {{:ok, Map.put(data, :adapter, request.adapter.name)}, state}

        # A cancelled launch leaves nobody holding the session: kill it.
        {{:aborted, _message}, state} ->
          {{:aborted, "Debug #{kind} cancelled; the debug session was terminated."},
           discard_session(state)}
      end
    else
      {status, message, state} ->
        state = discard_session(state)
        {{status, start_error(request.adapter, message)}, state}
    end
  end

  defp initialize_args(adapter) do
    %{
      "clientID" => "lemon",
      "clientName" => "Lemon",
      "adapterID" => adapter.name,
      "locale" => "en-US",
      "linesStartAt1" => true,
      "columnsStartAt1" => true,
      "pathFormat" => "path",
      "supportsRunInTerminalRequest" => false,
      "supportsStartDebuggingRequest" => true,
      "supportsVariableType" => true,
      "supportsVariablePaging" => false,
      "supportsMemoryReferences" => false,
      "supportsProgressReporting" => false,
      "supportsInvalidatedEvent" => false
    }
  end

  defp start_args(_kind, %{reverse_configuration: configuration}, _state), do: configuration

  defp start_args(:launch, request, state) do
    entry_overrides =
      if has_breakpoints?(state),
        do: Map.new(Adapters.entry_stop_keys(), &{&1, false}),
        else: %{}

    request.adapter.launch_defaults
    |> Map.merge(request[:launch_overrides] || %{})
    |> Map.merge(entry_overrides)
    |> Map.merge(%{"program" => request.program, "cwd" => request.cwd})
    |> put_present("args", request[:args])
  end

  defp start_args(:attach, %{adapter: %{connect_mode: :remote}} = request, _state) do
    Map.put(request.adapter.attach_defaults, "connect", %{
      "host" => request.adapter.host,
      "port" => request.adapter.port
    })
  end

  defp start_args(:attach, request, _state) do
    request.adapter.attach_defaults
    |> Map.put("cwd", request.cwd)
    |> put_present("pid", request[:pid])
    |> put_present("processId", request[:pid])
    |> put_present("port", request[:port])
    |> put_present("host", request[:host])
  end

  defp has_breakpoints?(state) do
    map_size(state.breakpoints) > 0 or state.function_breakpoints != []
  end

  # Adapters may answer launch/attach only after configurationDone, so the
  # start request is in flight while we wait for `initialized`.
  defp await_initialized(state, start_seq, ctx) do
    result =
      await(state, ctx, fn state ->
        session = state.session

        cond do
          session.initialized? -> {:done, :ok}
          match?(%{"success" => false}, session.responses[start_seq]) -> {:done, :start_failed}
          is_nil(session.client) -> {:done, :exited}
          true -> nil
        end
      end)

    case result do
      {:ok, :ok, state} -> {:ok, state}
      {:ok, :start_failed, state} -> response_error(state, start_seq)
      {:ok, :exited, state} -> {:error, adapter_exit_message(state), state}
      {:timeout, state} -> {:error, "debug adapter did not send `initialized` in time", state}
      {:aborted, state} -> {:aborted, "Debug launch cancelled.", state}
    end
  end

  defp configure(state, ctx) do
    with {:ok, state} <- send_all_source_breakpoints(state, ctx),
         {:ok, state} <- send_function_breakpoints_if_any(state, ctx) do
      if state.session.capabilities["supportsConfigurationDoneRequest"] == true do
        case dap_request(state, "configurationDone", %{}, ctx) do
          {:ok, _body, state} -> {:ok, update_session(state, &mark_configured/1)}
          other -> other
        end
      else
        {:ok, update_session(state, &mark_configured/1)}
      end
    end
  end

  defp mark_configured(session) do
    status =
      if session.status in [:initializing, :configuring], do: :running, else: session.status

    %{session | configuration_done?: true, status: status}
  end

  defp send_all_source_breakpoints(state, ctx) do
    Enum.reduce_while(state.breakpoints, {:ok, state}, fn {file, entries}, {:ok, state} ->
      case source_breakpoints_request(state, file, entries, ctx) do
        {:ok, body, state} ->
          mapped = map_breakpoints(entries, list(body, "breakpoints"), state.session)
          {:cont, {:ok, %{state | breakpoints: Map.put(state.breakpoints, file, mapped)}}}

        {:error, message, state} ->
          mapped = Enum.map(entries, &%{&1 | verified: false, message: message})
          {:cont, {:ok, %{state | breakpoints: Map.put(state.breakpoints, file, mapped)}}}

        aborted ->
          {:halt, aborted}
      end
    end)
  end

  defp send_function_breakpoints_if_any(%{function_breakpoints: []} = state, _ctx),
    do: {:ok, state}

  defp send_function_breakpoints_if_any(state, ctx) do
    entries = state.function_breakpoints

    case dap_request(state, "setFunctionBreakpoints", function_breakpoint_args(entries), ctx) do
      {:ok, body, state} ->
        {:ok,
         %{
           state
           | function_breakpoints:
               map_breakpoints(entries, list(body, "breakpoints"), state.session)
         }}

      {:error, message, state} ->
        {:ok,
         %{
           state
           | function_breakpoints: Enum.map(entries, &%{&1 | verified: false, message: message})
         }}

      aborted ->
        aborted
    end
  end

  defp start_error(%{name: "debugpy"}, message) when is_binary(message) do
    if message =~ ~r/No module named ['"]?debugpy/,
      do: "debug adapter 'debugpy' is not available: install with `pip install debugpy`",
      else: message
  end

  defp start_error(_adapter, message) when is_binary(message), do: message
  defp start_error(_adapter, {:shutdown, message}) when is_binary(message), do: message
  defp start_error(_adapter, reason), do: "cannot start debug adapter: #{inspect(reason)}"

  # ── Breakpoint sync ──────────────────────────────────────────────────────

  defp sync_source_breakpoints(file, entries, ctx, state) do
    store = fn state, entries ->
      breakpoints =
        if entries == [],
          do: Map.delete(state.breakpoints, file),
          else: Map.put(state.breakpoints, file, entries)

      %{state | breakpoints: breakpoints}
    end

    case live_session(state) do
      {:ok, _session} ->
        case source_breakpoints_request(state, file, entries, ctx) do
          {:ok, body, state} ->
            mapped = map_breakpoints(entries, list(body, "breakpoints"), state.session)
            state = store.(state, mapped)

            {{:ok, %{snapshot: snapshot(state), file: file, breakpoints: mapped, pending: false}},
             state}

          {status, message, state} ->
            {{status, message}, state}
        end

      {:error, _} ->
        pending = Enum.map(entries, &%{&1 | verified: false, id: nil, message: nil})
        state = store.(state, pending)

        {{:ok, %{snapshot: snapshot(state), file: file, breakpoints: pending, pending: true}},
         state}
    end
  end

  defp sync_function_breakpoints(entries, ctx, state) do
    case live_session(state) do
      {:ok, _session} ->
        case dap_request(state, "setFunctionBreakpoints", function_breakpoint_args(entries), ctx) do
          {:ok, body, state} ->
            mapped = map_breakpoints(entries, list(body, "breakpoints"), state.session)
            state = %{state | function_breakpoints: mapped}

            {{:ok, %{snapshot: snapshot(state), function_breakpoints: mapped, pending: false}},
             state}

          {status, message, state} ->
            {{status, message}, state}
        end

      {:error, _} ->
        pending = Enum.map(entries, &%{&1 | verified: false, id: nil, message: nil})
        state = %{state | function_breakpoints: pending}
        {{:ok, %{snapshot: snapshot(state), function_breakpoints: pending, pending: true}}, state}
    end
  end

  defp source_breakpoints_request(state, file, entries, ctx) do
    if Enum.any?(entries, & &1[:log_message]) and
         state.session.capabilities["supportsLogPoints"] != true do
      {:error, "Adapter does not advertise supportsLogPoints; log_message is unsupported", state}
    else
      dap_request(state, "setBreakpoints", source_breakpoint_args(file, entries), ctx)
    end
  end

  defp source_breakpoint_args(file, entries) do
    %{
      "source" => %{"path" => file, "name" => Path.basename(file)},
      "breakpoints" =>
        Enum.map(entries, fn entry ->
          %{"line" => entry.line}
          |> put_present("condition", entry.condition)
          |> put_present("hitCondition", entry.hit_condition)
          |> put_present("logMessage", entry[:log_message])
        end)
    }
  end

  defp function_breakpoint_args(entries) do
    %{
      "breakpoints" =>
        Enum.map(entries, fn entry ->
          %{"name" => entry.name}
          |> put_present("condition", entry.condition)
          |> put_present("hitCondition", entry.hit_condition)
        end)
    }
  end

  # Adapters may report a breakpoint's resolution through a `breakpoint`
  # event before answering the set request, so known event state for the
  # returned id is merged in.
  defp map_breakpoints(entries, response, session) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      reply = Enum.at(response, index) || %{}
      event = Map.get(session.breakpoint_events, reply["id"], %{})

      %{
        entry
        | verified: reply["verified"] == true or event["verified"] == true,
          message: reply["message"] || event["message"],
          id: reply["id"]
      }
    end)
  end

  # ── Execution helpers ────────────────────────────────────────────────────

  defp with_thread(state, thread_id, _ctx, fun) when is_integer(thread_id),
    do: fun.(thread_id, state)

  defp with_thread(state, nil, ctx, fun) do
    case resolve_thread(state, ctx) do
      {:ok, thread_id, state} -> fun.(thread_id, state)
      {status, message, state} -> {{status, message}, state}
    end
  end

  defp resolve_thread(state, ctx) do
    session = state.session

    cond do
      is_integer(session.stop[:thread_id]) ->
        {:ok, session.stop.thread_id, state}

      match?([%{"id" => _} | _], session.threads) ->
        {:ok, hd(session.threads)["id"], state}

      true ->
        case dap_request(state, "threads", nil, ctx) do
          {:ok, body, state} ->
            threads = list(body, "threads")
            state = update_session(state, &%{&1 | threads: threads})

            case threads do
              [%{"id" => id} | _] -> {:ok, id, state}
              _ -> {:error, "Debugger reported no threads.", state}
            end

          other ->
            other
        end
    end
  end

  defp resolve_frame(frame_id, _ctx, state) when is_integer(frame_id), do: {:ok, frame_id, state}

  defp resolve_frame(nil, ctx, state) do
    case state.session.stop[:frame_id] do
      id when is_integer(id) ->
        {:ok, id, state}

      nil when state.session.status == :stopped ->
        state = fetch_top_frame(state, ctx)

        case state.session.stop[:frame_id] do
          id when is_integer(id) -> {:ok, id, state}
          _ -> {:error, "No active stack frame. Run stack_trace first or supply frame_id.", state}
        end

      nil ->
        {:error, "Program is not stopped. Pause it or wait for a breakpoint first.", state}
    end
  end

  defp restore_after_failed_resume(state, previous) do
    if is_nil(state.session.client) or state.session.status == :terminated do
      state
    else
      update_session(
        state,
        &%{&1 | status: previous.status, stop: previous.stop, frames: previous.frames}
      )
    end
  end

  # Wait for the session to stop or terminate, then capture the top frame.
  defp await_outcome(state, ctx) do
    result =
      await(state, ctx, fn state ->
        case state.session do
          %{status: status} when status in [:stopped, :terminated] -> {:done, status}
          %{client: nil} -> {:done, :terminated}
          _ -> nil
        end
      end)

    case result do
      {:ok, :stopped, state} ->
        state = fetch_top_frame(state, ctx)
        {{:ok, %{snapshot: snapshot(state), state: :stopped, timed_out: false}}, state}

      {:ok, :terminated, state} ->
        {{:ok, %{snapshot: snapshot(state), state: :terminated, timed_out: false}}, state}

      {:timeout, state} ->
        {{:ok, %{snapshot: snapshot(state), state: :running, timed_out: true}}, state}

      {:aborted, state} ->
        {{:aborted, "Debug operation cancelled; the program may still be running."}, state}
    end
  end

  defp fetch_top_frame(state, ctx) do
    case state.session.stop[:thread_id] do
      thread_id when is_integer(thread_id) ->
        # The top frame is a best-effort enrichment bounded separately.
        ctx = %{ctx | deadline: max(ctx.deadline, System.monotonic_time(:millisecond) + 5_000)}

        case dap_request(state, "stackTrace", %{"threadId" => thread_id, "levels" => 1}, ctx) do
          {:ok, body, state} ->
            frames = list(body, "stackFrames")
            update_session(state, &apply_top_frame(%{&1 | frames: frames}, List.first(frames)))

          {_status, _message, state} ->
            state
        end

      _ ->
        state
    end
  end

  defp apply_top_frame(session, nil), do: session

  defp apply_top_frame(session, frame) do
    source = frame["source"] || %{}

    stop =
      Map.merge(session.stop, %{
        frame_id: frame["id"],
        frame_name: frame["name"],
        source_path: source["path"],
        source_name: source["name"],
        line: frame["line"],
        column: frame["column"]
      })

    %{session | stop: stop}
  end

  # ── Termination ──────────────────────────────────────────────────────────

  defp terminate_session(state, ctx) do
    case state.session do
      %{client: client} = session when is_pid(client) ->
        ctx = %{ctx | deadline: min(ctx.deadline, System.monotonic_time(:millisecond) + 5_000)}

        state =
          if session.kind == :launch and session.capabilities["supportsTerminateRequest"] == true and
               session.status != :terminated do
            case dap_request(state, "terminate", nil, ctx) do
              {_, _, state} -> state
            end
          else
            state
          end

        state =
          if state.session.client do
            case dap_request(
                   state,
                   "disconnect",
                   %{"terminateDebuggee" => session.kind == :launch},
                   ctx
                 ) do
              {_, _, state} -> state
            end
          else
            state
          end

        stop_client(state)

      _ ->
        state
    end
  end

  defp dispose_if_terminated(%{session: %{status: :terminated, client: client}} = state)
       when is_pid(client) do
    state = stop_children(state)

    ctx = %{
      timeout_ms: @dispose_timeout_ms,
      deadline: System.monotonic_time(:millisecond) + @dispose_timeout_ms,
      signal: nil
    }

    state =
      try do
        case dap_request(
               state,
               "disconnect",
               %{"terminateDebuggee" => state.session.kind == :launch},
               ctx
             ) do
          {_, _, state} -> state
        end
      catch
        {:owner_down, state} -> state
      end

    stop_client(state)
  end

  defp dispose_if_terminated(%{session: %{status: :terminated}} = state),
    do: stop_children(state)

  defp dispose_if_terminated(state), do: state

  defp stop_client(state) do
    case state.session do
      %{client: client} when is_pid(client) ->
        Client.stop(client)
        flush_client(client)
        update_session(state, &%{&1 | client: nil, status: :terminated})

      _ ->
        state
    end
  end

  defp discard_session(state) do
    state = stop_children(state)
    state = stop_client(state)
    %{state | session: nil}
  end

  defp flush_client(client) do
    receive do
      {:dap, ^client, _} -> flush_client(client)
      {:EXIT, ^client, _} -> flush_client(client)
    after
      0 -> :ok
    end
  end

  # ── Request / event plumbing ─────────────────────────────────────────────

  defp dap_request(state, command, arguments, ctx) do
    case send_async(state, command, arguments) do
      {:ok, seq, state} -> await_response(state, seq, ctx)
      error -> error
    end
  end

  defp send_async(state, command, arguments) do
    case state.session do
      %{client: client} when is_pid(client) ->
        case Client.request(client, command, arguments) do
          {:ok, seq} ->
            {:ok, seq,
             update_session(state, &%{&1 | awaiting: Map.put(&1.awaiting, seq, command)})}

          {:error, message} ->
            {:error, message, state}
        end

      _ ->
        {:error, adapter_exit_message(state), state}
    end
  end

  defp await_response(state, seq, ctx) do
    result =
      await(state, ctx, fn state ->
        session = state.session

        cond do
          Map.has_key?(session.responses, seq) -> {:done, :response}
          is_nil(session.client) -> {:done, :exited}
          true -> nil
        end
      end)

    case result do
      {:ok, :response, state} ->
        response = state.session.responses[seq]
        state = forget_request(state, seq)

        if response["success"] == true do
          {:ok, response["body"], state}
        else
          {:error, response_message(response), state}
        end

      {:ok, :exited, state} ->
        {:error, adapter_exit_message(state), forget_request(state, seq)}

      {:timeout, state} ->
        command = Map.get(state.session.awaiting, seq, "request")

        {:error, "DAP request #{command} timed out after #{format_seconds(ctx.timeout_ms)}",
         forget_request(state, seq)}

      {:aborted, state} ->
        {:aborted, "Debug operation cancelled.", forget_request(state, seq)}
    end
  end

  defp response_error(state, seq) do
    response = state.session.responses[seq]
    {:error, response_message(response), forget_request(state, seq)}
  end

  defp response_message(response) do
    format = get_in(response, ["body", "error", "format"])
    message = response["message"]

    cond do
      is_binary(format) and format != "" -> format
      is_binary(message) and message != "" -> message
      true -> "DAP request #{response["command"]} failed"
    end
  end

  defp format_seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp format_seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp forget_request(state, seq) do
    update_session(state, fn session ->
      %{
        session
        | awaiting: Map.delete(session.awaiting, seq),
          responses: Map.delete(session.responses, seq)
      }
    end)
  end

  defp adapter_exit_message(state) do
    case state.session do
      %{error: error} when is_binary(error) -> error
      _ -> "debug adapter is not running"
    end
  end

  # Receive DAP traffic (applying it to state) until `done?` returns
  # `{:done, value}`, the operation deadline passes or the signal aborts.
  defp await(state, ctx, done?) do
    case done?.(state) do
      {:done, value} ->
        {:ok, value, state}

      nil ->
        now = System.monotonic_time(:millisecond)

        cond do
          AbortSignal.aborted?(ctx.signal) ->
            {:aborted, state}

          now >= ctx.deadline ->
            {:timeout, state}

          true ->
            client = state.session && state.session.client
            owner_ref = state.owner_ref

            receive do
              {:dap, ^client, payload} ->
                await(apply_payload(state, payload), ctx, done?)

              {:EXIT, ^client, reason} ->
                state =
                  apply_payload(
                    state,
                    {:exit, "debug adapter client stopped: #{inspect(reason)}"}
                  )

                await(state, ctx, done?)

              {:DOWN, ^owner_ref, :process, _pid, _reason} ->
                throw({:owner_down, state})
            after
              min(@poll_ms, ctx.deadline - now) -> await(state, ctx, done?)
            end
        end
    end
  end

  defp stop_children(state) do
    Enum.each(state.children, fn {_id, pid} ->
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :normal, @dispose_timeout_ms)
      catch
        :exit, _ -> Process.exit(pid, :kill)
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)

    %{state | children: %{}}
  end

  defp apply_payload(state, {:start_debugging, message}) do
    arguments = message["arguments"] || %{}
    configuration = arguments["configuration"]
    kind = arguments["request"]

    if kind in ["launch", "attach"] and is_map(configuration) do
      id = "#{state.session.id}-#{map_size(state.children) + 1}"
      key = {state.key, id}

      case DynamicSupervisor.start_child(
             @supervisor,
             {__MODULE__,
              key: key,
              owner: self(),
              id_prefix: id,
              breakpoints: state.breakpoints,
              function_breakpoints: state.function_breakpoints}
           ) do
        {:ok, pid} ->
          request = %{
            action: kind,
            adapter: Client.child_adapter(state.session.client),
            cwd: configuration["cwd"] || state.session.cwd,
            program: configuration["program"],
            args: configuration["args"] || [],
            reverse_configuration: configuration
          }

          # Acknowledge session creation before handshaking: adapters may wait
          # for this response before allowing the child's initialize/attach.
          Client.respond(state.session.client, message, :ok)
          send(pid, {:start_child, request})
          %{state | children: Map.put(state.children, id <> "-1", pid)}

        {:error, _reason} ->
          Client.respond(
            state.session.client,
            message,
            {:error, "Cannot create child debug session"}
          )

          state
      end
    else
      Client.respond(
        state.session.client,
        message,
        {:error, "startDebugging requires request launch/attach and a configuration object"}
      )

      state
    end
  end

  defp apply_payload(%{session: nil} = state, _payload), do: state

  defp apply_payload(state, {:response, seq, response}) do
    update_session(state, fn session ->
      if Map.has_key?(session.awaiting, seq),
        do: %{session | responses: Map.put(session.responses, seq, response)},
        else: session
    end)
  end

  defp apply_payload(state, {:event, event, body}) do
    update_session(state, &apply_event(&1, event, body || %{}))
  end

  defp apply_payload(state, {:reverse_request, command}) do
    update_session(state, fn session ->
      %{
        session
        | output: append_output(session.output, "[lemon] rejected adapter request: #{command}\n")
      }
    end)
  end

  defp apply_payload(state, {:exit, reason}) do
    state = stop_children(state)

    update_session(state, fn session ->
      # The adapter may have died before disconnecting its launched program.
      # Its children can already be reparented, so the adapter pid alone no
      # longer identifies them. Never claim ownership of an attached process.
      if session.status != :terminated and session.kind == :launch do
        case session.process do
          %{pid: pid} when is_integer(pid) and pid > 0 -> BashExecutor.kill_process_tree(pid)
          _ -> :ok
        end
      end

      error = if session.status == :terminated, do: session.error, else: reason
      %{session | client: nil, status: :terminated, error: error}
    end)
  end

  defp apply_event(session, "output", body) do
    case body do
      %{"category" => "telemetry"} ->
        session

      %{"output" => text} when is_binary(text) ->
        %{session | output: append_output(session.output, text)}

      _ ->
        session
    end
  end

  defp apply_event(session, "initialized", _body) do
    status = if session.status == :initializing, do: :configuring, else: session.status
    %{session | initialized?: true, status: status}
  end

  defp apply_event(session, "stopped", body) do
    stop = %{
      thread_id: body["threadId"],
      reason: body["reason"],
      description: body["description"],
      text: body["text"],
      hit_breakpoint_ids: body["hitBreakpointIds"]
    }

    hit_events =
      Map.new(List.wrap(body["hitBreakpointIds"]), fn id ->
        {id, %{"id" => id, "verified" => true}}
      end)

    %{
      session
      | status: :stopped,
        stop: stop,
        frames: [],
        breakpoint_events: Map.merge(session.breakpoint_events, hit_events),
        breakpoints_dirty?: session.breakpoints_dirty? or map_size(hit_events) > 0
    }
  end

  defp apply_event(session, "continued", body) do
    %{session | status: :running, stop: %{thread_id: body["threadId"]}, frames: []}
  end

  defp apply_event(session, "exited", body) do
    %{session | exit_code: body["exitCode"], status: :terminated}
  end

  defp apply_event(session, "terminated", _body), do: %{session | status: :terminated}

  defp apply_event(session, "process", body) do
    %{session | process: %{name: body["name"], pid: body["systemProcessId"]}}
  end

  defp apply_event(session, "breakpoint", %{"breakpoint" => %{"id" => id} = bp}) do
    %{
      session
      | breakpoint_events: Map.put(session.breakpoint_events, id, bp),
        breakpoints_dirty?: true
    }
  end

  defp apply_event(session, _event, _body), do: session

  defp update_session(%{session: nil} = state, _fun), do: state

  defp update_session(state, fun) do
    session = fun.(state.session)
    state = %{state | session: session}

    if session.breakpoints_dirty? do
      apply_breakpoint_events(state)
    else
      state
    end
  end

  # `breakpoint` events (e.g. lldb-dap resolving a location after a module
  # loads) update verification of breakpoints the adapter already knows by id.
  defp apply_breakpoint_events(state) do
    events = state.session.breakpoint_events

    apply = fn entry ->
      case events[entry.id] do
        nil -> entry
        bp -> %{entry | verified: bp["verified"] == true, message: bp["message"] || entry.message}
      end
    end

    %{
      state
      | breakpoints:
          Map.new(state.breakpoints, fn {file, entries} -> {file, Enum.map(entries, apply)} end),
        function_breakpoints: Enum.map(state.function_breakpoints, apply),
        session: %{state.session | breakpoints_dirty?: false}
    }
  end

  # ── Session record ───────────────────────────────────────────────────────

  defp new_session(state, kind, adapter, client, request) do
    %{
      id: "#{state.id_prefix}-#{state.next_id}",
      kind: kind,
      adapter: adapter,
      client: client,
      cwd: request.cwd,
      program: request[:program],
      status: :initializing,
      capabilities: %{},
      initialized?: false,
      configuration_done?: false,
      stop: %{},
      frames: [],
      threads: [],
      exit_code: nil,
      error: nil,
      process: nil,
      awaiting: %{},
      responses: %{},
      breakpoint_events: %{},
      breakpoints_dirty?: false,
      output: %{queue: :queue.new(), bytes: 0, total: 0, truncated?: false},
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp live_session(state) do
    case state.session do
      %{client: client, status: status} = session when is_pid(client) and status != :terminated ->
        {:ok, session}

      %{id: id} ->
        {:error, "Debug session #{id} has terminated. Launch or attach again."}

      nil ->
        {:error, "No active debug session. Launch or attach first."}
    end
  end

  defp snapshot(state) do
    breakpoints =
      for {file, entries} <- Enum.sort(state.breakpoints), entry <- entries do
        Map.put(entry, :file, file)
      end

    children =
      Enum.map(state.children, fn {id, pid} ->
        try do
          ctx = %{
            timeout_ms: 100,
            deadline: System.monotonic_time(:millisecond) + 100,
            signal: nil
          }

          {:ok, %{snapshot: child}} = GenServer.call(pid, {:op, %{action: "status"}, ctx}, 100)
          Map.put(child, :parent_id, state.session && state.session.id)
        catch
          :exit, _ ->
            %{id: id, status: :initializing, parent_id: state.session && state.session.id}
        end
      end)

    base = %{
      breakpoints: breakpoints,
      function_breakpoints: state.function_breakpoints,
      children: children
    }

    case state.session do
      nil ->
        Map.put(base, :status, :none)

      session ->
        stop = session.stop

        Map.merge(base, %{
          id: session.id,
          kind: session.kind,
          adapter: session.adapter.name,
          status: session.status,
          cwd: session.cwd,
          program: session.program,
          process_id: session.process && session.process.pid,
          thread_id: stop[:thread_id],
          frame_id: stop[:frame_id],
          frame_name: stop[:frame_name],
          stop_reason: stop[:reason],
          stop_description: stop[:description] || stop[:text],
          source_path: stop[:source_path],
          line: stop[:line],
          column: stop[:column],
          exit_code: session.exit_code,
          error: session.error,
          output_bytes: session.output.total,
          output_truncated: session.output.truncated?,
          started_at: session.started_at
        })
    end
  end

  # ── Output ring buffer ───────────────────────────────────────────────────

  defp append_output(output, ""), do: output

  defp append_output(output, text) do
    size = byte_size(text)

    %{
      output
      | queue: :queue.in(text, output.queue),
        bytes: output.bytes + size,
        total: output.total + size
    }
    |> trim_output()
  end

  defp trim_output(%{bytes: bytes} = output) when bytes <= @max_output_bytes, do: output

  defp trim_output(output) do
    {{:value, front}, rest} = :queue.out(output.queue)
    front_size = byte_size(front)

    cond do
      not :queue.is_empty(rest) and output.bytes - front_size >= @max_output_bytes ->
        trim_output(%{output | queue: rest, bytes: output.bytes - front_size, truncated?: true})

      true ->
        excess = output.bytes - @max_output_bytes
        kept = front |> binary_part(excess, front_size - excess) |> drop_continuation_bytes()

        %{
          output
          | queue: :queue.in_r(kept, rest),
            bytes: output.bytes - front_size + byte_size(kept),
            truncated?: true
        }
    end
  end

  defp drop_continuation_bytes(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_continuation_bytes(rest)

  defp drop_continuation_bytes(binary), do: binary

  # ── Misc ─────────────────────────────────────────────────────────────────

  defp schedule_idle(state) do
    token = make_ref()
    Process.send_after(self(), {:idle, token}, state.idle_timeout_ms)
    %{state | idle_token: token}
  end

  defp list(body, key) when is_map(body) do
    case body[key] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp list(_body, _key), do: []

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
