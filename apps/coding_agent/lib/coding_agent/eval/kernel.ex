defmodule CodingAgent.Eval.Kernel do
  @moduledoc """
  One `eval` kernel slot: a persistent Python or JavaScript process for one
  owner (coding session) and language.

  The slot state machine owns the kernel `Port`, which runs a driver from
  `priv/eval/` (`python_kernel.py` under `python3`/`python`, `js_kernel.js`
  under `bun`/`node`) in the session cwd. Commands are newline-delimited JSON
  on stdin. The kernel's stdout and stderr are one merged stream: protocol
  frames are lines prefixed with a per-process random marker and everything
  else is user output, relayed to the caller as it arrives. User code printing
  JSON, partial lines or protocol-looking text therefore cannot desynchronise
  the protocol.

  One cell runs at a time. Timeout first sends SIGINT and waits two seconds for
  the cell to unwind, preserving state when it does. Otherwise the process groups
  are killed, as they are on abort, `reset`, kernel crash, idle timeout, owner exit and
  slot shutdown. The slot stays alive after a kill while its owner lives, so the
  next run reports that it started a fresh kernel and why the previous one
  ended. Without an owner pid the slot stops entirely after its idle timeout.

  Each driver leads its own OS process group (the JavaScript kernel is a
  detached child of `js_kernel_host.js`, so its group differs from the port
  process) and reports its pid in the `ready` frame. That frame is only a
  claim: the slot binds the pid only when `ps` shows it leading its own group
  and being the port process itself or its direct child with the same birth.
  The group is then signalled only while that witness still matches, so
  children reparented away from the kernel but still in its group die with it.
  On Unix a kernel whose group cannot be proven this way is killed through the
  port process group and the run is refused, rather than reporting a stoppable
  kernel that is not. Descendants that escape the witnessed groups are unsupported.

  Caller messages for an accepted run `ref`:

    * `{:lemon_eval, ref, {:output, binary}}` - raw user output bytes
    * `{:lemon_eval, ref, {:tool_call, call, tool, args}}` - the cell asked to
      run session tool `tool` (call number `call`, unique within the cell);
      answer with `tool_reply/4` while the cell runs
    * `{:lemon_eval, ref, {:result, map}}` - the driver's result frame
    * `{:lemon_eval, ref, {:exited, status}}` - the kernel process exited

  Tool bridge frames: the driver emits
  `{"type":"tool_call","id":<cell id>,"call":<int>,"tool":<name>,"args":<any>}`
  and the slot relays only frames naming the busy cell. Replies go to the
  driver's stdin as `{"op":"tool_result","id":<cell id>,"call":<int>,"result":{...}}`
  or `{"op":"tool_error","id":<cell id>,"call":<int>,"message":<string>}`, and
  are written only while the run they answer is still busy.

  ## Transitions

  | State | Event | Next state |
  | --- | --- | --- |
  | idle | run without a kernel | starting |
  | starting | ready frame | verifying (asynchronous process-group witness) |
  | verifying | valid witness | busy |
  | idle | run with a kernel | busy |
  | busy | result | idle |
  | busy | timeout interruption | interrupting (asynchronous SIGINT) |
  | interrupting | result / two-second state timeout | idle / stopping |
  | any live state | abort, reset, caller exit or kernel failure | stopping |
  | stopping | process-group cleanup completes | idle (or starting after reset) |

  Startup uses one named timeout across starting and verification; interrupt
  grace and idle expiry use state timeouts. Status and output extend none of them.
  Process-group observation and signalling run in monitored tasks, so `os_pid/1`
  and owner binding remain responsive during slow `ps` or `kill` IO. A run is
  never admitted until its witness is verified or previous cleanup has finished.
  """

  @behaviour :gen_statem

  alias CodingAgent.BashExecutor
  alias CodingAgent.Eval.Output
  alias LemonCore.ProcessGroup

  @default_idle_timeout_ms 30 * 60 * 1000
  @startup_timeout_ms 20_000
  @max_frame_bytes 16 * 1024 * 1024

  @type language :: String.t()
  @type lost_reason :: :timeout | :aborted | :reset | :crashed | :idle

  defstruct [
    :key,
    :language,
    :cwd,
    :runtime,
    :owner_ref,
    :owner_pid,
    :idle_timeout_ms,
    :port,
    :os_pid,
    :kernel_group,
    :marker,
    :busy,
    :lost_reason,
    :display_path,
    :pip_command,
    :operation,
    :pending_run,
    :io_runner,
    startup_output: [],
    interrupt_from: [],
    buffer: "",
    generation: 0,
    next_id: 1
  ]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc """
  Starts a slot. Options: `:key` (registry key, required), `:language`
  (`"py"` | `"js"`), `:cwd`, `:runtime` (executable path), `:owner_pid`,
  `:idle_timeout_ms` and `:name`. `:io_runner` can wrap process IO tasks with
  an arity-two function receiving the operation kind and zero-arity IO function.
  """
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name when is_atom(name) -> :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  @doc """
  Runs `code`, starting a kernel first when the slot has none. With `reset:
  true` an existing kernel is killed first.

  Returns `{:ok, %{ref: ref, cell: id, restarted: nil | lost_reason}}`, where
  `cell` is the driver's cell id and `restarted` names why a previous kernel in
  this slot ended when this run had to start a fresh one.
  """
  @spec run(GenServer.server(), String.t(), keyword()) ::
          {:ok, %{ref: reference(), cell: pos_integer(), restarted: lost_reason() | nil}}
          | {:error, term()}
  def run(slot, code, opts \\ []) do
    :gen_statem.call(
      slot,
      {:run, code, Keyword.get(opts, :reset, false), self()},
      @startup_timeout_ms + 10_000
    )
  end

  @doc """
  Interrupts a timed-out cell, allowing two seconds to preserve the kernel.
  Aborts kill immediately. Output is relayed before the reply.
  """
  @spec interrupt(GenServer.server(), reference(), :timeout | :aborted) :: :preserved | :killed
  def interrupt(slot, ref, reason) do
    :gen_statem.call(slot, {:interrupt, ref, reason}, 15_000)
  catch
    :exit, _ -> :killed
  end

  @doc """
  Answers tool call `call` of run `ref` with `{:ok, result_map}` (resolved in
  the cell) or `{:error, message}` (rejected/raised in the cell). Dropped
  unless `ref` is still the busy run, so late replies are harmless.
  """
  @spec tool_reply(
          GenServer.server(),
          reference(),
          pos_integer(),
          {:ok, map()} | {:error, String.t()}
        ) ::
          :ok
  def tool_reply(slot, ref, call, payload),
    do: :gen_statem.cast(slot, {:tool_reply, ref, call, payload})

  @doc "OS pid of the running kernel process, if any."
  @spec os_pid(GenServer.server()) :: integer() | nil
  def os_pid(slot), do: :gen_statem.call(slot, :os_pid)

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner_ref =
      case Keyword.get(opts, :owner_pid) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    state = %__MODULE__{
      key: Keyword.fetch!(opts, :key),
      language: Keyword.fetch!(opts, :language),
      cwd: Keyword.fetch!(opts, :cwd),
      runtime: Keyword.fetch!(opts, :runtime),
      owner_ref: owner_ref,
      owner_pid: Keyword.get(opts, :owner_pid),
      pip_command: Keyword.get(opts, :pip_command),
      io_runner: Keyword.get(opts, :io_runner, fn _kind, fun -> fun.() end),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms) || @default_idle_timeout_ms
    }

    {:ok, :idle, state, idle_timeout(state)}
  end

  @impl true
  def handle_event({:call, from}, {:bind_owner, owner}, _phase, state) do
    {:reply, reply, state} = CodingAgent.ToolResources.owner_reply(:bind_owner, owner, state)
    {:keep_state, state, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, :os_pid, _phase, state),
    do: {:keep_state_and_data, [{:reply, from, state.os_pid}]}

  def handle_event({:call, from}, {:run, code, reset, caller}, :idle, state) do
    pending = %{from: from, code: code, caller: caller, monitor: Process.monitor(caller)}
    state = %{state | pending_run: pending}

    if reset and state.port do
      stop_kernel(state, :reset, :restart)
    else
      start_run(state)
    end
  end

  def handle_event({:call, _from}, {:run, _code, _reset, _caller}, :stopping, %{pending_run: nil}),
      do: {:keep_state_and_data, [:postpone]}

  def handle_event({:call, from}, {:run, _code, _reset, _caller}, _phase, _state),
    do: {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}

  def handle_event(
        {:call, from},
        {:interrupt, ref, :timeout},
        :busy,
        %{busy: %{ref: ref}} = state
      ) do
    target =
      if state.language == "py",
        do: "-#{state.os_pid}",
        else: Integer.to_string(state.os_pid)

    state =
      start_io(%{state | interrupt_from: [from]}, :interrupt, fn ->
        System.cmd("/bin/kill", ["-INT", "--", target], stderr_to_stdout: true)
      end)

    {:next_state, :interrupting, state}
  end

  def handle_event({:call, from}, {:interrupt, ref, reason}, phase, %{busy: %{ref: ref}} = state)
      when phase in [:busy, :interrupting] do
    stop_kernel(%{state | interrupt_from: [from | state.interrupt_from]}, reason, :idle)
  end

  def handle_event(
        {:call, from},
        {:interrupt, ref, _reason},
        :stopping,
        %{busy: %{ref: ref}} = state
      ),
      do: {:keep_state, %{state | interrupt_from: [from | state.interrupt_from]}}

  def handle_event({:call, from}, {:interrupt, _ref, _reason}, _phase, _state),
    do: {:keep_state_and_data, [{:reply, from, :preserved}]}

  def handle_event(
        :cast,
        {:tool_reply, ref, call, payload},
        phase,
        %{busy: %{ref: ref, id: id}, port: port} = state
      )
      when port != nil and phase in [:busy, :interrupting] do
    frame =
      with {:ok, result} <- payload,
           {:ok, json} <- Jason.encode(%{op: "tool_result", id: id, call: call, result: result}) do
        json
      else
        {:error, message} when is_binary(message) ->
          Jason.encode!(%{op: "tool_error", id: id, call: call, message: message})

        _ ->
          Jason.encode!(%{
            op: "tool_error",
            id: id,
            call: call,
            message: "unencodable tool result"
          })
      end

    try do
      Port.command(port, [frame, "\n"])
    rescue
      # The kernel exited; its exit_status message follows.
      ArgumentError -> :ok
    end

    {:keep_state, state}
  end

  def handle_event(:cast, {:tool_reply, _ref, _call, _payload}, _phase, _state),
    do: :keep_state_and_data

  def handle_event(:info, {port, {:data, data}}, :starting, %{port: port} = state) do
    {frames, raw, buffer} = split_frames(state.buffer <> data, state.marker)
    state = %{state | buffer: buffer, startup_output: [state.startup_output | raw]}

    case Enum.find(frames, &match?(%{"type" => "ready"}, &1)) do
      nil ->
        {:keep_state, state}

      ready ->
        state = start_io(state, :verify, fn -> owned_kernel_group(ready, state.os_pid) end)
        {:next_state, :verifying, state}
    end
  end

  def handle_event(:info, {port, {:data, data}}, phase, %{port: port} = state) do
    state = consume(state, data)

    if phase in [:busy, :interrupting] and is_nil(state.busy) do
      # Do not admit another cell while an old SIGINT can still be delivered.
      if state.operation do
        {:keep_state, state}
      else
        {:next_state, :idle, state, idle_timeout(state)}
      end
    else
      {:keep_state, state}
    end
  end

  def handle_event(:info, {ref, result}, phase, %{operation: %{ref: ref, kind: kind}} = state) do
    Process.demonitor(ref, [:flush])
    finish_io(kind, result, phase, %{state | operation: nil})
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        _phase,
        %{operation: %{ref: ref, kind: kind}} = state
      ) do
    finish_io(kind, {:io_error, reason}, nil, %{state | operation: nil})
  end

  def handle_event(:info, {port, {:exit_status, _status}}, :stopping, %{port: port} = state),
    do: {:keep_state, state}

  def handle_event(:info, {port, {:exit_status, status}}, phase, %{port: port} = state) do
    state = flush_buffer(state)

    if state.busy do
      notify(state, {:exited, status})
      Process.demonitor(state.busy.monitor, [:flush])
    end

    state = %{state | busy: nil}

    state =
      if phase in [:starting, :verifying] do
        output = startup_tail([state.startup_output, state.buffer])
        defer_run_error(state, "kernel exited during startup (status #{status})#{output}")
      else
        state
      end

    stop_kernel(state, :crashed, :idle, true)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _phase,
        %{owner_ref: ref} = state
      )
      when is_reference(ref),
      do: {:stop, :normal, state}

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        :stopping,
        %{pending_run: %{monitor: ref}} = state
      ),
      do: {:keep_state, %{state | pending_run: nil}}

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _phase,
        %{pending_run: %{monitor: ref}} = state
      ),
      do: stop_kernel(%{state | pending_run: nil}, :aborted, :idle)

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        :stopping,
        %{busy: %{monitor: ref}} = state
      ),
      do: {:keep_state, state}

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _phase,
        %{busy: %{monitor: ref}} = state
      ),
      do: stop_kernel(state, :aborted, :idle)

  def handle_event({:timeout, :startup}, :expired, phase, state)
      when phase in [:starting, :verifying] do
    output = startup_tail([state.startup_output, state.buffer])

    state =
      defer_run_error(
        state,
        "kernel did not start within #{div(@startup_timeout_ms, 1000)}s#{output}"
      )

    stop_kernel(state, :crashed, :idle)
  end

  def handle_event(:state_timeout, :interrupt_grace, :interrupting, state),
    do: stop_kernel(state, :timeout, :idle)

  def handle_event(:state_timeout, :idle, :idle, state) do
    if state.owner_ref do
      if state.port, do: stop_kernel(state, :idle, :dormant), else: :keep_state_and_data
    else
      {:stop, :normal, state}
    end
  end

  def handle_event(:info, _message, _phase, _state), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _phase, state) do
    cancel_io(state)

    # Shutdown cannot accept calls. Cleanup still runs outside this callback;
    # the supervised worker retains the birth witness after the port closes.
    if state.port do
      Task.Supervisor.start_child(CodingAgent.TaskSupervisor, fn ->
        kill_os_processes(state, true)
        if state.display_path, do: File.rm(state.display_path)
      end)
    end

    :ok
  end

  defp idle_timeout(state), do: [{:state_timeout, state.idle_timeout_ms, :idle}]

  defp start_io(state, kind, fun) do
    runner = state.io_runner
    task = Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn -> runner.(kind, fun) end)
    %{state | operation: %{ref: task.ref, pid: task.pid, kind: kind}}
  end

  defp cancel_io(%{operation: nil} = state), do: state

  defp cancel_io(state) do
    Process.exit(state.operation.pid, :kill)
    Process.demonitor(state.operation.ref, [:flush])
    %{state | operation: nil}
  end

  defp start_run(%{port: nil} = state) do
    restarted = if state.generation > 0, do: state.lost_reason || :reset
    state = %{state | pending_run: Map.put(state.pending_run, :restarted, restarted)}

    case open_kernel(state) do
      {:ok, state} ->
        {:next_state, :starting, state, [{{:timeout, :startup}, @startup_timeout_ms, :expired}]}

      {:error, reason, state} ->
        {:next_state, :idle, fail_run(state, reason), idle_timeout(state)}
    end
  end

  defp start_run(state), do: execute(state)

  defp execute(state) do
    pending = state.pending_run
    id = state.next_id
    File.write!(state.display_path, "")
    Port.command(state.port, [Jason.encode!(%{op: "execute", id: id, code: pending.code}), "\n"])
    ref = make_ref()
    busy = %{ref: ref, caller: pending.caller, monitor: pending.monitor, id: id}
    reply = {:ok, %{ref: ref, cell: id, restarted: Map.get(pending, :restarted)}}
    state = %{state | busy: busy, pending_run: nil, next_id: id + 1, startup_output: []}
    {:next_state, :busy, state, [{:reply, pending.from, reply}, {{:timeout, :startup}, :cancel}]}
  end

  defp fail_run(%{pending_run: nil} = state, _reason), do: state

  defp fail_run(state, reason) do
    :gen_statem.reply(state.pending_run.from, {:error, reason})
    Process.demonitor(state.pending_run.monitor, [:flush])
    %{state | pending_run: nil}
  end

  defp defer_run_error(state, reason),
    do: %{state | pending_run: Map.put(state.pending_run, :error, reason)}

  defp finish_io(:verify, {:ok, group}, _phase, state),
    do: execute(%{state | kernel_group: group})

  defp finish_io(:verify, _error, _phase, state) do
    if match?({:win32, _}, :os.type()) do
      execute(state)
    else
      reason =
        "could not prove the kernel's own process group (needs ps); refusing to run code whose processes could not be stopped"

      stop_kernel(defer_run_error(state, reason), :crashed, :idle)
    end
  end

  defp finish_io(:interrupt, _result, _phase, %{busy: nil} = state),
    do: {:next_state, :idle, complete_interrupt(state, :preserved), idle_timeout(state)}

  defp finish_io(:interrupt, {_output, 0}, _phase, state),
    do: {:keep_state, state, [{:state_timeout, 2_000, :interrupt_grace}]}

  defp finish_io(:interrupt, _error, _phase, state), do: stop_kernel(state, :timeout, :idle)

  defp finish_io({:stop, reason, next}, _result, _phase, state) do
    state = finish_stop(state, reason)

    state =
      case state.pending_run do
        %{error: error} -> fail_run(state, error)
        _ -> state
      end

    cond do
      next == :restart and state.pending_run -> start_run(state)
      next == :dormant -> {:next_state, :idle, state}
      true -> {:next_state, :idle, state, idle_timeout(state)}
    end
  end

  defp stop_kernel(state, reason, next, port_exited \\ false) do
    state = cancel_io(state)

    state =
      start_io(state, {:stop, reason, next}, fn -> kill_os_processes(state, port_exited) end)

    {:next_state, :stopping, state, [{{:timeout, :startup}, :cancel}]}
  end

  # ── Kernel process ──────────────────────────────────────────────────────

  defp open_kernel(state) do
    token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    marker = "\x1eLEMONEVAL:" <> token <> ":"
    display_path = Path.join(System.tmp_dir!(), "lemon-eval-display-#{token}.jsonl")
    File.write!(display_path, "", [:exclusive])
    File.chmod!(display_path, 0o600)
    state = %{state | display_path: display_path}

    env = [
      {~c"LEMON_EVAL_DISPLAY_PATH", String.to_charlist(display_path)},
      {~c"LEMON_EVAL_PIP_COMMAND", String.to_charlist(Jason.encode!(state.pip_command))},
      {~c"PYTHONUNBUFFERED", ~c"1"},
      {~c"PYTHONDONTWRITEBYTECODE", ~c"1"},
      {~c"NO_COLOR", ~c"1"}
    ]

    # The output-framing marker is not a Lemon credential, but its name matches
    # the `ChildEnv` scrub, so it is added after the scrubbed environment.
    framing = {~c"LEMON_EVAL_TOKEN", String.to_charlist(token)}

    child_env =
      env
      |> LemonCore.ChildEnv.port_env()
      |> List.keydelete(~c"LEMON_EVAL_TOKEN", 0)
      |> Kernel.++([framing])

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      {:args, [driver_path(state.language)]},
      {:cd, state.cwd},
      {:env, child_env}
    ]

    try do
      # The JS host launches a detached kernel group. Its local witness cannot
      # certify whole-workload cleanup if the slot dies before killing that group.
      if state.language == "js", do: LemonCore.NativeProcess.unsupported!()

      port = LemonCore.NativeProcess.open({:spawn_executable, state.runtime}, port_opts)
      os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid

      state = %{
        state
        | port: port,
          os_pid: os_pid,
          kernel_group: nil,
          marker: marker,
          buffer: "",
          generation: state.generation + 1,
          lost_reason: nil
      }

      {:ok, state}
    rescue
      error ->
        File.rm(display_path)
        {:error, "could not start #{state.runtime}: #{Exception.message(error)}", state}
    end
  end

  defp startup_tail(iodata) do
    case iodata |> IO.iodata_to_binary() |> BashExecutor.sanitize_output() |> String.trim() do
      "" -> ""
      text -> ":\n" <> String.slice(text, -2000, 2000)
    end
  end

  defp owned_kernel_group(%{"pid" => pid}, port_pid)
       when is_integer(pid) and is_integer(port_pid) do
    with {:ok, group} <- ProcessGroup.capture_workload_group(pid),
         true <- pid == port_pid or port_child?(group, port_pid) do
      {:ok, group}
    else
      _ -> :error
    end
  end

  defp owned_kernel_group(_ready, _port_pid), do: :error

  # The claimed leader must be a direct child of the live port process, observed
  # with the same birth as the group witness (so not a recycled pid).
  defp port_child?(%{root_pid: pid, root_birth: birth}, port_pid) do
    with ps when is_binary(ps) <- Enum.find(["/bin/ps", "/usr/bin/ps"], &File.regular?/1),
         {output, 0} <-
           System.cmd(ps, ["-o", "ppid=,lstart=", "-p", Integer.to_string(pid)],
             stderr_to_stdout: true
           ),
         [parent, observed_birth] <- String.split(String.trim(output), ~r/\s+/, parts: 2),
         {^port_pid, ""} <- Integer.parse(parent) do
      observed_birth == birth
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  # Signal the witnessed kernel group first, while its leader can still prove
  # ownership, then the port process group. After the port exited, a kernel
  # group rooted at the port pid is known to have exited, so a live process
  # with that pid is a recycled identity and is never signalled.
  defp kill_os_processes(state, port_exited) do
    if state.kernel_group do
      root_exited = port_exited and state.kernel_group.root_pid == state.os_pid
      ProcessGroup.terminate(state.kernel_group, signal: :sigkill, root_exited: root_exited)
    end

    if state.os_pid, do: ProcessGroup.terminate(state.os_pid, signal: :sigkill)
  end

  defp finish_stop(state, reason) do
    # Relay output that was produced before the kill.
    state = drain_port(state)
    state = flush_buffer(state)

    try do
      if state.port, do: Port.close(state.port)
    catch
      :error, _ -> :ok
    end

    if state.busy, do: Process.demonitor(state.busy.monitor, [:flush])

    if state.busy do
      case Output.read_displays(state.display_path) do
        {:ok, displays} -> notify(state, {:result, %{"status" => "error", "outputs" => displays}})
        _ -> :ok
      end
    end

    if state.display_path, do: File.rm(state.display_path)
    state = complete_interrupt(state, :killed)

    %{
      state
      | port: nil,
        os_pid: nil,
        kernel_group: nil,
        busy: nil,
        buffer: "",
        lost_reason: reason
    }
  end

  defp complete_interrupt(state, outcome) do
    Enum.each(state.interrupt_from, &:gen_statem.reply(&1, outcome))
    %{state | interrupt_from: []}
  end

  defp drain_port(%{port: port} = state) do
    receive do
      {^port, {:data, data}} -> state |> consume(data) |> drain_port()
    after
      0 -> state
    end
  end

  defp driver_path("py"), do: Application.app_dir(:coding_agent, "priv/eval/python_kernel.py")
  defp driver_path("js"), do: Application.app_dir(:coding_agent, "priv/eval/js_kernel_host.js")

  # ── Stream parsing ──────────────────────────────────────────────────────

  defp consume(state, data) do
    {frames, raw, buffer} = split_frames(state.buffer <> data, state.marker)
    state = %{state | buffer: buffer}
    if IO.iodata_length(raw) > 0, do: notify(state, {:output, IO.iodata_to_binary(raw)})

    state =
      if byte_size(buffer) > @max_frame_bytes do
        notify(state, {:output, buffer})
        %{state | buffer: ""}
      else
        state
      end

    Enum.reduce(frames, state, &handle_frame/2)
  end

  defp flush_buffer(%{buffer: ""} = state), do: state

  defp flush_buffer(state) do
    notify(state, {:output, state.buffer})
    %{state | buffer: ""}
  end

  defp handle_frame(
         %{"type" => "tool_call", "id" => id, "call" => call, "tool" => tool} = frame,
         %{busy: %{id: id}} = state
       )
       when is_integer(call) and is_binary(tool) do
    notify(state, {:tool_call, call, tool, Map.get(frame, "args")})
    state
  end

  defp handle_frame(%{"type" => "result", "id" => id} = frame, %{busy: %{id: id}} = state) do
    frame =
      case Output.read_displays(state.display_path) do
        {:ok, displays} -> Map.put(frame, "outputs", displays)
        {:error, message} -> Map.merge(frame, %{"status" => "error", "error" => message})
      end

    notify(state, {:result, frame})
    Process.demonitor(state.busy.monitor, [:flush])
    state = %{state | busy: nil}
    if state.operation, do: state, else: complete_interrupt(state, :preserved)
  end

  defp handle_frame(_frame, state), do: state

  defp notify(%{busy: %{ref: ref, caller: caller}}, message),
    do: send(caller, {:lemon_eval, ref, message})

  defp notify(_state, _message), do: :ok

  @doc false
  # Splits `data` into decoded frames, raw output iodata and a retained
  # remainder (an incomplete frame or a possible marker prefix).
  @spec split_frames(binary(), binary()) :: {[map()], iodata(), binary()}
  def split_frames(data, marker), do: split_frames(data, marker, [], [])

  defp split_frames(data, marker, frames, raw) do
    case :binary.match(data, marker) do
      {pos, len} ->
        before = binary_part(data, 0, pos)
        rest = binary_part(data, pos + len, byte_size(data) - pos - len)

        case :binary.match(rest, "\n") do
          {nl, 1} ->
            line = binary_part(rest, 0, nl)
            after_line = binary_part(rest, nl + 1, byte_size(rest) - nl - 1)

            case Jason.decode(line) do
              {:ok, %{} = frame} ->
                split_frames(after_line, marker, [frame | frames], [raw | before])

              _ ->
                # Not a well-formed frame: treat the line as user output.
                split_frames(after_line, marker, frames, [raw, before, line, "\n"])
            end

          :nomatch ->
            {Enum.reverse(frames), [raw | before], binary_part(data, pos, byte_size(data) - pos)}
        end

      :nomatch ->
        keep = partial_marker_suffix(data, marker)
        emit = binary_part(data, 0, byte_size(data) - keep)
        {Enum.reverse(frames), [raw | emit], binary_part(data, byte_size(data) - keep, keep)}
    end
  end

  # Length of the longest suffix of `data` that is a proper prefix of `marker`.
  defp partial_marker_suffix(data, marker) do
    max_len = min(byte_size(data), byte_size(marker) - 1)

    Enum.find(max_len..1//-1, 0, fn len ->
      binary_part(data, byte_size(data) - len, len) == binary_part(marker, 0, len)
    end)
  end
end
