defmodule CodingAgent.ProcessManager do
  @moduledoc """
  DynamicSupervisor for managing background process sessions.

  Provides:
  - Starting new background processes
  - Listing active processes
  - Polling process status and logs
  - Writing to process stdin
  - Killing processes
  - Clearing completed processes

  This is the main API for the durable background process manager.
  """

  use DynamicSupervisor
  require Logger

  alias CodingAgent.{ProcessSession, ProcessStore}

  # Default max log lines (used by ProcessSession)

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a new background process.

  Options:
  - :command - The command to execute (required)
  - :cwd - Working directory (default: current directory)
  - :env - Environment variables map (default: %{})
  - :timeout_ms - Timeout in milliseconds (optional, nil = no timeout)
  - :yield_ms - Auto-background after this many milliseconds (optional)
  - :max_log_lines - Maximum log lines to keep (default: 1000)
  - :use_lane_queue - Whether to route through LaneQueue :background_exec lane (default: true)

  Returns {:ok, process_id} on success.
  """
  @spec exec(keyword()) :: {:ok, String.t()} | {:error, term()}
  def exec(opts) do
    command = Keyword.fetch!(opts, :command)
    use_lane_queue = Keyword.get(opts, :use_lane_queue, true)

    if use_lane_queue do
      # Route through LaneQueue for :background_exec lane
      exec_with_lane_queue(command, opts)
    else
      # Direct execution without lane scheduling
      do_exec(command, opts)
    end
  end

  defp exec_with_lane_queue(command, opts) do
    # Submit to LaneQueue :background_exec lane
    result =
      CodingAgent.LaneQueue.run(
        CodingAgent.LaneQueue,
        :background_exec,
        fn -> do_exec(command, Keyword.put(opts, :use_lane_queue, false)) end,
        %{type: :background_exec, command: command}
      )

    case result do
      {:ok, {:ok, process_id}} -> {:ok, process_id}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning(
        "LaneQueue unavailable for background exec, falling back to direct: #{inspect(e)}"
      )

      do_exec(command, opts)
  end

  defp do_exec(_command, opts) do
    process_id = generate_id()

    child_spec = %{
      id: {ProcessSession, process_id},
      start: {ProcessSession, :start_link, [[{:process_id, process_id} | opts]]},
      restart: :temporary,
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} ->
        # If yield_ms is specified, we would normally wait and then return
        # For now, we just return immediately
        {:ok, process_id}

      {:ok, _pid, _info} ->
        {:ok, process_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a command synchronously with optional timeout.

  If yield_ms is specified, the command will run in background after
  the yield time expires.
  """
  @spec exec_sync(keyword()) :: {:ok, map()} | {:error, term()}
  def exec_sync(opts) do
    yield_ms = Keyword.get(opts, :yield_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)

    if yield_ms do
      # Start in background and return immediately
      exec(opts)
    else
      # Run synchronously
      case exec(opts) do
        {:ok, process_id} ->
          # Wait for completion with timeout
          wait_for_completion(process_id, timeout_ms)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Poll a process for status and logs.

  Options:
  - :lines - Number of log lines to return (default: 100)
  """
  @spec poll(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll(process_id, opts \\ []) do
    line_count = Keyword.get(opts, :lines, 100)

    # First try to get from active session
    if ProcessSession.alive?(process_id) do
      ProcessSession.poll(process_id, line_count)
    else
      # Fall back to store
      case ProcessStore.get(process_id) do
        {:ok, record, logs} ->
          result = %{
            process_id: process_id,
            status: Map.get(record, :status),
            exit_code: Map.get(record, :exit_code),
            os_pid: Map.get(record, :os_pid),
            logs: Enum.take(logs, -line_count),
            command: Map.get(record, :command),
            cwd: Map.get(record, :cwd)
          }

          {:ok, result}

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  List all processes with optional status filter.

  Options:
  - :status - Filter by status (:running, :completed, :error, :killed, :lost, :all)
  """
  @spec list(keyword()) :: [{String.t(), map()}]
  def list(opts \\ []) do
    status_filter = Keyword.get(opts, :status, :all)
    ProcessStore.list(status_filter)
  end

  @doc """
  Get logs for a process.

  Options:
  - :lines - Number of log lines to return (default: 100)
  """
  @spec logs(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def logs(process_id, opts \\ []) do
    line_count = Keyword.get(opts, :lines, 100)

    if ProcessSession.alive?(process_id) do
      ProcessSession.poll(process_id, line_count)
      |> case do
        {:ok, result} -> {:ok, result.logs}
        error -> error
      end
    else
      ProcessStore.get_logs(process_id, line_count)
    end
  end

  @doc """
  Write data to a process's stdin.
  """
  @spec write(String.t(), String.t()) :: :ok | {:error, term()}
  def write(process_id, data) when is_binary(process_id) and is_binary(data) do
    if ProcessSession.alive?(process_id) do
      ProcessSession.write_stdin(process_id, data)
    else
      {:error, :process_not_running}
    end
  end

  @doc """
  Kill a running process.

  Signal can be :sigterm (default) or :sigkill.
  """
  @spec kill(String.t(), atom()) :: :ok | {:error, term()}
  def kill(process_id, signal \\ :sigterm) when is_binary(process_id) do
    if ProcessSession.alive?(process_id) do
      ProcessSession.kill(process_id, signal)
    else
      case ProcessStore.get(process_id) do
        {:ok, record, _} ->
          status = Map.get(record, :status)

          if status == :running do
            # Process was running but session died - mark as lost
            ProcessStore.mark_error(process_id, :session_died)
            :ok
          else
            {:error, :process_not_running}
          end

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Clear a completed process from the store.
  """
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(process_id) when is_binary(process_id) do
    # Stop the session if it's still running
    if ProcessSession.alive?(process_id) do
      ProcessSession.stop(process_id)
      ProcessStore.delete(process_id)
      :ok
    else
      case ProcessStore.get(process_id) do
        {:ok, _record, _logs} ->
          ProcessStore.delete(process_id)
          :ok

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Clear all completed/error/killed processes older than the specified age.
  """
  @spec clear_old(non_neg_integer()) :: :ok
  def clear_old(age_seconds \\ 3600) when is_integer(age_seconds) and age_seconds >= 0 do
    ProcessStore.cleanup(age_seconds)
  end

  @doc """
  Get the count of active (running) processes.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    __MODULE__
    |> DynamicSupervisor.count_children()
    |> Map.get(:active, 0)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60
    )
  end

  # Private Functions

  defp wait_for_completion(process_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(process_id, deadline)
  end

  defp do_wait(process_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case poll(process_id, lines: 0) do
        {:ok, %{status: status} = result} when status in [:completed, :error, :killed] ->
          case poll(process_id, lines: 1000) do
            {:ok, result_with_logs} -> {:ok, result_with_logs}
            _ -> {:ok, result}
          end

        {:ok, _} ->
          Process.sleep(100)
          do_wait(process_id, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
