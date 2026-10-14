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
        case ProcessStore.claim_launch(process_id, Keyword.get(opts, :owner), fingerprint) do
          :ok -> init_process(process_id, opts)
          {:error, reason} -> {:stop, reason}
        end
    end
  rescue
    _ -> {:stop, :launch_failed}
  catch
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

    {:ok, output_file} = File.open(output_path, [:write, :binary, :exclusive])
    File.chmod!(output_path, 0o600)

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
      launch_classification: :outcome_unknown
    })

    # Start the OS process via Port
    port = start_port(command, cwd, env, backend)
    os_pid = get_os_pid(port)

    # Mark as running in the store
    ProcessStore.mark_running(process_id, os_pid)
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
      on_exit: on_exit,
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
      try do
        Port.command(state.port, data)
        {:reply, :ok, state}
      rescue
        e -> {:reply, {:error, e}, state}
      end
    else
      {:reply, {:error, :process_not_running}, state}
    end
  end

  def handle_call({:kill, signal}, _from, state) do
    if state.status == :running and state.os_pid do
      do_kill(state.os_pid, signal)
      state = %{state | status: :killed, completed_at: System.system_time(:second)}
      ProcessStore.mark_killed(state.process_id)
      {:reply, :ok, state}
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

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    state = flush_partial_line(state)

    # Cancel timeout if still pending
    if state.timeout_ref do
      Process.cancel_timer(state.timeout_ref)
    end

    # Update status based on exit code
    {status, exit_code} =
      if state.status == :killed do
        {:killed, nil}
      else
        if exit_code == 0 do
          {:completed, exit_code}
        else
          {:error, exit_code}
        end
      end

    # Update store. Killed processes should remain `:killed` (not overwritten to `:error`).
    cond do
      status == :completed ->
        ProcessStore.mark_completed(state.process_id, exit_code)

      status == :killed ->
        ProcessStore.mark_killed(state.process_id)

      true ->
        ProcessStore.mark_error(state.process_id, %{exit_code: exit_code, status: status})
    end

    # Call exit callback if provided
    if state.on_exit do
      spawn(fn ->
        state.on_exit.(%{
          process_id: state.process_id,
          status: status,
          exit_code: exit_code
        })
      end)
    end

    new_state = %{
      state
      | status: status,
        exit_code: exit_code,
        completed_at: System.system_time(:second)
    }

    # Stop the GenServer after a short delay to allow final polling
    Process.send_after(self(), :stop_after_exit, 5_000)

    {:noreply, new_state}
  end

  def handle_info(:timeout, state) do
    if state.status == :running do
      do_kill(state.os_pid, :sigkill)
      ProcessStore.mark_error(state.process_id, :timeout)

      {:noreply,
       %{state | status: :error, timeout_ref: nil, completed_at: System.system_time(:second)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state)
      when is_reference(ref) do
    # The owning session is gone; nothing can read or stop this process any more.
    if state.status == :running do
      do_kill(state.os_pid, :sigkill)
      ProcessStore.mark_killed(state.process_id)

      {:noreply,
       %{state | status: :killed, owner_monitor: nil, completed_at: System.system_time(:second)}}
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

    Port.open({:spawn_executable, executable}, port_opts)
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

  defp do_kill(os_pid, signal) when is_integer(os_pid) do
    BashExecutor.kill_process_tree(os_pid, signal)
  end

  defp do_kill(_os_pid, _signal), do: :ok

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
