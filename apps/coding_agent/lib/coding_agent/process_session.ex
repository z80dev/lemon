defmodule CodingAgent.ProcessSession do
  @moduledoc """
  GenServer that manages a single background process via a Port.

  Features:
  - Rolling log buffer bounded by line count and retained bytes, split on
    complete lines (a partial line is held until its newline arrives or the
    process exits)
  - Incremental reads (`read_output/1`) with a per-process read cursor
  - Stdin writing support
  - Process kill support
  - Exit status tracking
  - Integration with ProcessStore for persistence

  ## Output capture

  Received bytes go to two bounded destinations:

  - An in-memory tail of recent lines. Its bytes (every retained line counts its
    bytes plus its consumed newline, plus the held partial line) never exceed
    `:max_retained_bytes`. Lines longer than the segment size (64 KiB, or less
    for small budgets) are split into segments; the oldest lines are discarded
    first. Retained lines are copied, so they never pin a large received chunk.
    `ProcessStore` mirrors exactly the retained lines, so the two copies hold at
    most twice that budget. Parsing scans bounded windows of the received chunk:
    it never concatenates or splits the whole chunk. Additional binary scratch
    space is at most two line segments; the incoming port message itself and
    downstream subscriber/mailbox accumulation are outside this capture budget.
  - A private artifact file (mode 0600) holding the head of the output. It
    grows to at most the capacity reserved at start: `:max_artifact_bytes`,
    reduced to what remains of the owner's `:max_owner_artifact_bytes` and
    `:max_runtime_artifact_bytes`, after reclaiming stopped sessions' artifacts
    (see `CodingAgent.ProcessStore.reserve_artifact/4`). Bytes beyond that capacity
    are counted and discarded; the process keeps running.

  Reaching a capture limit never changes execution status. A file write failure
  closes the artifact, records a bounded `artifact_error` atom and keeps the
  in-memory tail. `output` statistics in poll/read results report received,
  retained and discarded bytes and whether the artifact is incomplete; a
  truncated artifact is never described as complete output.

  Limits come from per-call options, then `config :coding_agent,
  :process_output`, then defaults. Each must be a positive integer; an invalid
  value stops the session before a file is created or the command runs.
  """

  use GenServer

  require Logger

  alias CodingAgent.{BashExecutor, ProcessStore}
  alias LemonCore.TerminalBackends
  alias LemonCore.TerminalBackends.{Docker, Ssh}

  @default_max_log_lines 1000
  # A line longer than this (for example `\r` progress output with no
  # newline) is split into segments of this size instead of growing without bound.
  @max_line_bytes 65_536
  @output_limit_defaults [
    max_retained_bytes: 1_048_576,
    max_artifact_bytes: 16_777_216,
    max_owner_artifact_bytes: 134_217_728,
    max_runtime_artifact_bytes: 536_870_912
  ]

  # Client API

  @doc """
  Start a new process session.

  Options:
  - :command - The command to execute (required)
  - :cwd - Working directory (default: current directory)
  - :env - Environment variables map (default: %{})
  - :process_id - Pre-generated process ID (optional)
  - :max_log_lines - Maximum log lines to keep (default: 1000)
  - :max_retained_bytes - In-memory output tail budget in bytes
  - :max_artifact_bytes - Per-process artifact file cap in bytes
  - :max_owner_artifact_bytes - Aggregate artifact budget for the owner in bytes
  - :max_runtime_artifact_bytes - Runtime-wide aggregate artifact budget in bytes
  - :timeout_ms - Timeout in milliseconds (optional, nil = no timeout)
  - :on_exit - Callback when process exits (optional)
  - :owner - Owning session id, recorded in the store (optional)
  - :owner_pid - Owning process; the OS process tree is killed when it exits (optional)
  """
  def start_link(opts) do
    process_id = Keyword.get(opts, :process_id) || generate_id()
    name = via_tuple(process_id)
    GenServer.start_link(__MODULE__, {process_id, opts}, name: name)
  end

  @doc """
  Get the process ID for a session.
  """
  def get_process_id(pid) when is_pid(pid) do
    GenServer.call(pid, :get_process_id)
  end

  def get_process_id(process_id) when is_binary(process_id) do
    process_id
  end

  @doc """
  Get the current status and logs for a process.
  """
  def poll(process_id, line_count \\ 100) do
    GenServer.call(via_tuple(process_id), {:poll, line_count}, 5_000)
  end

  @doc """
  Return the complete output lines produced since the previous
  `read_output/1` call and advance the read cursor.

  `dropped_lines` counts lines that scrolled out of the bounded buffer before
  they could be read.
  """
  def read_output(process_id, opts \\ []) do
    GenServer.call(via_tuple(process_id), {:read_output, Keyword.get(opts, :peek, false)}, 5_000)
  end

  @doc """
  Write to the process's stdin.
  """
  def write_stdin(process_id, data, opts \\ []) do
    GenServer.call(
      via_tuple(process_id),
      {:write_stdin, data, Keyword.get(opts, :eof, false)},
      5_000
    )
  end

  @doc """
  Kill the process.
  """
  def kill(process_id, signal \\ :sigterm) do
    GenServer.call(via_tuple(process_id), {:kill, signal}, 5_000)
  end

  @doc """
  Get the full session state.
  """
  def get_state(process_id) do
    GenServer.call(via_tuple(process_id), :get_state, 5_000)
  end

  @doc """
  Stop the session (does not kill the process if already exited).

  Already-stopped sessions and concurrent exits are successful cleanup. Unexpected
  concurrent exit reasons are logged without exposing process data; a stop failure
  while the resolved session is still alive continues to exit the caller.
  """
  @spec stop(String.t()) :: :ok
  def stop(process_id) do
    case GenServer.whereis(via_tuple(process_id)) do
      nil -> :ok
      pid -> stop_session(pid)
    end
  end

  @doc """
  Check if a process session is alive.
  """
  def alive?(process_id) do
    case Registry.lookup(CodingAgent.ProcessRegistry, process_id) do
      [{pid, _}] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # Server Callbacks

  @impl true
  def init({process_id, opts}) do
    case Keyword.get(opts, :launch_fingerprint) do
      nil ->
        init_process(process_id, opts)

      fingerprint ->
        with :ok <- ensure_pending_owner(process_id, opts),
             :ok <- ProcessStore.claim_launch(process_id, Keyword.get(opts, :owner), fingerprint) do
          init_process(process_id, opts)
        else
          {:error, reason} -> {:stop, reason}
        end
    end
  rescue
    _ -> {:stop, :launch_failed}
  catch
    :throw, :confirmed_startup_failure -> {:stop, :startup_failed}
    :throw, :uncertain_startup -> {:stop, :workload_unobservable}
    :throw, :process_start_failed -> {:stop, :process_start_failed}
    _, _ -> {:stop, :launch_failed}
  end

  defp init_process(process_id, opts) do
    with {:ok, limits} <- output_limits(opts),
         {:ok, output_path, output_file} <- open_output_file() do
      start_session(process_id, opts, limits, output_path, output_file)
    else
      {:error, reason} ->
        # A claimed launch never started; release its capacity before stopping.
        if Keyword.get(opts, :launch_fingerprint),
          do: ProcessStore.confirm_termination(process_id, {:startup_failed, reason})

        {:stop, reason}
    end
  end

  defp start_session(process_id, opts, limits, output_path, output_file) do
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    env = Keyword.get(opts, :env, %{})
    backend = Keyword.get(opts, :backend, :local)
    terminal_capabilities = TerminalBackends.capabilities(backend)
    max_log_lines = limits.max_log_lines
    timeout_ms = Keyword.get(opts, :timeout_ms)
    on_exit = Keyword.get(opts, :on_exit)
    owner = Keyword.get(opts, :owner)

    artifact_capacity =
      try do
        # Capture accounting must succeed before any external process starts.
        ProcessStore.new_process(%{
          id: process_id,
          command: command,
          cwd: cwd,
          env: env,
          backend: backend,
          terminal_capabilities: terminal_capabilities,
          max_log_lines: max_log_lines,
          full_output_path: output_path,
          timeout_ms: timeout_ms,
          restarted_from: Keyword.get(opts, :restarted_from),
          restart_generation: Keyword.get(opts, :restart_generation, 0),
          owner: owner,
          status: :starting,
          launch_fingerprint: Keyword.get(opts, :launch_fingerprint),
          launch_classification: :outcome_unknown,
          capacity_held: is_binary(Keyword.get(opts, :launch_fingerprint)),
          termination_confirmed: false
        })

        case ProcessStore.reserve_artifact(
               process_id,
               limits.max_artifact_bytes,
               limits.max_owner_artifact_bytes,
               limits.max_runtime_artifact_bytes
             ) do
          {:ok, capacity} -> capacity
          {:error, _reason} -> throw(:process_start_failed)
        end
      rescue
        _exception -> failed_start(process_id, opts, output_path, output_file)
      catch
        _kind, _reason -> failed_start(process_id, opts, output_path, output_file)
      end

    # Start the OS process via Port
    {port, stdin_path} =
      try do
        if before_start = Keyword.get(opts, :before_start), do: before_start.()
        start_port(command, cwd, env, backend)
      rescue
        _exception -> failed_start(process_id, opts, output_path, output_file)
      catch
        _kind, _reason -> failed_start(process_id, opts, output_path, output_file)
      end

    os_pid = get_os_pid(port)

    # Bind the owned group durably before the stdin gate allows user execution.
    workload_identity =
      try do
        activate_workload(process_id, port, os_pid, output_file)
      catch
        kind, reason ->
          File.rm(stdin_path)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    {:ok, stdin} = File.open(stdin_path, [:write, :binary, :raw])
    ProcessStore.classify_launch(process_id, :accepted)

    # Internal synchronization seam; never exposed in the agent's tool schema.
    if on_start = Keyword.get(opts, :on_start), do: on_start.(process_id)

    # Set up timeout if specified
    timeout_ref = if timeout_ms, do: Process.send_after(self(), :timeout, timeout_ms)

    owner_monitor =
      case Keyword.get(opts, :owner_pid) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    state = %{
      process_id: process_id,
      port: port,
      stdin: stdin,
      stdin_path: stdin_path,
      stdin_closed: false,
      os_pid: os_pid,
      workload_identity: workload_identity,
      root_exited: false,
      root_exit_code: nil,
      workload_timer: nil,
      command: command,
      cwd: cwd,
      env: env,
      backend: backend,
      terminal_capabilities: terminal_capabilities,
      status: :running,
      exit_code: nil,
      max_log_lines: max_log_lines,
      max_retained_bytes: limits.max_retained_bytes,
      max_line_bytes: min(@max_line_bytes, max(limits.max_retained_bytes - 1, 1)),
      log_bytes: 0,
      received_bytes: 0,
      artifact_capacity: artifact_capacity,
      artifact_bytes: 0,
      artifact_discarded_bytes: 0,
      artifact_error: nil,
      artifact_size_unknown: false,
      output_finalized: false,
      log_buffer: :queue.new(),
      log_count: 0,
      partial_line: "",
      total_lines: 0,
      read_cursor: 0,
      output_file: output_file,
      full_output_path: output_path,
      owner: owner,
      owner_monitor: owner_monitor,
      timeout_ref: timeout_ref,
      termination_reason: nil,
      on_exit: on_exit,
      on_root_exit: Keyword.get(opts, :on_root_exit),
      started_at: System.system_time(:second),
      completed_at: nil,
      restarted_from: Keyword.get(opts, :restarted_from),
      restart_generation: Keyword.get(opts, :restart_generation, 0)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_process_id, _from, state) do
    {:reply, state.process_id, state}
  end

  def handle_call({:poll, line_count}, _from, state) do
    logs =
      state.log_buffer
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.take(line_count)
      |> Enum.map(&elem(&1, 0))

    result = %{
      process_id: state.process_id,
      status: state.status,
      exit_code: state.exit_code,
      os_pid: state.os_pid,
      logs: logs,
      partial_line: state.partial_line,
      command: state.command,
      cwd: state.cwd,
      backend: state.backend,
      terminal_capabilities: state.terminal_capabilities,
      max_log_lines: state.max_log_lines,
      log_line_count: state.log_count,
      started_at: state.started_at,
      completed_at: state.completed_at,
      restarted_from: state.restarted_from,
      restart_generation: state.restart_generation,
      output: output_stats(state)
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:read_output, peek}, _from, state) do
    first_buffered = state.total_lines - state.log_count
    cursor = if peek, do: 0, else: state.read_cursor
    start = max(cursor, first_buffered)

    lines =
      state.log_buffer
      |> :queue.to_list()
      |> Enum.drop(start - first_buffered)
      |> Enum.map(&elem(&1, 0))

    unless peek, do: ProcessStore.put_read_cursor(state.process_id, state.total_lines)

    result = %{
      process_id: state.process_id,
      status: state.status,
      exit_code: state.exit_code,
      command: state.command,
      owner: state.owner,
      lines: lines,
      full_output_path: state.full_output_path,
      dropped_lines: start - cursor,
      output: output_stats(state)
    }

    state = if peek, do: state, else: %{state | read_cursor: state.total_lines}
    {:reply, {:ok, result}, state}
  end

  def handle_call({:write_stdin, data, eof}, _from, state) do
    if state.status == :running and not state.stdin_closed do
      # Stdin may make the root exit immediately. Retain any verified surviving
      # members before forwarding bytes, while root ownership still binds them.
      state = remember_workload_members(state)

      if state.status == :running do
        try do
          :ok = :file.write(state.stdin, data)
          if eof, do: File.close(state.stdin)
          {:reply, :ok, %{state | stdin_closed: eof}}
        rescue
          e -> {:reply, {:error, e}, state}
        end
      else
        {:reply, {:error, {:outcome_unknown, state.process_id}}, state}
      end
    else
      reason = if state.status == :running, do: :stdin_closed, else: :process_not_running
      {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:kill, signal}, _from, state) do
    if state.status in [:running, :killing, :lost] and state.os_pid do
      {reply, state} = request_workload_stop(state, signal, :canceled)

      if reply == :ok and signal == :sigterm,
        do: Process.send_after(self(), :kill_after_grace, 2_000)

      {:reply, reply, state}
    else
      {:reply, {:error, :process_not_running}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state =
      write_artifact(%{state | received_bytes: state.received_bytes + byte_size(data)}, data)

    state = consume_output(state, data, 0)
    {:noreply, sync_output(state)}
  end

  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, root_exited: false} = state
      ) do
    state = finalize_output(state)
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

    state = %{state | root_exited: true, root_exit_code: exit_code, timeout_ref: nil}
    ProcessStore.update_workload_identity(state.process_id, state.workload_identity, true)

    state =
      case owned_workload_status(state) do
        :terminated -> finish_workload(state)
        {_liveness, identity} -> retain_workload(state, identity)
      end

    # Internal fault-test barrier, distinct from confirmed workload completion.
    if state.on_root_exit, do: state.on_root_exit.(state.process_id)
    {:noreply, state}
  end

  def handle_info(:reconcile_workload, %{root_exited: true, status: :lost} = state) do
    state = %{state | workload_timer: nil}

    case owned_workload_status(state) do
      :terminated -> {:noreply, finish_workload(state)}
      {_liveness, identity} -> {:noreply, retain_workload(state, identity)}
    end
  end

  def handle_info(:external_termination_confirmed, %{status: :lost} = state) do
    if state.workload_timer, do: Process.cancel_timer(state.workload_timer)
    {:stop, :normal, state}
  end

  def handle_info(:kill_after_grace, state) do
    if state.status in [:running, :killing, :lost] do
      {_reply, state} = request_workload_stop(state, :sigkill, :canceled)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:timeout, state) do
    if state.status in [:running, :killing, :lost] and not state.root_exited do
      {_reply, state} =
        request_workload_stop(state, :sigkill, state.termination_reason || :timeout)

      {:noreply, %{state | timeout_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state)
      when is_reference(ref) do
    if state.status in [:running, :killing, :lost] do
      {_reply, state} = request_workload_stop(state, :sigkill, :canceled)
      {:noreply, %{state | owner_monitor: nil}}
    else
      {:noreply, %{state | owner_monitor: nil}}
    end
  end

  def handle_info(:stop_after_exit, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} when is_map(state) ->
        {:state, Map.take(state, [:process_id, :status, :backend])}

      {:state, _} ->
        {:state, :unavailable}

      {:message, _} ->
        {:message, :process_event}

      {:log, _} ->
        {:log, []}

      {:reason, reason}
      when reason in [:normal, :shutdown, :killed, :startup_failed, :launch_failed] ->
        {:reason, reason}

      {:reason, _} ->
        {:reason, :process_session_failed}

      pair ->
        pair
    end)
  end

  @impl true
  def terminate(_reason, state) do
    if not state.output_finalized do
      try do
        finalize_output(state)
      catch
        # The store may already be gone during shutdown; still release the file.
        :exit, _reason -> close_output_file(state)
      end
    end

    # Ensure port is closed
    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    unless state.stdin_closed, do: File.close(state.stdin)
    File.rm(state.stdin_path)

    :ok
  end

  # Private Functions

  defp via_tuple(process_id) do
    {:via, Registry, {CodingAgent.ProcessRegistry, process_id}}
  end

  defp stop_session(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, reason ->
      # Resolve once so a registry change cannot make us check a different owner.
      # Liveness before stop/1 cannot prevent the session exiting during the call.
      if Process.alive?(pid) do
        :erlang.raise(:exit, reason, __STACKTRACE__)
      else
        log_stop_exit(reason)
        :ok
      end
  end

  defp log_stop_exit({reason, {GenServer, :stop, _args}}), do: log_stop_exit(reason)
  defp log_stop_exit({reason, {:sys, :terminate, _args}}), do: log_stop_exit(reason)

  defp log_stop_exit(reason) when reason in [:noproc, :normal, :shutdown, :launch_canceled],
    do: :ok

  defp log_stop_exit({:shutdown, _reason}), do: :ok

  defp log_stop_exit(_reason) do
    Logger.warning("Process session exited abnormally during cleanup")
  end

  defp ensure_pending_owner(process_id, opts) do
    abandoned? =
      Enum.any?(pending_owner_keys(opts), fn key ->
        case Keyword.get(opts, key) do
          pid when is_pid(pid) -> not Process.alive?(pid)
          _ -> false
        end
      end)

    if abandoned? do
      ProcessStore.cancel_launch(process_id, Keyword.get(opts, :owner))
      {:error, :launch_canceled}
    else
      :ok
    end
  end

  defp pending_owner_keys(opts) do
    if is_pid(Keyword.get(opts, :owner_pid)),
      do: [:owner_pid],
      else: [:admission_caller_pid]
  end

  defp activate_workload(process_id, port, os_pid, output_file) do
    case :os.type() do
      {:unix, _} ->
        case BashExecutor.capture_workload_group(os_pid) do
          {:ok, identity} ->
            ProcessStore.mark_running(process_id, os_pid, identity)
            true = Port.command(port, "\n")
            identity

          {:error, _} ->
            # The gate has not been released. Do not turn lost observation of
            # the native wrapper into a false confirmed-termination receipt.
            Port.close(port)
            File.close(output_file)
            ProcessStore.mark_unknown(process_id)
            throw(:uncertain_startup)
        end

      _ ->
        ProcessStore.mark_running(process_id, os_pid)
        nil
    end
  end

  defp owned_workload_status(%{backend: :local, workload_identity: identity} = state)
       when is_map(identity) do
    BashExecutor.workload_group_status(identity, state.root_exited)
  end

  defp owned_workload_status(state), do: {:unknown, state.workload_identity}

  defp retain_workload(state, identity) do
    if identity != state.workload_identity,
      do: ProcessStore.update_workload_identity(state.process_id, identity, state.root_exited)

    if state.status != :lost, do: ProcessStore.mark_unknown(state.process_id)

    timer =
      if state.backend == :local and is_map(identity) and not identity.ownership_lost do
        Process.send_after(self(), :reconcile_workload, 100)
      end

    %{state | status: :lost, exit_code: nil, workload_identity: identity, workload_timer: timer}
  end

  defp remember_workload_members(%{workload_identity: identity} = state) when is_map(identity) do
    case BashExecutor.workload_group_status(identity, state.root_exited) do
      {:alive, observed} ->
        if observed != identity,
          do: ProcessStore.update_workload_identity(state.process_id, observed, state.root_exited)

        %{state | workload_identity: observed}

      {:unknown, %{ownership_lost: true} = observed} ->
        ProcessStore.update_workload_identity(state.process_id, observed, state.root_exited)
        ProcessStore.mark_unknown(state.process_id)
        %{state | status: :lost, workload_identity: observed}

      _ ->
        state
    end
  end

  defp remember_workload_members(state), do: state

  defp request_workload_stop(state, signal, reason) do
    case BashExecutor.signal_workload_group(state.workload_identity, signal, state.root_exited) do
      {:ok, identity} ->
        ProcessStore.update_workload_identity(state.process_id, identity, state.root_exited)
        status = if state.root_exited, do: :lost, else: :killing
        {:ok, %{state | status: status, termination_reason: reason, workload_identity: identity}}

      {:terminated, identity} ->
        state = %{state | termination_reason: reason, workload_identity: identity}

        if state.root_exited do
          case owned_workload_status(state) do
            :terminated ->
              {:ok, finish_workload(state)}

            {_, observed} ->
              {{:error, {:outcome_unknown, state.process_id}}, retain_workload(state, observed)}
          end
        else
          {:ok, state}
        end

      {:error, _reason, identity} ->
        ProcessStore.mark_unknown(state.process_id)
        ProcessStore.update_workload_identity(state.process_id, identity, state.root_exited)

        {{:error, {:outcome_unknown, state.process_id}},
         %{state | status: :lost, termination_reason: reason, workload_identity: identity}}
    end
  end

  defp finish_workload(state) do
    state = finalize_output(state)
    if state.workload_timer, do: Process.cancel_timer(state.workload_timer)

    {status, exit_code} =
      cond do
        state.termination_reason == :canceled -> {:killed, nil}
        state.termination_reason == :timeout -> {:error, nil}
        state.root_exit_code == 0 -> {:completed, 0}
        true -> {:error, state.root_exit_code}
      end

    cond do
      state.termination_reason == :timeout -> ProcessStore.mark_error(state.process_id, :timeout)
      status == :completed -> ProcessStore.mark_completed(state.process_id, exit_code)
      status == :killed -> ProcessStore.mark_killed(state.process_id)
      true -> ProcessStore.mark_error(state.process_id, %{exit_code: exit_code, status: status})
    end

    ProcessStore.confirm_termination(state.process_id)

    if state.on_exit do
      spawn(fn ->
        state.on_exit.(%{process_id: state.process_id, status: status, exit_code: exit_code})
      end)
    end

    Process.send_after(self(), :stop_after_exit, 5_000)

    %{
      state
      | status: status,
        exit_code: exit_code,
        completed_at: System.system_time(:second),
        workload_timer: nil
    }
  end

  defp start_port(command, cwd, env, backend) do
    {shell_path, shell_args} = get_shell_config()

    {executable, args, stderr_to_stdout?} =
      case backend do
        :local_pty ->
          wrapped_command = command_with_cwd(command, cwd)

          {System.find_executable("script") || "script", ["-qfec", wrapped_command, "/dev/null"],
           false}

        :docker ->
          {Docker.docker_path() || "docker", docker_args(command, cwd, env), true}

        :ssh ->
          {Ssh.ssh_path() || "ssh", Ssh.args(command, env), true}

        _ ->
          wrapped_command = command_with_cwd(command, cwd)

          {shell_path, shell_args ++ [wrapped_command], true}
      end

    port_opts =
      [
        :stream,
        :binary,
        :exit_status,
        :use_stdio,
        {:args, args}
      ]
      |> maybe_stderr_to_stdout(stderr_to_stdout?)

    env_list =
      Enum.map(env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    port_opts =
      if backend not in [:docker, :ssh] and env_list != [] do
        [{:env, env_list} | port_opts]
      else
        port_opts
      end

    # A FIFO permits stdin EOF without closing stdout or losing exit status.
    # Opening its writer after activation synchronizes with the shell's reader,
    # so an immediate EOF cannot race the reader's open.
    stdin_path =
      Path.join(
        System.tmp_dir!(),
        "lemon-stdin-#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
      )

    {_, 0} = System.cmd("mkfifo", ["-m", "600", stdin_path])

    try do
      true = Path.type(executable) == :absolute

      gated_args = [
        "-c",
        "( IFS= read -r lemon_gate ) && lemon_stdin=$1 && shift && exec \"$@\" < \"$lemon_stdin\"",
        "lemon-process",
        stdin_path,
        executable | args
      ]

      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          List.keyreplace(port_opts, :args, 0, {:args, gated_args})
        )

      {port, stdin_path}
    rescue
      exception ->
        File.rm(stdin_path)
        reraise exception, __STACKTRACE__
    end
  end

  defp maybe_stderr_to_stdout(port_opts, true), do: [:stderr_to_stdout | port_opts]
  defp maybe_stderr_to_stdout(port_opts, false), do: port_opts

  defp docker_args(command, cwd, env) do
    workspace = docker_workspace(cwd)

    [
      "run",
      "--rm",
      "-i",
      "--pull",
      "never",
      "--network",
      Docker.network(),
      "--memory",
      Docker.memory(),
      "--cpus",
      Docker.cpus(),
      "--pids-limit",
      Docker.pids_limit(),
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--workdir",
      "/workspace",
      "--volume",
      "#{workspace}:/workspace"
    ] ++
      docker_read_only_args() ++
      docker_tmpfs_args() ++
      docker_env_args(env) ++
      [
        Docker.image(),
        "/bin/sh",
        "-lc",
        command
      ]
  end

  defp docker_workspace(nil), do: File.cwd!()
  defp docker_workspace(""), do: File.cwd!()
  defp docker_workspace(cwd), do: Path.expand(cwd)

  defp docker_read_only_args do
    if Docker.read_only_rootfs?(), do: ["--read-only"], else: []
  end

  defp docker_tmpfs_args do
    Enum.flat_map(Docker.tmpfs_mounts(), fn mount ->
      ["--tmpfs", mount]
    end)
  end

  defp docker_env_args(env) do
    Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end)
  end

  defp command_with_cwd(command, nil), do: command
  defp command_with_cwd(command, ""), do: command
  defp command_with_cwd(command, cwd), do: "cd #{shell_escape(cwd)} && #{command}"

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp output_limits(opts) do
    configured = Application.get_env(:coding_agent, :process_output, [])

    limits = [
      {:max_log_lines, Keyword.get(opts, :max_log_lines, @default_max_log_lines)}
      | Enum.map(@output_limit_defaults, fn {key, default} ->
          {key, Keyword.get_lazy(opts, key, fn -> configured_limit(configured, key, default) end)}
        end)
    ]

    case Enum.find(limits, fn {_key, value} -> not (is_integer(value) and value > 0) end) do
      nil -> {:ok, Map.new(limits)}
      {key, _value} -> {:error, {:invalid_process_output_limit, key}}
    end
  end

  defp configured_limit(configured, key, default) when is_list(configured),
    do: if(Keyword.keyword?(configured), do: Keyword.get(configured, key, default), else: nil)

  defp configured_limit(configured, key, default) when is_map(configured),
    do: Map.get(configured, key, default)

  defp configured_limit(_configured, _key, _default), do: nil

  defp failed_start(process_id, opts, output_path, output_file) do
    File.close(output_file)
    claimed? = is_binary(Keyword.get(opts, :launch_fingerprint))
    removed = File.rm(output_path) in [:ok, {:error, :enoent}]

    try do
      # No Port was opened. Release lifetime capacity independently of capture
      # cleanup; an unremovable artifact must keep its separate disk charge.
      if claimed?, do: ProcessStore.confirm_termination(process_id, :startup_failed)

      if removed do
        ProcessStore.put_output(process_id, %{
          artifact_capacity: 0,
          artifact_bytes: 0,
          finalized: true
        })

        ProcessStore.delete(process_id)
      else
        case ProcessStore.get(process_id) do
          {:ok, record, _logs} ->
            output = Map.put(Map.get(record, :output) || %{}, :finalized, true)
            ProcessStore.put_output(process_id, output)

          _ ->
            :ok
        end

        if not claimed?, do: ProcessStore.mark_error(process_id, :process_start_failed)
      end
    catch
      # Closed capture cleanup happens first. Unavailable accounting cannot
      # erase a durable reservation or authorize a fresh logical launch.
      :exit, _reason -> throw(:process_start_failed)
    end

    throw(if claimed?, do: :confirmed_startup_failure, else: :process_start_failed)
  end

  defp open_output_file do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon-process-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}.log"
      )

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, path, file}

          {:error, reason} ->
            File.close(file)
            File.rm(path)
            {:error, {:output_file_unavailable, reason}}
        end

      {:error, reason} ->
        {:error, {:output_file_unavailable, reason}}
    end
  end

  # The artifact keeps the head of the output up to the reserved capacity; the
  # remaining bytes are only counted. A write failure closes the file for good.
  defp write_artifact(%{output_file: nil} = state, data),
    do: discard_artifact_bytes(state, byte_size(data))

  defp write_artifact(state, data) do
    kept = min(state.artifact_capacity - state.artifact_bytes, byte_size(data))

    case write_output_file(state.output_file, binary_part(data, 0, kept)) do
      :ok ->
        state =
          %{state | artifact_bytes: state.artifact_bytes + kept}
          |> discard_artifact_bytes(byte_size(data) - kept)

        if state.artifact_bytes >= state.artifact_capacity,
          do: close_output_file(state),
          else: state

      {:error, reason} ->
        state = close_output_file(state)

        # A failed write can have written a prefix. Stat the closed artifact
        # rather than claiming the entire attempted write was discarded.
        {bytes, unknown?} =
          case File.stat(state.full_output_path) do
            {:ok, %{type: :regular, size: size}} -> {size, false}
            {:error, :enoent} -> {0, false}
            _ -> {state.artifact_bytes, true}
          end

        %{
          state
          | artifact_bytes: bytes,
            artifact_discarded_bytes: state.received_bytes - bytes,
            artifact_error: artifact_error(reason),
            artifact_size_unknown: unknown?
        }
    end
  end

  # `IO.binwrite/2` raises on failure; `:file.write/2` returns the reason.
  defp write_output_file(file, data) do
    :file.write(file, data)
  catch
    :exit, _reason -> {:error, :terminated}
  end

  # Diagnostics expose only fixed classifications, never arbitrary error terms.
  defp artifact_error(reason)
       when reason in [:enospc, :edquot, :eio, :eacces, :ebadf, :terminated],
       do: reason

  defp artifact_error(_reason), do: :write_failed

  defp discard_artifact_bytes(state, 0), do: state

  defp discard_artifact_bytes(state, bytes),
    do: %{state | artifact_discarded_bytes: state.artifact_discarded_bytes + bytes}

  defp close_output_file(%{output_file: nil} = state), do: state

  defp close_output_file(state) do
    try do
      File.close(state.output_file)
    catch
      :exit, _reason -> :ok
    end

    %{state | output_file: nil}
  end

  # Only inspect a segment-sized window. Neither a newline flood nor one huge
  # binary creates a chunk-sized concatenation, line list or retained subbinary.
  defp consume_output(state, data, offset) when offset == byte_size(data), do: state

  defp consume_output(state, data, offset) do
    room = state.max_line_bytes - byte_size(state.partial_line)

    if room == 0 do
      if :binary.at(data, offset) == ?\n do
        state |> finish_line(true) |> consume_output(data, offset + 1)
      else
        state |> finish_line(false) |> consume_output(data, offset)
      end
    else
      size = min(room, byte_size(data) - offset)

      case :binary.match(data, "\n", scope: {offset, size}) do
        {newline, 1} ->
          state
          |> extend_partial(data, offset, newline - offset)
          |> finish_line(true)
          |> consume_output(data, newline + 1)

        :nomatch ->
          state
          |> extend_partial(data, offset, size)
          |> consume_output(data, offset + size)
      end
    end
  end

  defp extend_partial(state, _data, _offset, 0), do: state

  defp extend_partial(state, data, offset, size) do
    budget = state.max_retained_bytes - byte_size(state.partial_line) - size

    {queue, bytes, count} =
      evict({state.log_buffer, state.log_bytes, state.log_count}, budget, state.max_log_lines)

    # Evict before allocating the bounded concatenation. Copy even a single
    # slice so a small partial line never pins the entire received binary.
    slice = binary_part(data, offset, size)

    partial =
      if state.partial_line == "",
        do: :binary.copy(slice),
        else: :erlang.iolist_to_binary([state.partial_line, slice])

    %{state | log_buffer: queue, log_bytes: bytes, log_count: count, partial_line: partial}
  end

  defp finish_line(state, newline?) do
    line = state.partial_line
    cost = byte_size(line) + if(newline?, do: 1, else: 0)
    state = %{state | partial_line: ""}

    # A one-byte budget cannot hold both a one-byte segment and its newline.
    # Charge/emit them separately, preserving the newest byte without exceeding it.
    if cost > state.max_retained_bytes do
      state |> retain_entry(line, byte_size(line)) |> retain_entry("", 1)
    else
      retain_entry(state, line, cost)
    end
  end

  defp retain_entry(state, line, cost) do
    {queue, bytes, count} =
      evict(
        {state.log_buffer, state.log_bytes, state.log_count},
        state.max_retained_bytes - cost,
        state.max_log_lines - 1
      )

    %{
      state
      | log_buffer: :queue.in({line, cost}, queue),
        log_bytes: bytes + cost,
        log_count: count + 1,
        total_lines: state.total_lines + 1
    }
  end

  defp sync_output(state) do
    ProcessStore.append_logs(
      state.process_id,
      Enum.map(:queue.to_list(state.log_buffer), &elem(&1, 0)),
      keep: state.log_count,
      total_lines: state.total_lines,
      output: output_stats(state)
    )

    state
  end

  defp evict({queue, bytes, count}, budget, max_lines) when bytes > budget or count > max_lines do
    {{:value, {_line, cost}}, queue} = :queue.out(queue)
    evict({queue, bytes - cost, count - 1}, budget, max_lines)
  end

  defp evict(ring, _budget, _max_lines), do: ring

  defp flush_partial_line(%{partial_line: ""} = state), do: state

  defp flush_partial_line(state), do: finish_line(state, false)

  defp finalize_output(%{output_finalized: true} = state), do: state

  # Runs once, when the process exits (or the session stops first): the
  # partial line joins the tail, the artifact is closed and its reservation
  # shrinks to the bytes actually written, and final statistics are stored.
  defp finalize_output(state) do
    state = state |> flush_partial_line() |> close_output_file() |> sync_output()

    capacity =
      if state.artifact_size_unknown, do: state.artifact_capacity, else: state.artifact_bytes

    state = %{state | artifact_capacity: capacity, output_finalized: true}
    ProcessStore.put_output(state.process_id, output_stats(state))
    state
  end

  defp output_stats(state) do
    retained = state.log_bytes + byte_size(state.partial_line)

    %{
      received_bytes: state.received_bytes,
      retained_bytes: retained,
      discarded_bytes: state.received_bytes - retained,
      max_retained_bytes: state.max_retained_bytes,
      artifact_bytes: state.artifact_bytes,
      artifact_capacity: state.artifact_capacity,
      artifact_discarded_bytes:
        if(state.artifact_size_unknown, do: nil, else: state.artifact_discarded_bytes),
      artifact_truncated: state.artifact_discarded_bytes > 0 or state.artifact_error != nil,
      artifact_error: state.artifact_error,
      finalized: state.output_finalized,
      artifact_size_unknown: state.artifact_size_unknown,
      artifact_reclaimed: false
    }
  end

  defp get_shell_config do
    case :os.type() do
      {:unix, _} ->
        cond do
          File.exists?("/bin/bash") -> {"/bin/bash", ["-c"]}
          File.exists?("/bin/sh") -> {"/bin/sh", ["-c"]}
          true -> {System.find_executable("sh") || "/bin/sh", ["-c"]}
        end

      {:win32, _} ->
        git_bash_paths = [
          "C:\\Program Files\\Git\\bin\\bash.exe",
          "C:\\Program Files (x86)\\Git\\bin\\bash.exe"
        ]

        case Enum.find(git_bash_paths, &File.exists?/1) do
          nil -> {System.find_executable("cmd.exe") || "cmd.exe", ["/C"]}
          path -> {path, ["-c"]}
        end
    end
  end

  defp shell_escape(path) do
    "'" <> String.replace(path, "'", "'\"'\"'") <> "'"
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
