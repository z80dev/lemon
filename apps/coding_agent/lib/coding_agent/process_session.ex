defmodule CodingAgent.ProcessSession do
  @moduledoc """
  GenServer that manages a single background process via a Port.

  Features:
  - Rolling log buffer (bounded), split on complete lines (a partial line is
    held until its newline arrives or the process exits)
  - Incremental reads (`read_output/1`) with a per-process read cursor
  - Stdin writing support
  - Process kill support
  - Exit status tracking
  - Integration with ProcessStore for persistence

  The session monitors the OS process via a Port and maintains
  a bounded ring buffer of output lines. Complete output is archived in a
  private temporary file, retrievable even after unread lines leave the ring.
  """

  use GenServer

  alias CodingAgent.{BashExecutor, ProcessStore}
  alias LemonCore.TerminalBackends

  @default_max_log_lines 1000
  # A line longer than this (for example `\r` progress output with no
  # newline) is flushed to the log as-is instead of growing without bound.
  @max_partial_line_bytes 65_536

  # Client API

  @doc """
  Start a new process session.

  Options:
  - :command - The command to execute (required)
  - :cwd - Working directory (default: current directory)
  - :env - Environment variables map (default: %{})
  - :process_id - Pre-generated process ID (optional)
  - :max_log_lines - Maximum log lines to keep (default: 1000)
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
  def read_output(process_id) do
    GenServer.call(via_tuple(process_id), :read_output, 5_000)
  end

  @doc """
  Write to the process's stdin.
  """
  def write_stdin(process_id, data) do
    GenServer.call(via_tuple(process_id), {:write_stdin, data}, 5_000)
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
  """
  def stop(process_id) do
    GenServer.stop(via_tuple(process_id), :normal)
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
    _, _ -> {:stop, :launch_failed}
  end

  defp init_process(process_id, opts) do
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    env = Keyword.get(opts, :env, %{})
    backend = Keyword.get(opts, :backend, :local)
    terminal_capabilities = TerminalBackends.capabilities(backend)
    max_log_lines = Keyword.get(opts, :max_log_lines, @default_max_log_lines)
    timeout_ms = Keyword.get(opts, :timeout_ms)
    on_exit = Keyword.get(opts, :on_exit)
    owner = Keyword.get(opts, :owner)

    output_path =
      Path.join(
        System.tmp_dir!(),
        "lemon-process-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}.log"
      )

    output_file = prepare_output(process_id, output_path)

    # Create the process entry in the store
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

    # Start the OS process via Port
    port =
      protected_start_port(
        process_id,
        command,
        cwd,
        env,
        backend,
        Keyword.get(opts, :before_start),
        output_file,
        output_path
      )

    os_pid = get_os_pid(port)

    # Bind the owned group durably before the stdin gate allows user execution.
    workload_identity = activate_workload(process_id, port, os_pid, output_file)
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

    result = %{
      process_id: state.process_id,
      status: state.status,
      exit_code: state.exit_code,
      os_pid: state.os_pid,
      logs: logs,
      command: state.command,
      cwd: state.cwd,
      backend: state.backend,
      terminal_capabilities: state.terminal_capabilities,
      max_log_lines: state.max_log_lines,
      log_line_count: state.log_count,
      started_at: state.started_at,
      completed_at: state.completed_at,
      restarted_from: state.restarted_from,
      restart_generation: state.restart_generation
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call(:read_output, _from, state) do
    first_buffered = state.total_lines - :queue.len(state.log_buffer)
    start = max(state.read_cursor, first_buffered)

    lines =
      state.log_buffer
      |> :queue.to_list()
      |> Enum.drop(start - first_buffered)

    ProcessStore.put_read_cursor(state.process_id, state.total_lines)

    result = %{
      process_id: state.process_id,
      status: state.status,
      exit_code: state.exit_code,
      command: state.command,
      owner: state.owner,
      lines: lines,
      full_output_path: state.full_output_path,
      dropped_lines: start - state.read_cursor
    }

    {:reply, {:ok, result}, %{state | read_cursor: state.total_lines}}
  end

  def handle_call({:write_stdin, data}, _from, state) do
    if state.status == :running do
      # Stdin may make the root exit immediately. Retain any verified surviving
      # members before forwarding bytes, while root ownership still binds them.
      state = remember_workload_members(state)

      if state.status == :running do
        try do
          Port.command(state.port, data)
          {:reply, :ok, state}
        rescue
          e -> {:reply, {:error, e}, state}
        end
      else
        {:reply, {:error, {:outcome_unknown, state.process_id}}, state}
      end
    else
      {:reply, {:error, :process_not_running}, state}
    end
  end

  def handle_call({:kill, signal}, _from, state) do
    if state.status in [:running, :killing, :lost] and state.os_pid do
      {reply, state} = request_workload_stop(state, signal, :canceled)
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
    :ok = IO.binwrite(state.output_file, data)
    parts = String.split(state.partial_line <> data, "\n")
    {lines, [partial]} = Enum.split(parts, -1)

    {lines, partial} =
      if byte_size(partial) > @max_partial_line_bytes,
        do: {lines ++ [partial], ""},
        else: {lines, partial}

    {:noreply, state |> append_lines(lines) |> Map.put(:partial_line, partial)}
  end

  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, root_exited: false} = state
      ) do
    state = flush_partial_line(state)
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
    File.close(state.output_file)
    # Ensure port is closed
    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # Private Functions

  defp via_tuple(process_id) do
    {:via, Registry, {CodingAgent.ProcessRegistry, process_id}}
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

  defp prepare_output(process_id, path) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        case File.chmod(path, 0o600) do
          :ok ->
            file

          _ ->
            File.close(file)
            File.rm(path)
            ProcessStore.confirm_termination(process_id, :startup_failed)
            throw(:confirmed_startup_failure)
        end

      _ ->
        ProcessStore.confirm_termination(process_id, :startup_failed)
        throw(:confirmed_startup_failure)
    end
  end

  defp protected_start_port(process_id, command, cwd, env, backend, before_start, file, path) do
    if before_start, do: before_start.()
    start_port(command, cwd, env, backend)
  rescue
    _ -> confirmed_start_failure(process_id, file, path)
  catch
    :exit, _ -> confirmed_start_failure(process_id, file, path)
  end

  defp confirmed_start_failure(process_id, file, path) do
    File.close(file)
    File.rm(path)
    ProcessStore.confirm_termination(process_id, :startup_failed)
    throw(:confirmed_startup_failure)
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

      {:terminated, _identity} ->
        state = %{state | termination_reason: reason}
        {:ok, if(state.root_exited, do: finish_workload(state), else: state)}

      {:error, _reason, identity} ->
        ProcessStore.mark_unknown(state.process_id)
        ProcessStore.update_workload_identity(state.process_id, identity, state.root_exited)

        {{:error, {:outcome_unknown, state.process_id}},
         %{state | status: :lost, termination_reason: reason, workload_identity: identity}}
    end
  end

  defp finish_workload(state) do
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
          {LemonCore.TerminalBackends.Docker.docker_path() || "docker",
           docker_args(command, cwd, env), true}

        :ssh ->
          {LemonCore.TerminalBackends.Ssh.ssh_path() || "ssh",
           LemonCore.TerminalBackends.Ssh.args(command, env), true}

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

    case :os.type() do
      {:unix, _} ->
        # Noninteractive POSIX sh does not source the command's BASH_ENV. The
        # subshell consumes only our newline; exec preserves the target shell,
        # env, cwd, argv and subsequent stdin without a new PATH lookup.
        true = Path.type(executable) == :absolute

        gated_args =
          ["-c", "( IFS= read -r ) && exec \"$@\"", "lemon-process", executable | args]

        Port.open(
          {:spawn_executable, "/bin/sh"},
          List.keyreplace(port_opts, :args, 0, {:args, gated_args})
        )

      _ ->
        Port.open({:spawn_executable, executable}, port_opts)
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
      LemonCore.TerminalBackends.Docker.network(),
      "--memory",
      LemonCore.TerminalBackends.Docker.memory(),
      "--cpus",
      LemonCore.TerminalBackends.Docker.cpus(),
      "--pids-limit",
      LemonCore.TerminalBackends.Docker.pids_limit(),
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
        LemonCore.TerminalBackends.Docker.image(),
        "/bin/sh",
        "-lc",
        command
      ]
  end

  defp docker_workspace(nil), do: File.cwd!()
  defp docker_workspace(""), do: File.cwd!()
  defp docker_workspace(cwd), do: Path.expand(cwd)

  defp docker_read_only_args do
    if LemonCore.TerminalBackends.Docker.read_only_rootfs?(), do: ["--read-only"], else: []
  end

  defp docker_tmpfs_args do
    Enum.flat_map(LemonCore.TerminalBackends.Docker.tmpfs_mounts(), fn mount ->
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

  defp append_lines(state, []), do: state

  defp append_lines(state, lines) do
    ProcessStore.append_logs(state.process_id, lines)

    buffer =
      lines
      |> Enum.reduce(state.log_buffer, &:queue.in/2)
      |> trim_log_buffer(state.max_log_lines)

    %{
      state
      | log_buffer: buffer,
        log_count: :queue.len(buffer),
        total_lines: state.total_lines + length(lines)
    }
  end

  defp flush_partial_line(%{partial_line: ""} = state), do: state

  defp flush_partial_line(state) do
    append_lines(%{state | partial_line: ""}, [state.partial_line])
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

  defp trim_log_buffer(buffer, max_log_lines)
       when is_integer(max_log_lines) and max_log_lines >= 0 do
    if :queue.len(buffer) > max_log_lines do
      {{:value, _}, buffer} = :queue.out(buffer)
      trim_log_buffer(buffer, max_log_lines)
    else
      buffer
    end
  end

  defp trim_log_buffer(buffer, _max_log_lines), do: buffer

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
