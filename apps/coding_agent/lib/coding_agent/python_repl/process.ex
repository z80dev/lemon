defmodule CodingAgent.PythonRepl.Process do
  @moduledoc """
  OS process boundary for one Python REPL kernel.

  Owns the BEAM `Port` for the interpreter, its OS PID, and the signal and
  process-tree primitives the kernel boundary needs:

    * `start/1` spawns the resolved interpreter with stdio connected to the
      port. The port's stdin/stdout carry the control protocol; the runner
      itself duplicates the original stdout into a private non-inherited
      control descriptor and redirects fd 1/2 to captured pipes, so user
      stdout/stderr can never corrupt or hold the control channel.
    * `write/2` queues request bytes (NDJSON lines) on stdin.
    * `interrupt/1` delivers SIGINT to the interpreter's process group on
      POSIX. Platforms without a reliable soft interrupt return
      `{:error, :unsupported}` and callers must escalate straight to
      `terminate_tree/1`.
    * `terminate_tree/1` first verifies that the OS process is alive, then
      escalates SIGTERM over the process group (bounded grace) to SIGKILL, and
      closes the port. Because PID liveness and signalling are separate OS
      operations, a PID can still be reused between them; callers MUST use
      close-only teardown once a port exit confirms the interpreter is dead.
    * `alive?/1` reports whether the OS process (not just the port) is alive.

  This module is a plain data wrapper with no process of its own. The owning
  `CodingAgent.PythonRepl.Session` receives the port's messages directly and
  recognizes them with `port/1`. The runner calls `setsid()` early on POSIX,
  which makes the interpreter a process-group leader; signal helpers target
  the group first and fall back to the single PID, so descendants die even
  when the runner died before it could establish its group.
  """

  defstruct [:port, :os_pid, :program, :term_grace_ms, :kill_grace_ms]

  @type t :: %__MODULE__{
          port: port() | nil,
          os_pid: integer() | nil,
          program: String.t() | nil,
          term_grace_ms: non_neg_integer(),
          kill_grace_ms: non_neg_integer()
        }

  @default_term_grace_ms 1_000
  @default_kill_grace_ms 1_000
  @poll_interval_ms 20

  @doc """
  Spawns the interpreter.

  ## Options

    * `:program` (required) - absolute path of the resolved interpreter
    * `:args` - argv after the program (default `[]`)
    * `:cwd` - working directory for the spawned process (required)
    * `:env` - additional/overriding environment (default `[]`)
    * `:term_grace_ms` - grace `terminate_tree/1` waits after SIGTERM
      (default #{@default_term_grace_ms})
    * `:kill_grace_ms` - grace `terminate_tree/1` waits after SIGKILL
      (default #{@default_kill_grace_ms})

  `:stderr_to_stdout` is deliberately not set: the runner redirects fd 1/2
  itself and speaks framed protocol on the duplicated stdout descriptor.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    program = Keyword.fetch!(opts, :program)
    args = Keyword.get(opts, :args, [])
    cwd = Keyword.fetch!(opts, :cwd)
    env = Keyword.get(opts, :env, [])

    port_opts =
      [:stream, :binary, :exit_status, :use_stdio, {:args, args}, {:cd, cwd}] ++
        env_opts(env) ++ hide_on_windows()

    case safe_open(program, port_opts) do
      {:ok, port} ->
        {:ok,
         %__MODULE__{
           port: port,
           os_pid: os_pid_of(port),
           program: program,
           term_grace_ms: Keyword.get(opts, :term_grace_ms, @default_term_grace_ms),
           kill_grace_ms: Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns the port whose messages identify this process."
  @spec port(t()) :: port() | nil
  def port(%__MODULE__{port: port}), do: port

  @doc "Returns the OS PID of the spawned interpreter, if known."
  @spec os_pid(t()) :: integer() | nil
  def os_pid(%__MODULE__{os_pid: os_pid}), do: os_pid

  @doc "Queues request bytes on the interpreter's stdin."
  @spec write(t(), iodata()) :: :ok
  def write(%__MODULE__{port: port}, data) when is_port(port) do
    Port.command(port, data)
    :ok
  end

  @doc """
  Delivers SIGINT to the interpreter's process group (POSIX only).

  Returns `{:error, :unsupported}` on platforms without a reliable soft
  interrupt; callers must then go directly to `terminate_tree/1`.
  """
  @spec interrupt(t()) :: :ok | {:error, :unsupported}
  def interrupt(%__MODULE__{} = process) do
    case :os.type() do
      {:unix, _} ->
        signal(process, :int)
        :ok

      _ ->
        {:error, :unsupported}
    end
  end

  @doc """
  Reports whether the OS process behind the port is still alive.

  Prefers an OS-level check (`kill -0`) so a dead child is not reported alive
  merely because its port has buffered data; falls back to `Port.info/1` when
  no OS PID or probe is available.
  """
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{port: port, os_pid: os_pid}) do
    cond do
      is_nil(port) -> false
      is_integer(os_pid) and os_probe?() -> os_pid_alive?(os_pid)
      true -> Port.info(port) != nil
    end
  end

  @doc """
  Terminates the interpreter and its whole process tree, synchronously.

  It only signals after `alive?/1` reports a live OS process, and checks
  liveness again before escalating from SIGTERM to SIGKILL. POSIX sends each
  signal to the group (falling back to the single PID), with bounded polls
  between signals. Windows uses `taskkill /F /T`. The port is always closed
  before returning, so no further port messages are delivered.

  The liveness check cannot make a PID identity-safe: the OS may reuse a PID
  between the check and the signal. Confirmed-dead port-exit paths MUST call
  `close/1` instead.
  """
  @spec terminate_tree(t()) :: :ok
  def terminate_tree(%__MODULE__{} = process) do
    if alive?(process) do
      case :os.type() do
        {:unix, _} ->
          signal(process, :term)

          unless down_within?(process, process.term_grace_ms) do
            if alive?(process) do
              signal(process, :kill)
              down_within?(process, process.kill_grace_ms)
            end
          end

        {:win32, _} ->
          if os_pid = process.os_pid do
            safe_cmd("taskkill", ["/F", "/T", "/PID", Integer.to_string(os_pid)])
          end
      end
    end

    close(process)
  end

  @doc "Closes the port without signalling. Idempotent."
  @spec close(t()) :: :ok
  def close(%__MODULE__{port: port}) do
    if is_port(port) do
      try do
        Port.close(port)
      catch
        :error, _ -> :ok
      end
    end

    :ok
  end

  ## Internals

  defp safe_open(program, port_opts) do
    port = Port.open({:spawn_executable, String.to_charlist(program)}, port_opts)
    {:ok, port}
  catch
    # Port.open raises on a missing executable or bad options; normalize to {:error, _}
    :error, reason -> {:error, reason}
  end

  defp env_opts([]), do: []

  defp env_opts(env) when is_list(env) do
    env
    |> Enum.map(fn
      {k, v} when is_binary(k) and is_binary(v) -> {String.to_charlist(k), String.to_charlist(v)}
      {k, v} when is_list(k) and is_list(v) -> {k, v}
    end)
    |> case do
      [] -> []
      normalized -> [{:env, normalized}]
    end
  end

  defp hide_on_windows do
    case :os.type() do
      {:win32, _} -> [:hide]
      _ -> []
    end
  end

  defp os_pid_of(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp signal(%__MODULE__{os_pid: os_pid}, sig) when is_integer(os_pid) do
    sig_name = signal_name(sig)

    # Group first (the runner setsid's, so its PID is the PGID), then the
    # single process as a fallback for a runner that died before setsid().
    safe_cmd("kill", ["-#{sig_name}", "-#{os_pid}"])
    safe_cmd("kill", ["-#{sig_name}", Integer.to_string(os_pid)])
    :ok
  end

  defp signal(%__MODULE__{os_pid: nil}, _sig), do: :ok

  defp signal_name(:int), do: "INT"
  defp signal_name(:term), do: "TERM"
  defp signal_name(:kill), do: "KILL"

  defp safe_cmd(prog, args) do
    if path = System.find_executable(prog) do
      try do
        System.cmd(path, args, stderr_to_stdout: true)
        :ok
      catch
        :error, _ -> :ok
      end
    else
      :ok
    end
  end

  defp os_probe?, do: not is_nil(System.find_executable("kill"))

  defp os_pid_alive?(os_pid) do
    case System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      {_out, _} -> false
    end
  end

  defp down_within?(process, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + max(grace_ms, 0)
    poll_until_down(process, deadline)
  end

  defp poll_until_down(process, deadline) do
    if not alive?(process) do
      true
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        false
      else
        Process.sleep(min(@poll_interval_ms, max(deadline - now, 1)))
        poll_until_down(process, deadline)
      end
    end
  end
end
