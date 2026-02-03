defmodule AgentCore.CliRunners.JsonlRunner do
  @moduledoc """
  Base GenServer for running CLI tools that emit JSONL events.

  This module provides the infrastructure for spawning CLI subprocesses,
  reading their JSONL output, and emitting events through an EventStream.

  ## Architecture

  The JsonlRunner is a behaviour module that concrete runners implement.
  It handles:

  - Subprocess spawning with proper signal handling
  - JSONL line parsing from stdout
  - Concurrent stderr draining
  - Graceful shutdown (SIGTERM → SIGKILL)
  - Session locking to prevent concurrent runs of the same session
  - Event translation to unified CLI runner events

  ## Usage

  Implement the callbacks:

      defmodule MyRunner do
        use AgentCore.CliRunners.JsonlRunner

        @impl true
        def engine, do: "my_engine"

        @impl true
        def build_command(prompt, resume, state) do
          {"my-cli", ["exec", "--json"]}
        end

        @impl true
        def translate_event(data, state) do
          # Convert parsed JSON to CLI runner events
        end
      end

  Then start it:

      {:ok, pid} = MyRunner.start_link(prompt: "Hello", cwd: "/path")

      # Subscribe to events
      for event <- AgentCore.EventStream.events(stream) do
        handle_event(event)
      end

  ## Session Locking

  When resuming a session, the runner acquires a lock to prevent concurrent
  execution. This ensures session consistency when multiple callers try to
  resume the same session.

  """

  use GenServer

  require Logger

  alias AgentCore.CliRunners.Types.{Action, ActionEvent, ResumeToken, StartedEvent}

  # ============================================================================
  # Types
  # ============================================================================

  @type resume_option :: ResumeToken.t() | nil

  @type start_option ::
          {:prompt, String.t()}
          | {:resume, resume_option()}
          | {:cwd, String.t()}
          | {:env, [{String.t(), String.t()}]}
          | {:timeout, timeout()}
          | {:owner, pid()}

  @type runner_state :: term()

  # ============================================================================
  # Callbacks
  # ============================================================================

  @doc "Return the engine identifier (e.g., 'codex', 'claude')"
  @callback engine() :: String.t()

  @doc "Build the command and arguments to execute"
  @callback build_command(prompt :: String.t(), resume :: resume_option(), state :: runner_state()) ::
              {command :: String.t(), args :: [String.t()]}

  @doc "Create initial runner state"
  @callback init_state(prompt :: String.t(), resume :: resume_option()) :: runner_state()

  @doc "Create initial runner state with cwd context"
  @callback init_state(prompt :: String.t(), resume :: resume_option(), cwd :: String.t()) :: runner_state()

  @doc "Return bytes to send to stdin (or nil for no input)"
  @callback stdin_payload(prompt :: String.t(), resume :: resume_option(), state :: runner_state()) ::
              binary() | nil

  @doc "Decode a JSON line into a data structure"
  @callback decode_line(line :: binary()) :: {:ok, term()} | {:error, term()}

  @doc """
  Translate decoded data into CLI runner events.

  Returns a tuple of {events, updated_state, options} where options can include:
  - `:found_session` - ResumeToken extracted from this event
  - `:done` - true if this is the final event
  """
  @callback translate_event(data :: term(), state :: runner_state()) ::
              {events :: [AgentCore.CliRunners.Types.cli_event()], state :: runner_state(), opts :: keyword()}

  @doc "Handle non-zero exit code"
  @callback handle_exit_error(exit_code :: integer(), state :: runner_state()) ::
              {events :: [AgentCore.CliRunners.Types.cli_event()], state :: runner_state()}

  @doc "Handle stream end without completion event"
  @callback handle_stream_end(state :: runner_state()) ::
              {events :: [AgentCore.CliRunners.Types.cli_event()], state :: runner_state()}

  @doc "Optional environment variables"
  @callback env(state :: runner_state()) :: [{String.t(), String.t()}] | nil

  @optional_callbacks [env: 1, init_state: 3]

  # ============================================================================
  # Using Macro
  # ============================================================================

  defmacro __using__(_opts) do
    quote do
      @behaviour AgentCore.CliRunners.JsonlRunner

      require Logger

      alias AgentCore.CliRunners.JsonlRunner
      alias AgentCore.CliRunners.Types.ResumeToken

      # Default implementations

      @impl true
      def init_state(_prompt, _resume), do: %{}

      @impl true
      def stdin_payload(prompt, _resume, _state), do: prompt

      @impl true
      def decode_line(line) do
        Jason.decode(line)
      end

      @impl true
      def env(_state), do: nil

      defoverridable init_state: 2, stdin_payload: 3, decode_line: 1, env: 1

      # Public API

      @doc "Start the runner"
      def start_link(opts) do
        JsonlRunner.start_link(__MODULE__, opts)
      end

      @doc "Run synchronously and return the final result"
      def run(opts) do
        JsonlRunner.run(__MODULE__, opts)
      end

      @doc "Get the event stream from a running runner"
      def stream(pid) do
        JsonlRunner.stream(pid)
      end

      @doc "Cancel a running runner"
      def cancel(pid, reason \\ :user_requested) do
        JsonlRunner.cancel(pid, reason)
      end
    end
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a JSONL runner.

  ## Options

  - `:prompt` - The prompt to send (required)
  - `:resume` - ResumeToken for session continuation (optional)
  - `:cwd` - Working directory (default: current directory)
  - `:env` - Additional environment variables
  - `:timeout` - Subprocess timeout in ms (default: 10 minutes)
  - `:owner` - Owner process to monitor (default: caller)

  Returns `{:ok, pid}` where pid is the runner GenServer.
  Use `stream/1` to get the event stream.
  """
  @spec start_link(module(), [start_option()]) :: GenServer.on_start()
  def start_link(module, opts) do
    GenServer.start_link(__MODULE__, {module, opts})
  end

  @doc """
  Run synchronously and collect all events.

  Returns `{:ok, events}` or `{:error, reason}`.
  """
  @spec run(module(), [start_option()]) :: {:ok, [term()]} | {:error, term()}
  def run(module, opts) do
    case start_link(module, opts) do
      {:ok, pid} ->
        stream = stream(pid)
        events = AgentCore.EventStream.events(stream) |> Enum.to_list()
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Get the event stream from a running runner"
  @spec stream(pid()) :: AgentCore.EventStream.t()
  def stream(pid) do
    GenServer.call(pid, :get_stream)
  end

  @doc "Cancel a running runner"
  @spec cancel(pid(), term()) :: :ok
  def cancel(pid, reason \\ :user_requested) do
    GenServer.cast(pid, {:cancel, reason})
  end

  # ============================================================================
  # Session Lock Registry
  # ============================================================================

  # Simple ETS-based session locking
  @lock_table __MODULE__.SessionLocks

  defp ensure_lock_table do
    case :ets.whereis(@lock_table) do
      :undefined ->
        :ets.new(@lock_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  defp acquire_session_lock(nil), do: :ok

  defp acquire_session_lock(%ResumeToken{engine: engine, value: value}) do
    ensure_lock_table()
    key = {engine, value}

    case :ets.insert_new(@lock_table, {key, self()}) do
      true -> :ok
      false -> {:error, :session_locked}
    end
  end

  defp release_session_lock(nil), do: :ok

  defp release_session_lock(%ResumeToken{engine: engine, value: value}) do
    key = {engine, value}

    try do
      :ets.delete(@lock_table, key)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  defmodule State do
    @moduledoc false
    defstruct [
      :module,
      :prompt,
      :resume,
      :cwd,
      :extra_env,
      :timeout,
      :owner,
      :owner_ref,
      :stream,
      :port,
      :os_pid,
      :runner_state,
      :found_session,
      :stderr_path,
      :stderr_task,
      :timeout_ref,
      :done,
      :buffer,
      :new_session_locked,
      :decode_error_count,
      :cancel_kill_ref
    ]
  end

  @impl true
  def init({module, opts}) do
    prompt = Keyword.fetch!(opts, :prompt)
    resume = Keyword.get(opts, :resume)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    extra_env = Keyword.get(opts, :env, [])
    timeout = Keyword.get(opts, :timeout, 600_000)
    owner = Keyword.get(opts, :owner, self())

    # Acquire session lock if resuming
    case acquire_session_lock(resume) do
      :ok ->
        # Monitor owner
        owner_ref = Process.monitor(owner)

        # Create event stream
        {:ok, stream} = AgentCore.EventStream.start_link(owner: self(), timeout: :infinity)

        # Initialize runner state
        runner_state =
          if function_exported?(module, :init_state, 3) do
            module.init_state(prompt, resume, cwd)
          else
            module.init_state(prompt, resume)
          end

        state = %State{
          module: module,
          prompt: prompt,
          resume: resume,
          cwd: cwd,
          extra_env: extra_env,
          timeout: timeout,
          owner: owner,
          owner_ref: owner_ref,
          stream: stream,
          runner_state: runner_state,
          found_session: nil,
          done: false,
          buffer: "",
          new_session_locked: false,
          decode_error_count: 0,
          cancel_kill_ref: nil
        }

        # Start the subprocess
        {:ok, state, {:continue, :start_subprocess}}

      {:error, :session_locked} ->
        {:stop, {:error, :session_locked}}
    end
  end

  @impl true
  def handle_continue(:start_subprocess, state) do
    module = state.module

    # Expand tilde in cwd (Erlang ports don't expand ~)
    cwd = expand_tilde(state.cwd)
    state = %{state | cwd: cwd}

    # Build command
    {cmd, args} = module.build_command(state.prompt, state.resume, state.runner_state)

    # Get stdin payload
    stdin = module.stdin_payload(state.prompt, state.resume, state.runner_state)

    # Prepare stderr sink to avoid JSONL contamination
    stderr_path = write_temp_stderr()

    # Find executable
    cmd_path =
      case System.find_executable(cmd) do
        nil -> cmd
        path -> path
      end

    # Build environment
    base_env = module.env(state.runner_state) || []
    env = Enum.map(base_env ++ state.extra_env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    # Since Erlang ports can't close stdin, we need to pipe stdin through a shell
    # This ensures EOF is properly sent after the input
    {shell_cmd, port_opts} =
      if stdin do
        # Write stdin to temp file, then cat it into the command
        # This ensures proper EOF handling
        tmp_file = write_temp_stdin(stdin)

        # Build shell command that pipes temp file to the executable
        escaped_args = Enum.map(args, &escape_shell_arg/1) |> Enum.join(" ")
        shell_command =
          "cat #{escape_shell_arg(tmp_file)} | #{escape_shell_arg(cmd_path)} #{escaped_args} 2> #{escape_shell_arg(stderr_path)}; rm -f #{escape_shell_arg(tmp_file)}"

        shell_path = System.find_executable("bash") || System.find_executable("sh") || "/bin/sh"

        opts = [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:cd, state.cwd},
          {:args, ["-c", shell_command]}
        ] ++ if env != [], do: [{:env, env}], else: []

        {shell_path, opts}
      else
        # No stdin needed - still use shell wrapper to ensure proper stdout/stderr handling
        # and avoid TTY buffering issues. Important: redirect stdin from /dev/null to ensure
        # the subprocess gets EOF immediately (some CLIs like Claude wait for stdin to close)
        escaped_args = Enum.map(args, &escape_shell_arg/1) |> Enum.join(" ")
        shell_command = "#{escape_shell_arg(cmd_path)} #{escaped_args} </dev/null 2> #{escape_shell_arg(stderr_path)}"

        shell_path = System.find_executable("bash") || System.find_executable("sh") || "/bin/sh"

        opts = [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:cd, state.cwd},
          {:args, ["-c", shell_command]}
        ] ++ if env != [], do: [{:env, env}], else: []

        {shell_path, opts}
      end

    # Write to a debug file since stderr seems to be swallowed
    shell_args = Keyword.get(port_opts, :args, [])
    shell_script = if length(shell_args) > 1, do: Enum.at(shell_args, 1), else: "N/A"
    debug_log = "/tmp/jsonl_runner_debug.log"
    File.write!(debug_log, """
    [#{DateTime.utc_now()}] JsonlRunner starting
    cmd: #{cmd}
    path: #{cmd_path || "NOT FOUND"}
    cwd: #{state.cwd}
    script: #{shell_script}
    PATH: #{System.get_env("PATH")}
    """, [:append])

    try do
      port = Port.open({:spawn_executable, shell_cmd}, port_opts)
      os_pid = get_os_pid(port)

      # Set up timeout
      timeout_ref =
        if state.timeout != :infinity do
          Process.send_after(self(), :timeout, state.timeout)
        end

      state = %{state | port: port, os_pid: os_pid, timeout_ref: timeout_ref, stderr_path: stderr_path}

      {:noreply, state}
    rescue
      e ->
        Logger.error("Failed to start subprocess: #{inspect(e)}")
        AgentCore.EventStream.error(state.stream, {:spawn_failed, e})
        {:stop, :normal, state}
    end
  end

  defp write_temp_stdin(content) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "cli_runner_stdin_#{random}.txt")
    File.write!(path, content)
    path
  end

  defp write_temp_stderr do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "cli_runner_stderr_#{random}.log")
  end

  defp escape_shell_arg(arg) do
    # Escape single quotes and wrap in single quotes
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  @impl true
  def handle_call(:get_stream, _from, state) do
    {:reply, state.stream, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state =
      state
      |> maybe_reset_timeout(data)
      |> process_data(data)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    # Write to debug file
    debug_log = "/tmp/jsonl_runner_debug.log"

    stderr_content =
      if state.stderr_path do
        case File.read(state.stderr_path) do
          {:ok, content} -> content
          {:error, reason} -> "failed to read: #{inspect(reason)}"
        end
      else
        "no stderr path"
      end

    File.write!(debug_log, """

    [#{DateTime.utc_now()}] Exit status: #{exit_code}
    stderr_path: #{state.stderr_path}
    stderr_content: #{stderr_content}
    """, [:append])

    state =
      if state.done do
        state
      else
        state =
          maybe_emit_stderr_warning(state, exit_code)

        if exit_code != 0 do
          {events, runner_state} = state.module.handle_exit_error(exit_code, state.runner_state)
          state = %{state | runner_state: runner_state}
          emit_events(events, state)
        else
          {events, runner_state} = state.module.handle_stream_end(state.runner_state)
          state = %{state | runner_state: runner_state}
          emit_events(events, state)
        end

        %{state | done: true}
      end

    # Complete the stream
    AgentCore.EventStream.complete(state.stream, [])

    # Cleanup
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info(:timeout, state) do
    Logger.warning("Subprocess timed out")
    terminate_subprocess(state, :kill)
    AgentCore.EventStream.error(state.stream, :timeout)
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    Logger.debug("Owner process died, stopping runner")
    terminate_subprocess(state, :kill)
    AgentCore.EventStream.cancel(state.stream, :owner_down)
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info({:found_session, %ResumeToken{} = resume}, state) do
    {:noreply, %{state | found_session: resume}}
  end

  def handle_info(:cancel_kill, state) do
    terminate_subprocess(state, :kill)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    terminate_subprocess(state, :term)
    cancel_kill_ref = schedule_cancel_kill(state)
    AgentCore.EventStream.cancel(state.stream, reason)
    {:noreply, %{state | done: true, cancel_kill_ref: cancel_kill_ref}}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp process_data(state, data) do
    # Append to buffer and process only complete lines
    buffer = state.buffer <> data
    lines = String.split(buffer, "\n", trim: false)

    {complete_lines, remainder} =
      case Enum.split(lines, max(length(lines) - 1, 0)) do
        {[], []} -> {[], ""}
        {completed, [last]} -> {completed, last}
        {completed, []} -> {completed, ""}
      end

    state =
      Enum.reduce(complete_lines, state, fn line, acc ->
        process_line(line, acc)
      end)

    %{state | buffer: remainder}
  end

  defp process_line(line, state) when byte_size(line) == 0, do: state

  defp process_line(line, state) do
    line = String.trim_trailing(line, "\r")

    if String.contains?(line, "\n") do
      line
      |> String.split("\n", trim: true)
      |> Enum.reduce(state, &process_line/2)
    else
      if state.done do
        state
      else
        module = state.module

        case module.decode_line(line) do
          {:ok, data} ->
            {events, runner_state, opts} = module.translate_event(data, state.runner_state)

            # Update found_session if present
            found_session = Keyword.get(opts, :found_session, state.found_session)
            done = Keyword.get(opts, :done, false)

            state = %{state | runner_state: runner_state, found_session: found_session, done: done}

            case handle_started_events(events, state) do
              {:ok, state} ->
                # Emit events
                emit_events(events, state)

                state

              {:error, state} ->
                state
            end

          {:error, reason} ->
            Logger.debug("Failed to decode JSONL line: #{inspect(reason)}, line: #{line}")
            maybe_emit_decode_warning(reason, line, state)
        end
      end
    end
  end

  defp handle_started_events(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn
      %StartedEvent{resume: resume}, {:ok, acc} ->
        cond do
          acc.resume != nil and resume != acc.resume ->
            Logger.error("Resume session mismatch: expected #{inspect(acc.resume)}, got #{inspect(resume)}")
            AgentCore.EventStream.error(acc.stream, {:session_mismatch, %{expected: acc.resume, got: resume}})
            terminate_subprocess(acc, :kill)
            {:halt, {:error, %{acc | done: true}}}

          acc.found_session != nil and resume != acc.found_session ->
            Logger.error("Session switched midstream: expected #{inspect(acc.found_session)}, got #{inspect(resume)}")
            AgentCore.EventStream.error(acc.stream, {:session_mismatch, %{expected: acc.found_session, got: resume}})
            terminate_subprocess(acc, :kill)
            {:halt, {:error, %{acc | done: true}}}

          acc.resume == nil and not acc.new_session_locked ->
            case acquire_session_lock(resume) do
              :ok ->
                {:cont, {:ok, %{acc | new_session_locked: true}}}

              {:error, :session_locked} ->
                Logger.error("Session already locked: #{inspect(resume)}")
                AgentCore.EventStream.error(acc.stream, {:session_locked, resume})
                terminate_subprocess(acc, :kill)
                {:halt, {:error, %{acc | done: true}}}
            end

          true ->
            {:cont, {:ok, acc}}
        end

      _event, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  defp emit_events(events, state) do
    Enum.each(events, fn event ->
      # Extract session from StartedEvent
      case event do
        %StartedEvent{resume: resume} ->
          # Update found_session
          if resume do
            send(self(), {:found_session, resume})
          end

        _ ->
          :ok
      end

      AgentCore.EventStream.push_async(state.stream, {:cli_event, event})
    end)
  end

  defp terminate_subprocess(%{port: nil}, _mode), do: :ok

  defp terminate_subprocess(%{port: port, os_pid: os_pid}, :kill) do
    # Try to close the port gracefully first
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end

    # Kill the process tree if we have an OS PID
    if os_pid do
      kill_process_tree(os_pid)
    end

    :ok
  end

  defp terminate_subprocess(%{os_pid: os_pid, owner: owner}, :term) do
    if Mix.env() == :test and is_pid(owner) do
      send(owner, {:cli_term, os_pid})
    end

    if os_pid do
      term_process_tree(os_pid)
    end

    :ok
  end

  defp kill_process_tree(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:unix, _} ->
        # Try to kill process group first
        try do
          :os.cmd(~c"kill -9 -#{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

        # Also try single process
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

  defp term_process_tree(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:unix, _} ->
        try do
          :os.cmd(~c"kill -TERM -#{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

        try do
          :os.cmd(~c"kill -TERM #{os_pid} 2>/dev/null")
        catch
          _, _ -> :ok
        end

      {:win32, _} ->
        try do
          :os.cmd(~c"taskkill /T /PID #{os_pid}")
        catch
          _, _ -> :ok
        end
    end

    :ok
  end

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp cleanup(state) do
    # Cancel timeout
    if state.timeout_ref do
      Process.cancel_timer(state.timeout_ref)
    end

    if state.cancel_kill_ref do
      Process.cancel_timer(state.cancel_kill_ref)
    end

    # Release session lock(s). If a resumed session mismatched, we might have both.
    [state.found_session, state.resume]
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&release_session_lock/1)

    # Remove stderr file if present
    if state.stderr_path do
      try do
        File.rm(state.stderr_path)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp maybe_reset_timeout(%{timeout: :infinity} = state, _data), do: state

  defp maybe_reset_timeout(state, data) when is_binary(data) do
    if byte_size(data) == 0 do
      state
    else
      if state.timeout_ref do
        Process.cancel_timer(state.timeout_ref)
      end

      timeout_ref = Process.send_after(self(), :timeout, state.timeout)
      %{state | timeout_ref: timeout_ref}
    end
  end

  defp schedule_cancel_kill(_state) do
    grace_ms = cancel_grace_ms()
    Process.send_after(self(), :cancel_kill, grace_ms)
  end

  defp cancel_grace_ms do
    case Application.get_env(:agent_core, :cli_cancel_grace_ms) do
      nil -> 1_000
      value when is_integer(value) and value > 0 -> value
      _ -> 1_000
    end
  end

  defp maybe_emit_stderr_warning(%State{stderr_path: nil} = state, _exit_code), do: state

  defp maybe_emit_stderr_warning(%State{stderr_path: stderr_path} = state, exit_code) do
    if exit_code == 0 and state.done do
      state
    else
      stderr = read_stderr(stderr_path, 2_000)

      if stderr == "" do
        state
      else
        detail = %{
          stderr: stderr,
          exit_code: exit_code,
          truncated: byte_size(stderr) >= 2_000
        }

        emit_warning_event(state, "cli.stderr", "CLI stderr output", detail)
        state
      end
    end
  end

  defp read_stderr(path, max_bytes) do
    case File.read(path) do
      {:ok, content} ->
        if byte_size(content) > max_bytes do
          binary_part(content, 0, max_bytes)
        else
          content
        end

      _ ->
        ""
    end
  end

  defp expand_tilde("~" <> rest) do
    case System.user_home() do
      nil -> "~" <> rest
      home -> home <> rest
    end
  end

  defp expand_tilde(path), do: path

  defp maybe_emit_decode_warning(reason, line, %State{} = state) do
    if state.decode_error_count < 3 do
      detail = %{
        decode_error: reason,
        line: line
      }

      id = "decode_error_#{state.decode_error_count}"
      emit_warning_event(state, id, "Invalid JSONL line", detail)
    end

    %{state | decode_error_count: state.decode_error_count + 1}
  end

  defp emit_warning_event(state, action_id, title, detail) do
    action = %Action{id: action_id, kind: :warning, title: title, detail: detail}

    event = %ActionEvent{
      engine: state.module.engine(),
      action: action,
      phase: :completed,
      ok: false,
      message: title,
      level: :warning
    }

    AgentCore.EventStream.push_async(state.stream, {:cli_event, event})
  end

  if Mix.env() == :test do
    @doc false
    def ingest_data_for_test(state, data) do
      process_data(state, data)
    end
  end
end
