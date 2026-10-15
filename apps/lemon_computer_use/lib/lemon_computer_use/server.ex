defmodule LemonComputerUse.Server do
  @moduledoc """
  Owns the Node bridge to LCU and serializes computer-use operations.

  One bridge process (`priv/lcu_bridge.mjs`) holds one connection to the
  original computer-use MCP server through LCU's shared harness client. The
  desktop is a single shared resource, so operations run one at a time in
  arrival order: connect, `js`/`js_reset` calls and turn-end cleanup. Because at
  most one call is in flight, every native-app approval request the runtime
  raises belongs to that call and is answered with that call's Lemon approval
  context (see `LemonComputerUse.Approval`).

  ## Turns

  LCU needs real host session and turn identities on every call and expects
  `turn_ended` when the host turn ends. A call carries the Lemon session id and
  the run id (the turn). The server subscribes to `run:<run_id>` and monitors
  the session process; `:run_completed` or the session exiting enqueues the
  original `Stop` cleanup for every turn of that run or session.

  ## Failure

  The bridge is started lazily (or at boot when enabled) and never relaunched
  in a loop: a bridge exit fails the in-flight and queued operations, and the
  next operation starts a fresh bridge. A call that was in flight when the
  bridge died may already have acted on the desktop; the error says so.
  """

  use GenServer

  require Logger

  alias LemonComputerUse.{Approval, Config}

  @catalog_key {__MODULE__, :catalog}
  @line_bytes 65_536
  @kill_grace_ms 3_000
  @abort_poll_ms 200

  @passthrough_env ~w(HOME USER LOGNAME PATH TMPDIR LANG LC_ALL LC_CTYPE SHELL DISPLAY
                      WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XAUTHORITY)

  defstruct port: nil,
            os_pid: nil,
            buffer: [],
            connected?: false,
            last_error: nil,
            next_id: 1,
            queue: :queue.new(),
            current: nil,
            waiters: [],
            elicitations: %{},
            turns: %{},
            run_topics: MapSet.new()

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The connected catalog (`instructions`, `tools`) without blocking, or `nil`."
  @spec cached_catalog() :: map() | nil
  def cached_catalog, do: :persistent_term.get(@catalog_key, nil)

  @doc """
  The original server's instructions and model tool descriptors, connecting
  first when needed. Waits at most `timeout` milliseconds.

  After a failed connection this answers the failure at once and retries in the
  background, so building a session's tools does not wait on a broken setup
  every time; a later caller sees the retry's outcome.
  """
  @spec catalog(GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def catalog(server \\ __MODULE__, timeout \\ Config.connect_timeout_ms()) do
    GenServer.call(server, :catalog, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :connect_timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Run one model tool call (`"js"` or `"js_reset"`).

  `context` must carry `:session_id` and `:turn_id`; `:run_id`, `:session_pid`,
  `:tool_call_id` and the approval fields are optional. `signal` is the
  `LemonAgent.AbortSignal` of the tool call; an abort cancels the call (and any
  pending approval) and returns `{:error, :aborted}`.
  """
  @spec call(String.t(), map(), map(), reference() | nil, GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def call(name, arguments, context, signal \\ nil, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil ->
        {:error, :unavailable}

      pid ->
        ref = make_ref()
        monitor = Process.monitor(pid)
        GenServer.cast(pid, {:call, self(), ref, name, arguments, context})
        await_call(pid, ref, monitor, signal, false)
    end
  end

  defp await_call(pid, ref, monitor, signal, cancelled?) do
    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, {:bridge_exited, :server_down}}
    after
      @abort_poll_ms ->
        if not cancelled? and LemonAgent.AbortSignal.aborted?(signal) do
          GenServer.cast(pid, {:cancel, ref})
          await_call(pid, ref, monitor, signal, true)
        else
          await_call(pid, ref, monitor, signal, cancelled?)
        end
    end
  end

  @doc "Bounded, redaction-safe status for diagnostics."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 5_000)
  catch
    :exit, _ -> %{running: false}
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %__MODULE__{}

    if Keyword.get(opts, :connect, false),
      do: {:ok, enqueue(state, :connect), {:continue, :run}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:run, state), do: {:noreply, run_next(state)}

  @impl true
  def handle_call(:catalog, _from, %{connected?: true} = state) do
    {:reply, {:ok, cached_catalog()}, state}
  end

  def handle_call(:catalog, _from, %{last_error: reason} = state)
      when not is_nil(reason) do
    if connect_pending?(state) do
      {:reply, {:error, reason}, state}
    else
      {:reply, {:error, reason}, state |> enqueue(:connect) |> run_next()}
    end
  end

  def handle_call(:catalog, from, state) do
    state = %{state | waiters: [from | state.waiters]}

    state =
      if connect_pending?(state), do: state, else: enqueue(state, :connect)

    {:noreply, run_next(state)}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running: true,
       bridge: if(state.port, do: :running, else: :stopped),
       connected: state.connected?,
       queued: :queue.len(state.queue),
       busy: not is_nil(state.current),
       active_turns: map_size(state.turns),
       last_error: error_tag(state.last_error)
     }, state}
  end

  @impl true
  def handle_cast({:call, caller, ref, name, arguments, context}, state) do
    monitor = Process.monitor(caller)

    op =
      {:call,
       %{caller: caller, ref: ref, monitor: monitor, name: name, args: arguments, ctx: context}}

    {:noreply, state |> enqueue(op) |> run_next()}
  end

  def handle_cast({:cancel, ref}, state), do: {:noreply, cancel_call(state, ref)}

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: [state.buffer, chunk]}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary([state.buffer, chunk])
    state = %{state | buffer: []}

    case Jason.decode(line) do
      {:ok, message} when is_map(message) ->
        {:noreply, handle_bridge_message(message, state)}

      _ ->
        Logger.debug("computer_use: ignored a non-protocol bridge line")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("computer_use: LCU bridge exited with status #{code}")
    {:noreply, state |> bridge_down({:bridge_exited, code}) |> run_next()}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:noreply, state |> bridge_down({:bridge_exited, safe_reason(reason)}) |> run_next()}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info({:elicitation_answer, id, response}, state) do
    case Map.pop(state.elicitations, id) do
      {nil, _} ->
        {:noreply, state}

      {%{monitor: monitor}, elicitations} ->
        Process.demonitor(monitor, [:flush])
        send_line(state, %{type: "elicitationResponse", id: id, response: response})
        {:noreply, %{state | elicitations: elicitations}}
    end
  end

  def handle_info(%LemonCore.Event{type: :run_completed, meta: meta}, state) do
    case meta do
      %{run_id: run_id} when is_binary(run_id) ->
        {:noreply, end_turns(state, &(&1.run_id == run_id))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      call_monitor?(state, monitor) ->
        {:noreply, cancel_call(state, call_ref_for_monitor(state, monitor))}

      elicitation = find_elicitation(state, monitor) ->
        {id, _} = elicitation
        send_line(state, %{type: "elicitationResponse", id: id, response: %{action: "cancel"}})
        {:noreply, %{state | elicitations: Map.delete(state.elicitations, id)}}

      true ->
        {:noreply, end_turns(state, &(&1.session_monitor == monitor))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_bridge(state)
    :persistent_term.erase(@catalog_key)
    :ok
  end

  # ── Queue ───────────────────────────────────────────────────────────────

  defp enqueue(state, op), do: %{state | queue: :queue.in(op, state.queue)}

  defp connect_pending?(state) do
    match?(%{op: :connect}, state.current) or :queue.member(:connect, state.queue)
  end

  defp run_next(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _} -> state
      {{:value, op}, queue} -> start_op(op, %{state | queue: queue})
    end
  end

  defp run_next(state), do: state

  defp start_op(:connect, %{connected?: true} = state) do
    state |> reply_waiters({:ok, cached_catalog()}) |> run_next()
  end

  defp start_op(:connect, state) do
    case ensure_bridge(state) do
      {:ok, state} ->
        dispatch(state, :connect, %{type: "connect", command: Config.command()})

      {:error, reason, state} ->
        state |> connect_failed(reason) |> run_next()
    end
  end

  defp start_op({:call, _call} = op, %{connected?: false} = state) do
    # Connect first, then run this call.
    start_op(:connect, %{state | queue: :queue.in_r(op, state.queue)})
  end

  defp start_op({:call, call}, state) do
    state = track_turn(state, call.ctx)

    dispatch(state, {:call, call}, %{
      type: "call",
      name: call.name,
      arguments: call.args,
      sessionId: call.ctx.session_id,
      turnId: call.ctx.turn_id,
      toolCallId: Map.get(call.ctx, :tool_call_id)
    })
  end

  defp start_op({:turn_ended, _session_id, _turn_id}, %{connected?: false} = state),
    do: run_next(state)

  defp start_op({:turn_ended, session_id, turn_id}, state) do
    dispatch(state, {:turn_ended, session_id, turn_id}, %{
      type: "turnEnded",
      sessionId: session_id,
      turnId: turn_id,
      event: "Stop"
    })
  end

  defp dispatch(state, op, payload) do
    id = state.next_id
    send_line(state, Map.put(payload, :id, id))
    %{state | next_id: id + 1, current: %{id: id, op: op}}
  end

  # ── Bridge messages ─────────────────────────────────────────────────────

  defp handle_bridge_message(%{"type" => "elicitation", "id" => id, "params" => params}, state) do
    case state.current do
      %{op: {:call, call}} ->
        if same_turn?(params, call.ctx) do
          server = self()
          approval_id = LemonCore.Id.approval_id()

          {pid, monitor} =
            spawn_monitor(fn ->
              response = Approval.answer(params, call.ctx, approval_id)
              send(server, {:elicitation_answer, id, response})
            end)

          entry = %{pid: pid, monitor: monitor, approval_id: approval_id}
          %{state | elicitations: Map.put(state.elicitations, id, entry)}
        else
          send_line(state, %{type: "elicitationResponse", id: id, response: %{action: "cancel"}})
          state
        end

      _ ->
        send_line(state, %{type: "elicitationResponse", id: id, response: %{action: "cancel"}})
        state
    end
  end

  defp handle_bridge_message(%{"type" => "elicitationCancelled", "id" => id}, state) do
    case Map.pop(state.elicitations, id) do
      {nil, _} ->
        state

      {entry, elicitations} ->
        abandon_elicitation(entry)
        %{state | elicitations: elicitations}
    end
  end

  defp handle_bridge_message(
         %{"id" => id, "ok" => ok} = message,
         %{current: %{id: id, op: op}} = state
       ) do
    state = %{state | current: nil}

    reply =
      if ok == true,
        do: {:ok, message["result"]},
        else: {:error, {:bridge_error, message["error"], message["code"]}}

    state
    |> complete(op, reply)
    |> run_next()
  end

  defp handle_bridge_message(_message, state) do
    Logger.debug("computer_use: ignored an uncorrelated bridge message")
    state
  end

  # The runtime echoes the call's turn metadata on its approval requests. When
  # it does, it must name the call in flight; a request for any other turn is
  # not this call's to answer.
  defp same_turn?(params, ctx) do
    case get_in(params, ["_meta", "x-codex-turn-metadata"]) do
      %{"session_id" => session_id, "turn_id" => turn_id} ->
        session_id == ctx.session_id and turn_id == ctx.turn_id

      _ ->
        true
    end
  end

  defp complete(state, :connect, {:ok, %{"instructions" => instructions, "tools" => tools}})
       when is_list(tools) do
    :persistent_term.put(@catalog_key, %{instructions: instructions || "", tools: tools})
    %{state | connected?: true, last_error: nil} |> reply_waiters({:ok, cached_catalog()})
  end

  defp complete(state, :connect, {:ok, _invalid}),
    do: connect_failed(state, :invalid_catalog)

  defp complete(state, :connect, {:error, reason}), do: connect_failed(state, reason)

  defp complete(state, {:call, call}, reply) do
    Process.demonitor(call.monitor, [:flush])
    send(call.caller, {call.ref, reply})
    state
  end

  defp complete(state, {:turn_ended, _session_id, _turn_id}, {:error, reason}) do
    Logger.debug("computer_use: turn cleanup failed: #{inspect(safe_reason(reason))}")
    state
  end

  defp complete(state, {:turn_ended, _session_id, _turn_id}, _ok), do: state

  defp connect_failed(state, reason) do
    reason = safe_reason(reason)
    Logger.warning("computer_use: LCU connection failed: #{inspect(reason)}")

    # Calls queued behind a failed connect would only retry it; fail them now.
    {calls, rest} =
      state.queue |> :queue.to_list() |> Enum.split_with(&match?({:call, _}, &1))

    Enum.each(calls, fn {:call, call} -> complete(state, {:call, call}, {:error, reason}) end)

    %{state | last_error: reason, queue: :queue.from_list(rest)}
    |> reply_waiters({:error, reason})
  end

  defp reply_waiters(state, reply) do
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    %{state | waiters: []}
  end

  # ── Cancellation ────────────────────────────────────────────────────────

  defp cancel_call(state, ref) do
    case state.current do
      %{id: id, op: {:call, %{ref: ^ref}}} ->
        send_line(state, %{type: "cancel", target: id})
        state

      _ ->
        {matching, rest} =
          state.queue
          |> :queue.to_list()
          |> Enum.split_with(&match?({:call, %{ref: ^ref}}, &1))

        Enum.each(matching, fn {:call, call} ->
          complete(state, {:call, call}, {:error, :aborted})
        end)

        %{state | queue: :queue.from_list(rest)}
    end
  end

  defp call_monitor?(state, monitor), do: not is_nil(call_ref_for_monitor(state, monitor))

  defp call_ref_for_monitor(state, monitor) do
    current =
      case state.current do
        %{op: {:call, %{monitor: ^monitor, ref: ref}}} -> [ref]
        _ -> []
      end

    queued =
      for {:call, %{monitor: ^monitor, ref: ref}} <- :queue.to_list(state.queue), do: ref

    List.first(current ++ queued)
  end

  defp find_elicitation(state, monitor) do
    Enum.find(state.elicitations, fn {_id, entry} -> entry.monitor == monitor end)
  end

  defp abandon_elicitation(%{pid: pid, monitor: monitor, approval_id: approval_id}) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pid, :kill)
    Approval.cancel(approval_id)
  end

  # ── Turns ───────────────────────────────────────────────────────────────

  defp track_turn(state, ctx) do
    key = {ctx.session_id, ctx.turn_id}

    if Map.has_key?(state.turns, key) do
      state
    else
      run_id = Map.get(ctx, :run_id)
      session_pid = Map.get(ctx, :session_pid)

      state = maybe_subscribe(state, run_id)

      monitor =
        if is_pid(session_pid), do: Process.monitor(session_pid), else: nil

      turn = %{run_id: run_id, session_monitor: monitor}
      %{state | turns: Map.put(state.turns, key, turn)}
    end
  end

  defp maybe_subscribe(state, run_id) when is_binary(run_id) and run_id != "" do
    if MapSet.member?(state.run_topics, run_id) do
      state
    else
      LemonCore.Bus.subscribe("run:" <> run_id)
      %{state | run_topics: MapSet.put(state.run_topics, run_id)}
    end
  end

  defp maybe_subscribe(state, _run_id), do: state

  defp end_turns(state, match?) do
    {ending, remaining} = Enum.split_with(state.turns, fn {_key, turn} -> match?.(turn) end)

    state =
      Enum.reduce(ending, %{state | turns: Map.new(remaining)}, fn {{session_id, turn_id}, turn},
                                                                   acc ->
        if turn.session_monitor, do: Process.demonitor(turn.session_monitor, [:flush])
        enqueue(acc, {:turn_ended, session_id, turn_id})
      end)

    state
    |> drop_unused_topics()
    |> run_next()
  end

  defp drop_unused_topics(state) do
    live = MapSet.new(state.turns, fn {_key, turn} -> turn.run_id end)

    Enum.reduce(state.run_topics, state, fn run_id, acc ->
      if MapSet.member?(live, run_id) do
        acc
      else
        LemonCore.Bus.unsubscribe("run:" <> run_id)
        %{acc | run_topics: MapSet.delete(acc.run_topics, run_id)}
      end
    end)
  end

  # ── Bridge process ──────────────────────────────────────────────────────

  defp ensure_bridge(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_bridge(state) do
    root = Config.lcu_root()
    node = Config.node()
    script = Config.bridge_script()
    [lcu | _] = Config.command()

    cond do
      not File.regular?(lcu) ->
        {:error, :lcu_not_installed, state}

      not File.regular?(node) ->
        {:error, :node_missing, state}

      not File.regular?(script) ->
        {:error, :bridge_missing, state}

      true ->
        port =
          Port.open({:spawn_executable, "/usr/bin/env"}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:line, @line_bytes},
            args: ["-i" | bridge_env()] ++ [node, script, root]
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        {:ok, %{state | port: port, os_pid: os_pid, buffer: []}}
    end
  rescue
    error -> {:error, {:spawn_failed, Exception.message(error) |> String.slice(0, 200)}, state}
  end

  # The bridge and the LCU server it starts get a minimal environment: the
  # runtime runs model-written JavaScript, and Lemon's provider credentials and
  # LEMON_* settings have no business there.
  defp bridge_env do
    System.get_env()
    |> Enum.filter(fn {name, _value} ->
      name in @passthrough_env or String.starts_with?(name, ["LCU_", "XDG_"])
    end)
    |> Enum.sort()
    |> Enum.map(fn {name, value} -> name <> "=" <> value end)
  end

  defp bridge_down(state, reason) do
    if state.current do
      case state.current.op do
        {:call, call} -> complete(state, {:call, call}, {:error, reason})
        :connect -> :ok
        _ -> :ok
      end
    end

    Enum.each(state.elicitations, fn {_id, entry} -> abandon_elicitation(entry) end)

    Enum.each(state.turns, fn {_key, turn} ->
      if turn.session_monitor, do: Process.demonitor(turn.session_monitor, [:flush])
    end)

    Enum.each(state.run_topics, &LemonCore.Bus.unsubscribe("run:" <> &1))
    :persistent_term.erase(@catalog_key)

    connect_in_flight? = match?(%{op: :connect}, state.current)

    state = %{
      state
      | port: nil,
        os_pid: nil,
        buffer: [],
        connected?: false,
        current: nil,
        elicitations: %{},
        turns: %{},
        run_topics: MapSet.new(),
        last_error: reason
    }

    # Drop pending cleanups: the server they were for is gone.
    queue = :queue.filter(&(not match?({:turn_ended, _, _}, &1)), state.queue)
    state = %{state | queue: queue}

    if connect_in_flight?, do: connect_failed(state, reason), else: state
  end

  defp stop_bridge(%{port: port, os_pid: os_pid}) when is_port(port) do
    # The bridge closes LCU and exits on stdin EOF; make sure it does.
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    if os_pid do
      spawn(fn ->
        Process.sleep(@kill_grace_ms)
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end)
    end

    :ok
  end

  defp stop_bridge(_state), do: :ok

  defp send_line(%{port: port}, payload) when is_port(port) do
    Port.command(port, [Jason.encode!(payload), "\n"])
    :ok
  catch
    _, _ -> :ok
  end

  defp send_line(_state, _payload), do: :ok

  defp safe_reason({:bridge_error, message, code}) when is_binary(message),
    do: {:bridge_error, String.slice(message, 0, 500), code}

  defp safe_reason(reason) when is_atom(reason) or is_integer(reason), do: reason
  defp safe_reason({tag, _} = reason) when is_atom(tag), do: reason
  defp safe_reason(_reason), do: :unknown

  defp error_tag(nil), do: nil
  defp error_tag(reason) when is_atom(reason), do: reason
  defp error_tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp error_tag(_reason), do: :unknown
end
