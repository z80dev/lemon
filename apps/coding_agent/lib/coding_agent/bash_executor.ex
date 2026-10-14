defmodule CodingAgent.BashExecutor do
  @moduledoc """
  Handles streaming shell command execution with output sanitization,
  truncation, and abort signal support. A Port-owning guardian kills shell
  descendants if the tool worker exits, including forced cancellation/crashes.
  UTF-8 is decoded across stream chunks; invalid bytes do not discard later
  output. Large output is archived privately, and only its bounded tail is
  read back into memory when execution completes.
  """

  alias LemonAgent.AbortSignal

  defmodule Result do
    @moduledoc """
    Result struct for bash command execution.
    """
    defstruct [
      :output,
      :exit_code,
      :cancelled,
      :truncated,
      :full_output_path,
      timed_out: false,
      terminal_id: nil,
      client_output_truncated: false
    ]

    @type t :: %__MODULE__{
            output: String.t() | nil,
            exit_code: integer() | nil,
            cancelled: boolean(),
            truncated: boolean(),
            full_output_path: String.t() | nil,
            timed_out: boolean(),
            terminal_id: String.t() | nil,
            client_output_truncated: boolean()
          }
  end

  @default_max_bytes 50_000
  # Tool calls should not time out by default. Callers can pass `timeout: ms`
  # explicitly (or abort via AbortSignal).
  @default_timeout :infinity
  @default_max_lines 2000

  # ANSI escape sequence pattern
  @ansi_regex ~r/\e\[[0-9;]*[a-zA-Z]/

  @doc """
  Execute a shell command with streaming output support.

  ## Options

    * `:on_chunk` - Callback function `fn(chunk :: String.t()) -> :ok` called for each output chunk
    * `:signal` - Abort signal reference (check with `AbortSignal.aborted?/1`)
    * `:timeout` - Timeout in milliseconds, or `:infinity` for no timeout (default: #{@default_timeout})
    * `:max_bytes` - Maximum output bytes before truncation (default: #{@default_max_bytes})
    * `:pty` - When `true`, run the command in a pseudo-terminal (default: `false`)
    * `:env` - Extra environment variables (`%{name => value}`) layered over the
      inherited environment (default: `%{}`)

  ## Returns

    * `{:ok, Result.t()}` on success (including non-zero exit codes)
    * `{:error, term()}` on execution failure

  """
  @spec execute(command :: String.t(), cwd :: String.t(), opts :: keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def execute(command, cwd, opts \\ []) do
    on_chunk = Keyword.get(opts, :on_chunk)
    signal = Keyword.get(opts, :signal)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    use_pty = Keyword.get(opts, :pty, false)
    env = Keyword.get(opts, :env, %{})

    # Threshold for writing to temp file (2x max_bytes)
    temp_file_threshold = max_bytes * 2

    {shell_path, shell_args} = get_shell_config()

    command = wrap_command_with_cwd(command, cwd)

    {spawn_path, spawn_args} =
      if use_pty do
        wrap_with_pty(shell_path, shell_args, command)
      else
        {shell_path, shell_args ++ [command]}
      end

    port_opts =
      [
        :stream,
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, spawn_args}
      ] ++ port_env(env)

    try do
      {port, os_pid, guardian} = start_guarded_port(spawn_path, port_opts)

      try do
        # Set up timeout (optional). `Process.send_after/3` requires an integer timeout.
        timeout_ref =
          case timeout do
            :infinity ->
              nil

            nil ->
              nil

            ms when is_integer(ms) and ms > 0 ->
              Process.send_after(self(), {:timeout, port}, ms)

            _ ->
              nil
          end

        state = %{
          port: port,
          os_pid: os_pid,
          signal: signal,
          on_chunk: on_chunk,
          max_bytes: max_bytes,
          temp_file_threshold: temp_file_threshold,
          output_buffer: [],
          utf8_tail: "",
          total_bytes: 0,
          temp_file: nil,
          temp_file_path: nil,
          cancelled: false,
          exit_code: nil,
          timeout_ref: timeout_ref
        }

        result = collect_output(state)

        # Cancel timeout if still pending
        if timeout_ref, do: Process.cancel_timer(timeout_ref)

        {:ok, result}
      after
        send(guardian, :finish)
      end
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # The guardian, not the killable tool worker, owns the Port. If the worker
  # disappears, the shell is still alive while we enumerate/kill descendants.
  # Closing a worker-owned Port first would orphan them before we could find them.
  defp start_guarded_port(path, opts) do
    caller = self()
    ref = make_ref()

    guardian =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        monitor = Process.monitor(caller)

        try do
          port = Port.open({:spawn_executable, path}, opts)
          os_pid = get_os_pid(port)
          send(caller, {ref, :started, port, os_pid})
          relay_port(port, os_pid, caller, monitor)
        rescue
          error -> send(caller, {ref, :error, error})
        end
      end)

    receive do
      {^ref, :started, port, os_pid} -> {port, os_pid, guardian}
      {^ref, :error, error} -> raise error
    end
  end

  defp relay_port(port, os_pid, caller, monitor) do
    receive do
      {^port, {:data, _data}} = event ->
        send(caller, event)
        relay_port(port, os_pid, caller, monitor)

      {^port, {:exit_status, _code}} = event ->
        send(caller, event)
        Process.demonitor(monitor, [:flush])

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        if Port.info(port) && os_pid, do: kill_process_tree(os_pid)
        safe_close_port(port)

      :finish ->
        Process.demonitor(monitor, [:flush])
        if Port.info(port) && os_pid, do: kill_process_tree(os_pid)
        safe_close_port(port)

      {:EXIT, ^port, reason} ->
        Process.demonitor(monitor, [:flush])
        if reason != :normal, do: send(caller, {port, {:exit_status, 1}})
    end
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end
  end

  defp collect_output(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        # Buffer the chunk before honoring an abort so output that raced the
        # abort is still part of the partial result.
        state = buffer_chunk(state, data)

        if state.signal && AbortSignal.aborted?(state.signal) do
          handle_abort(state)
        else
          collect_output(state)
        end

      {port, {:exit_status, status}} when port == state.port ->
        finalize_result(%{state | exit_code: status})

      {:timeout, port} when port == state.port ->
        handle_timeout(state)

      _other ->
        collect_output(state)
    after
      100 ->
        # Periodic check for abort signal
        if state.signal && AbortSignal.aborted?(state.signal) do
          handle_abort(state)
        else
          collect_output(state)
        end
    end
  end

  defp buffer_chunk(state, data) do
    {decoded, tail} = decode_utf8(state.utf8_tail <> data, [])
    state = %{state | utf8_tail: tail}
    sanitized = sanitize_output(decoded)

    # Call chunk callback if provided
    if state.on_chunk, do: state.on_chunk.(sanitized)

    new_total = state.total_bytes + byte_size(sanitized)

    cond do
      new_total > state.temp_file_threshold && is_nil(state.temp_file) ->
        # Start writing to temp file
        path = generate_temp_path()
        {:ok, file} = File.open(path, [:write, :binary, :exclusive])
        File.chmod!(path, 0o600)

        # Write existing buffer to file
        existing_content = IO.iodata_to_binary(Enum.reverse(state.output_buffer))
        IO.binwrite(file, existing_content)
        IO.binwrite(file, sanitized)

        %{
          state
          | temp_file: file,
            temp_file_path: path,
            output_buffer: [],
            total_bytes: new_total
        }

      state.temp_file ->
        # Continue writing to temp file
        IO.binwrite(state.temp_file, sanitized)
        %{state | total_bytes: new_total}

      true ->
        # Buffer in memory
        %{state | output_buffer: [sanitized | state.output_buffer], total_bytes: new_total}
    end
  end

  defp handle_abort(state) do
    state = stop_process(state)
    finalize_result(%{state | cancelled: true, exit_code: nil})
  end

  defp handle_timeout(state) do
    state = stop_process(state)
    result = finalize_result(%{state | cancelled: true, exit_code: nil})
    %Result{result | timed_out: true}
  end

  # Kill the process tree, keep any output already delivered to the mailbox
  # (partial output is part of an aborted/timed-out result), then close the port.
  defp stop_process(state) do
    if state.os_pid, do: kill_process_tree(state.os_pid)
    state = drain_output(state)

    try do
      Port.close(state.port)
    catch
      :error, _ -> :ok
    end

    state
  end

  defp drain_output(%{port: port} = state) do
    receive do
      {^port, {:data, data}} -> drain_output(buffer_chunk(state, data))
    after
      0 -> state
    end
  end

  # Wrap a command to run inside a pseudo-terminal using the `script` utility.
  # On macOS, `script -q /dev/null <shell> -c <cmd>` allocates a PTY.
  # On Linux, `script -qc <cmd> /dev/null` does the same.
  defp wrap_with_pty(shell_path, shell_args, command) do
    script_path = System.find_executable("script")

    if script_path do
      case :os.type() do
        {:unix, :darwin} ->
          # macOS: script -q /dev/null <shell> -c <command>
          {script_path, ["-q", "/dev/null", shell_path] ++ shell_args ++ [command]}

        {:unix, _} ->
          # Linux: script -qc '<shell> -c <command>' /dev/null
          inner = Enum.join([shell_path] ++ shell_args ++ [shell_escape(command)], " ")
          {script_path, ["-qc", inner, "/dev/null"]}

        _ ->
          # Fallback: no PTY wrapping available
          {shell_path, shell_args ++ [command]}
      end
    else
      # script not available, fall back to normal execution
      {shell_path, shell_args ++ [command]}
    end
  end

  defp wrap_command_with_cwd(command, cwd) when is_binary(cwd) and cwd != "" do
    if String.trim(command) == "" do
      "cd #{shell_escape(cwd)}"
    else
      "cd #{shell_escape(cwd)} && #{command}"
    end
  end

  defp wrap_command_with_cwd(command, _cwd), do: command

  defp shell_escape(path) do
    "'" <> String.replace(path, "'", "'\"'\"'") <> "'"
  end

  defp port_env(env) when map_size(env) == 0, do: []

  defp port_env(env) do
    [{:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}]
  end

  defp finalize_result(state) do
    state = if state.utf8_tail == "", do: state, else: buffer_chunk(%{state | utf8_tail: ""}, "�")
    # Close temp file if open
    if state.temp_file do
      File.close(state.temp_file)
    end

    # A spilled command may have emitted gigabytes. Read only its tail back;
    # the full stream stays in the retrievable artifact, not in BEAM memory.
    full_output =
      if state.temp_file_path do
        read_output_tail(state.temp_file_path, state.max_bytes)
      else
        IO.iodata_to_binary(Enum.reverse(state.output_buffer))
      end

    # Apply tail truncation
    {truncated_output, tail_truncated?, _info} =
      truncate_tail(full_output,
        max_bytes: state.max_bytes,
        max_lines: @default_max_lines
      )

    was_truncated = tail_truncated? or state.total_bytes > state.max_bytes
    # Determine full_output_path
    full_output_path =
      cond do
        was_truncated && state.temp_file_path ->
          # Already have temp file
          state.temp_file_path

        was_truncated ->
          # Need to create temp file for full output
          path = generate_temp_path()
          File.write!(path, full_output, [:exclusive])
          File.chmod!(path, 0o600)
          path

        true ->
          # Not truncated, cleanup temp file if exists
          if state.temp_file_path, do: File.rm(state.temp_file_path)
          nil
      end

    %Result{
      output: truncated_output,
      exit_code: state.exit_code,
      cancelled: state.cancelled,
      truncated: was_truncated,
      full_output_path: full_output_path
    }
  end

  defp read_output_tail(path, max_bytes) do
    {:ok, output} =
      File.open(path, [:read, :binary], fn file ->
        {:ok, size} = :file.position(file, :eof)
        {:ok, _} = :file.position(file, max(size - max_bytes, 0))

        case IO.binread(file, max_bytes) do
          :eof -> ""
          bytes -> trim_utf8_start(bytes)
        end
      end)

    output
  end

  # A byte-based tail may begin within a UTF-8 codepoint; discard only its
  # continuation bytes, leaving the remainder byte-faithful.
  defp trim_utf8_start(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: trim_utf8_start(rest)

  defp trim_utf8_start(bytes), do: bytes

  @doc """
  Sanitize output by removing ANSI codes and non-printable characters.
  """
  @spec sanitize_output(data :: binary()) :: String.t()
  def sanitize_output(data) when is_binary(data) do
    {decoded, tail} = decode_utf8(data, [])
    text = if tail == "", do: decoded, else: decoded <> "�"

    text
    # Strip ANSI escape codes
    |> String.replace(@ansi_regex, "")
    # Remove binary garbage (keep printable chars plus tab, newline, carriage return)
    |> String.replace(~r/[^\x09\x0A\x0D\x20-\x7E\x80-\xFF]/, "")
    # Normalize line endings (remove \r)
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "")
  end

  defp decode_utf8(data, acc) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      text when is_binary(text) ->
        {IO.iodata_to_binary(Enum.reverse([text | acc])), ""}

      {:incomplete, valid, tail} ->
        {IO.iodata_to_binary(Enum.reverse([valid | acc])), tail}

      {:error, valid, <<_invalid, rest::binary>>} ->
        decode_utf8(rest, ["�", valid | acc])
    end
  end

  @doc """
  Truncate content to keep the last N lines/bytes.

  ## Options

    * `:max_bytes` - Maximum bytes to keep (default: #{@default_max_bytes})
    * `:max_lines` - Maximum lines to keep (default: #{@default_max_lines})

  ## Returns

  A tuple of `{truncated_content, was_truncated, info}` where info contains:

    * `:total_lines` - Original total line count
    * `:total_bytes` - Original total byte count
    * `:output_lines` - Lines in truncated output
    * `:output_bytes` - Bytes in truncated output

  """
  @spec truncate_tail(content :: String.t(), opts :: keyword()) ::
          {truncated_content :: String.t(), was_truncated :: boolean(), info :: map()}
  def truncate_tail(content, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:max_bytes, @default_max_bytes)
      |> Keyword.put_new(:max_lines, @default_max_lines)

    LemonAi.Text.truncate_tail(content, opts)
  end

  @doc """
  Get the shell configuration for the current platform.

  Returns `{shell_path, args}` where args are the arguments to pass
  before the command (typically `["-c"]`).
  """
  @spec get_shell_config() :: {shell_path :: String.t(), args :: [String.t()]}
  def get_shell_config do
    case :os.type() do
      {:unix, _} ->
        cond do
          File.exists?("/bin/bash") ->
            {"/bin/bash", ["-c"]}

          File.exists?("/bin/sh") ->
            {"/bin/sh", ["-c"]}

          true ->
            # Try to find bash in PATH
            case System.find_executable("bash") do
              nil -> {System.find_executable("sh") || "/bin/sh", ["-c"]}
              path -> {path, ["-c"]}
            end
        end

      {:win32, _} ->
        # Try to find Git Bash first
        git_bash_paths = [
          "C:\\Program Files\\Git\\bin\\bash.exe",
          "C:\\Program Files (x86)\\Git\\bin\\bash.exe"
        ]

        case Enum.find(git_bash_paths, &File.exists?/1) do
          nil ->
            # Fall back to cmd.exe
            {System.find_executable("cmd.exe") || "cmd.exe", ["/C"]}

          path ->
            {path, ["-c"]}
        end
    end
  end

  @doc false
  def capture_workload_group(os_pid) when is_integer(os_pid) and os_pid > 1 do
    with {:ok, rows} <- process_group_rows(),
         %{pgid: ^os_pid, birth: birth} <- Enum.find(rows, &(&1.pid == os_pid)) do
      members = rows |> Enum.filter(&(&1.pgid == os_pid)) |> group_members()

      {:ok,
       %{
         pgid: os_pid,
         root_pid: os_pid,
         root_birth: birth,
         members: members,
         ownership_lost: false
       }}
    else
      _ -> {:error, :workload_unobservable}
    end
  end

  def capture_workload_group(_os_pid), do: {:error, :workload_unobservable}

  @doc false
  def workload_group_status(identity, root_exited \\ false)

  def workload_group_status(%{ownership_lost: true} = identity, _root_exited),
    do: {:unknown, identity}

  def workload_group_status(%{pgid: pgid, root_pid: root_pid} = identity, root_exited) do
    with {:ok, rows} <- process_group_rows() do
      root = Enum.find(rows, &(&1.pid == root_pid))
      live = Enum.filter(rows, &(&1.pgid == pgid and not String.starts_with?(&1.status, "Z")))

      cond do
        root && not String.starts_with?(root.status, "Z") &&
            (root_exited || root.birth != identity.root_birth || root.pgid != pgid) ->
          # Never send a signal to a recycled identity, even if it is later empty.
          {:unknown, %{identity | ownership_lost: true}}

        live == [] ->
          :terminated

        (root && root.birth == identity.root_birth) ||
            Enum.any?(live, &(Map.get(identity.members, &1.pid) == &1.birth)) ->
          {:alive, %{identity | members: group_members(live)}}

        true ->
          # The root disappeared before we could bind a surviving member.
          # Retain capacity, but do not signal an unproven group.
          {:unknown, identity}
      end
    else
      _ -> {:unknown, identity}
    end
  end

  def workload_group_status(identity, _root_exited), do: {:unknown, identity}

  @doc false
  def signal_workload_group(identity, signal, root_exited \\ false) do
    case workload_group_status(identity, root_exited) do
      {:alive, %{pgid: pgid} = observed} ->
        number = if signal == :sigterm, do: 15, else: 9
        # The owned group was checked immediately above; never signal a stale
        # positive root PID after the original shell has exited.
        :os.cmd(String.to_charlist("kill -#{number} -#{pgid} 2>/dev/null"))
        {:ok, observed}

      :terminated ->
        {:terminated, identity}

      {:unknown, observed} ->
        {:error, :workload_unobservable, observed}
    end
  catch
    _, _ -> {:error, :workload_unobservable, identity}
  end

  defp process_group_rows do
    # OS-owned absolute paths, not a command-controlled PATH executable.
    case Enum.find(["/bin/ps", "/usr/bin/ps"], &File.regular?/1) do
      nil ->
        {:error, :workload_unobservable}

      executable ->
        case System.cmd(executable, ["-axo", "pid=,pgid=,stat=,lstart="], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
              case String.split(String.trim(line), ~r/\s+/, parts: 4) do
                [pid, pgid, status, birth] ->
                  with {pid, ""} <- Integer.parse(pid),
                       {pgid, ""} <- Integer.parse(pgid) do
                    {:cont, {:ok, [%{pid: pid, pgid: pgid, status: status, birth: birth} | rows]}}
                  else
                    _ -> {:halt, {:error, :workload_unobservable}}
                  end

                _ ->
                  {:halt, {:error, :workload_unobservable}}
              end
            end)
            |> case do
              {:ok, [_ | _] = rows} -> {:ok, rows}
              _ -> {:error, :workload_unobservable}
            end

          _ ->
            {:error, :workload_unobservable}
        end
    end
  rescue
    _ -> {:error, :workload_unobservable}
  end

  defp group_members(rows), do: Map.new(rows, &{&1.pid, &1.birth})

  @doc """
  Kill a process and all of its descendants.

  On Unix, the descendant tree is collected with `pgrep -P` before signalling,
  so children of `bash -c` (a `sleep`, a test runner) do not outlive the
  shell. The process group is signalled as well. `signal` is `:sigkill`
  (default) or `:sigterm`. On Windows, uses `taskkill /T` to kill the tree.
  """
  @spec kill_process_tree(os_pid :: integer(), signal :: :sigkill | :sigterm) :: :ok
  def kill_process_tree(os_pid, signal \\ :sigkill) when is_integer(os_pid) do
    case :os.type() do
      {:unix, _} ->
        signal_number = if signal == :sigterm, do: 15, else: 9
        pids = [os_pid | descendant_pids(os_pid)] |> Enum.map_join(" ", &Integer.to_string/1)

        command =
          "kill -#{signal_number} -#{os_pid} 2>/dev/null; kill -#{signal_number} #{pids} 2>/dev/null"

        try do
          # Every pid is an integer (guard + pgrep parse); shell kill syntax is deliberate.
          # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
          :os.cmd(String.to_charlist(command))
        catch
          _, _ -> :ok
        end

        :ok

      {:win32, _} ->
        try do
          # os_pid is guard-checked as an integer; shell process-tree kill syntax is deliberate.
          # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
          :os.cmd(~c"taskkill /F /T /PID #{os_pid}")
        catch
          _, _ -> :ok
        end

        :ok
    end
  end

  defp descendant_pids(os_pid) do
    case System.find_executable("pgrep") do
      nil ->
        []

      pgrep ->
        {output, _status} =
          System.cmd(pgrep, ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

        children =
          output
          |> String.split()
          |> Enum.flat_map(fn token ->
            case Integer.parse(token) do
              {pid, ""} -> [pid]
              _ -> []
            end
          end)

        children ++ Enum.flat_map(children, &descendant_pids/1)
    end
  rescue
    _ -> []
  end

  # Get the OS PID from a port
  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # Generate a unique temp file path
  defp generate_temp_path do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "pi-bash-#{random}.log")
  end
end
