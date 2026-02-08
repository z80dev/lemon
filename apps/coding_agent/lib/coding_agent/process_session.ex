defmodule CodingAgent.ProcessSession do
  @moduledoc """
  GenServer that manages a single background process via a Port.

  Features:
  - Rolling log buffer (bounded)
  - Stdin writing support
  - Process kill support
  - Exit status tracking
  - Integration with ProcessStore for persistence

  The session monitors the OS process via a Port and maintains
  a bounded ring buffer of output lines.
  """

  use GenServer
  require Logger

  alias CodingAgent.ProcessStore

  @default_max_log_lines 1000

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
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    env = Keyword.get(opts, :env, %{})
    max_log_lines = Keyword.get(opts, :max_log_lines, @default_max_log_lines)
    timeout_ms = Keyword.get(opts, :timeout_ms)
    on_exit = Keyword.get(opts, :on_exit)

    # Create the process entry in the store
    ProcessStore.new_process(%{
      id: process_id,
      command: command,
      cwd: cwd,
      env: env,
      status: :queued
    })

    # Start the OS process via Port
    port = start_port(command, cwd, env)
    os_pid = get_os_pid(port)

    # Mark as running in the store
    ProcessStore.mark_running(process_id, os_pid)

    # Set up timeout if specified
    timeout_ref = if timeout_ms, do: Process.send_after(self(), :timeout, timeout_ms)

    state = %{
      process_id: process_id,
      port: port,
      os_pid: os_pid,
      command: command,
      cwd: cwd,
      env: env,
      status: :running,
      exit_code: nil,
      max_log_lines: max_log_lines,
      log_buffer: :queue.new(),
      log_count: 0,
      timeout_ref: timeout_ref,
      on_exit: on_exit,
      started_at: System.system_time(:second)
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
      cwd: state.cwd
    }

    {:reply, {:ok, result}, state}
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
      state = %{state | status: :killed}
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
    lines = String.split(data, "\n", trim: false)

    # Append each line to the log buffer
    Enum.each(lines, fn line ->
      ProcessStore.append_log(state.process_id, line)
    end)

    # Update local buffer
    new_buffer =
      Enum.reduce(lines, state.log_buffer, fn line, buf ->
        buf = :queue.in(line, buf)

        if state.log_count >= state.max_log_lines do
          {{:value, _}, buf} = :queue.out(buf)
          buf
        else
          buf
        end
      end)

    new_count = min(state.log_count + length(lines), state.max_log_lines)

    {:noreply, %{state | log_buffer: new_buffer, log_count: new_count}}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
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

    new_state = %{state | status: status, exit_code: exit_code}

    # Stop the GenServer after a short delay to allow final polling
    Process.send_after(self(), :stop_after_exit, 5_000)

    {:noreply, new_state}
  end

  def handle_info(:timeout, state) do
    if state.status == :running do
      do_kill(state.os_pid, :sigkill)
      ProcessStore.mark_error(state.process_id, :timeout)
      {:noreply, %{state | status: :error, timeout_ref: nil}}
    else
      {:noreply, state}
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

  defp start_port(command, cwd, env) do
    {shell_path, shell_args} = get_shell_config()

    # Build environment variables
    env_list =
      Enum.map(env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    # Wrap command with cd
    wrapped_command =
      if cwd && cwd != "" do
        "cd #{shell_escape(cwd)} && #{command}"
      else
        command
      end

    port_opts = [
      :stream,
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, shell_args ++ [wrapped_command]}
    ]

    # Add environment if specified
    port_opts =
      if env_list != [] do
        [{:env, env_list} | port_opts]
      else
        port_opts
      end

    Port.open({:spawn_executable, shell_path}, port_opts)
  end

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp do_kill(os_pid, :sigterm) do
    case :os.type() do
      {:unix, _} ->
        try do
          :os.cmd(~c"kill -15 #{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

      {:win32, _} ->
        try do
          :os.cmd(~c"taskkill /PID #{os_pid}")
        catch
          _, _ -> :ok
        end
    end

    :ok
  end

  defp do_kill(os_pid, :sigkill) do
    case :os.type() do
      {:unix, _} ->
        # Try process group first, then single process
        try do
          :os.cmd(~c"kill -9 -#{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

        try do
          :os.cmd(~c"kill -9 #{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

      {:win32, _} ->
        try do
          :os.cmd(~c"taskkill /F /T /PID #{os_pid}")
        catch
          _, _ -> :ok
        end
    end

    :ok
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
