defmodule CodingAgent.BashExecutor do
  @moduledoc """
  Handles streaming shell command execution with output sanitization,
  truncation, and abort signal support.
  """

  alias AgentCore.AbortSignal

  defmodule Result do
    @moduledoc """
    Result struct for bash command execution.
    """
    defstruct [
      :output,
      :exit_code,
      :cancelled,
      :truncated,
      :full_output_path
    ]

    @type t :: %__MODULE__{
            output: String.t() | nil,
            exit_code: integer() | nil,
            cancelled: boolean(),
            truncated: boolean(),
            full_output_path: String.t() | nil
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

    port_opts = [
      :stream,
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, spawn_args}
    ]

    try do
      port = Port.open({:spawn_executable, spawn_path}, port_opts)
      os_pid = get_os_pid(port)

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
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp collect_output(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        # Check abort signal
        if state.signal && AbortSignal.aborted?(state.signal) do
          handle_abort(state)
        else
          sanitized = sanitize_output(data)

          # Call chunk callback if provided
          if state.on_chunk, do: state.on_chunk.(sanitized)

          new_total = state.total_bytes + byte_size(sanitized)

          state =
            if new_total > state.temp_file_threshold && is_nil(state.temp_file) do
              # Start writing to temp file
              path = generate_temp_path()
              {:ok, file} = File.open(path, [:write, :binary])

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
            else
              if state.temp_file do
                # Continue writing to temp file
                IO.binwrite(state.temp_file, sanitized)
                %{state | total_bytes: new_total}
              else
                # Buffer in memory
                %{
                  state
                  | output_buffer: [sanitized | state.output_buffer],
                    total_bytes: new_total
                }
              end
            end

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

  defp handle_abort(state) do
    cleanup_port(state)
    finalize_result(%{state | cancelled: true, exit_code: nil})
  end

  defp handle_timeout(state) do
    cleanup_port(state)
    finalize_result(%{state | cancelled: true, exit_code: nil})
  end

  defp cleanup_port(state) do
    # Kill the process tree
    if state.os_pid, do: kill_process_tree(state.os_pid)

    # Close the port
    try do
      Port.close(state.port)
    catch
      :error, _ -> :ok
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

  defp finalize_result(state) do
    # Close temp file if open
    if state.temp_file do
      File.close(state.temp_file)
    end

    # Get the full output
    full_output =
      if state.temp_file_path do
        File.read!(state.temp_file_path)
      else
        IO.iodata_to_binary(Enum.reverse(state.output_buffer))
      end

    # Apply tail truncation
    {truncated_output, was_truncated, _info} =
      truncate_tail(full_output,
        max_bytes: state.max_bytes,
        max_lines: @default_max_lines
      )

    # Determine full_output_path
    full_output_path =
      cond do
        was_truncated && state.temp_file_path ->
          # Already have temp file
          state.temp_file_path

        was_truncated ->
          # Need to create temp file for full output
          path = generate_temp_path()
          File.write!(path, full_output)
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

  @doc """
  Sanitize output by removing ANSI codes and non-printable characters.
  """
  @spec sanitize_output(data :: binary()) :: String.t()
  def sanitize_output(data) when is_binary(data) do
    data
    # First, ensure valid UTF-8 by replacing invalid sequences
    |> :unicode.characters_to_binary(:utf8, :utf8)
    |> case do
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
    # Strip ANSI escape codes
    |> String.replace(@ansi_regex, "")
    # Remove binary garbage (keep printable chars plus tab, newline, carriage return)
    |> String.replace(~r/[^\x09\x0A\x0D\x20-\x7E\x80-\xFF]/, "")
    # Normalize line endings (remove \r)
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "")
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
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)

    total_bytes = byte_size(content)
    lines = String.split(content, "\n")
    total_lines = length(lines)

    # Check if truncation is needed
    needs_line_truncation = total_lines > max_lines
    needs_byte_truncation = total_bytes > max_bytes

    if not needs_line_truncation and not needs_byte_truncation do
      info = %{
        total_lines: total_lines,
        total_bytes: total_bytes,
        output_lines: total_lines,
        output_bytes: total_bytes
      }

      {content, false, info}
    else
      # Take last max_lines
      truncated_lines =
        if needs_line_truncation do
          Enum.take(lines, -max_lines)
        else
          lines
        end

      truncated_content = Enum.join(truncated_lines, "\n")

      # Further truncate by bytes if needed
      truncated_content =
        if byte_size(truncated_content) > max_bytes do
          # Take last max_bytes, which may result in partial first line
          binary_part(truncated_content, byte_size(truncated_content) - max_bytes, max_bytes)
        else
          truncated_content
        end

      output_lines = length(String.split(truncated_content, "\n"))
      output_bytes = byte_size(truncated_content)

      info = %{
        total_lines: total_lines,
        total_bytes: total_bytes,
        output_lines: output_lines,
        output_bytes: output_bytes
      }

      # Add truncation notice
      notice = "[Output truncated. Total: #{total_lines} lines, #{total_bytes} bytes]\n\n"
      final_content = notice <> truncated_content

      {final_content, true, info}
    end
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

  @doc """
  Kill a process and its children.

  On Unix, attempts to kill the process group first, then falls back to killing
  the single process. On Windows, uses taskkill with /T to kill the tree.
  """
  @spec kill_process_tree(os_pid :: integer()) :: :ok
  def kill_process_tree(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:unix, _} ->
        # Try to kill process group first (negative PID)
        try do
          :os.cmd(~c"kill -9 -#{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

        # Also try single process as fallback
        try do
          :os.cmd(~c"kill -9 #{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

        :ok

      {:win32, _} ->
        try do
          :os.cmd(~c"taskkill /F /T /PID #{os_pid}")
        catch
          _, _ -> :ok
        end

        :ok
    end
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
