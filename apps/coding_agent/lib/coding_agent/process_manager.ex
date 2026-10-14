defmodule CodingAgent.ProcessManager do
  @moduledoc """
  DynamicSupervisor for owned background process sessions.

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

  alias CodingAgent.{ProcessSession, ProcessStore}
  alias LemonCore.{TerminalBackendPolicy, TerminalBackends}

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
  - :launch_id - Optional fixed identity for reconciliation/retry; distinct logical
    launches must use distinct identities. Generated before admission by default.
  - :use_lane_queue - Retained for internal callers; false does not bypass admission.

  Returns `{:ok, identity}` for an accepted launch, or a bounded
  `{:error, {:rejected, identity, reason} | {:outcome_unknown, identity}}`.
  `receipt/2` reconciles acceptance without rerunning external effects.
  """
  @spec exec(keyword()) :: {:ok, String.t()} | {:error, term()}
  def exec(opts) do
    exec_launch(Keyword.get(opts, :launch_id, generate_id()), opts)
  end

  defp exec_launch(identity, opts) do

    with :ok <- validate_launch(identity, opts),
         {:ok, backend} <- TerminalBackends.validate(Keyword.get(opts, :backend, :local)),
         :ok <- ensure_backend_available(backend),
         :ok <- TerminalBackendPolicy.validate(backend) do
      opts =
        opts
        |> Keyword.put(:backend, backend)
        |> Keyword.put(:process_id, identity)
        |> Keyword.put_new(:cwd, File.cwd!())
        |> Keyword.put_new(:env, %{})

      fingerprint = request_fingerprint(opts)
      opts = Keyword.put(opts, :launch_fingerprint, fingerprint)

      case ProcessStore.register_launch(identity, Keyword.get(opts, :owner), fingerprint) do
        :new -> exec_with_lane_queue(opts)
        {:existing, receipt} -> receipt_result(receipt)
        {:error, :identity_conflict} -> {:error, {:rejected, identity, :identity_conflict}}
      end
    else
      {:error, :unknown_backend} ->
        {:error, {:unknown_terminal_backend, Keyword.get(opts, :backend)}}

      {:error, :backend_unavailable} ->
        {:error, {:unavailable_terminal_backend, Keyword.get(opts, :backend)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, {:outcome_unknown, identity}}
  catch
    :exit, _ -> {:error, {:outcome_unknown, identity}}
  end

  @doc "Return a redacted launch receipt, scoped to the exact launch owner."
  def receipt(identity, owner \\ nil), do: ProcessStore.launch_receipt(identity, owner)

  defp validate_launch(identity, opts) do
    command = Keyword.get(opts, :command)
    env = Keyword.get(opts, :env, %{})
    owner = Keyword.get(opts, :owner)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    owner_pid = Keyword.get(opts, :owner_pid)

    valid_env =
      is_map(env) and
        Enum.all?(env, fn {key, value} ->
          is_binary(key) and Regex.match?(~r/\\A[A-Za-z_][A-Za-z0-9_]*\\z/, key) and
            is_binary(value) and not String.contains?(value, <<0>>)
        end)

    if is_binary(identity) and byte_size(identity) in 1..128 and
         Regex.match?(~r/\\A[A-Za-z0-9_-]+\\z/, identity) and
         is_binary(command) and byte_size(command) > 0 and
         not String.contains?(command, <<0>>) and is_binary(cwd) and
         not String.contains?(cwd, <<0>>) and valid_env and
         (is_nil(owner) or is_binary(owner)) and (is_nil(owner_pid) or is_pid(owner_pid)) do
      :ok
    else
      {:error, :invalid_launch_request}
    end
  end

  defp request_fingerprint(opts) do
    request =
      {Keyword.fetch!(opts, :command), Keyword.fetch!(opts, :cwd),
       Enum.sort(Keyword.fetch!(opts, :env)), Keyword.fetch!(opts, :backend),
       Keyword.get(opts, :timeout_ms), Keyword.get(opts, :max_log_lines, 1000),
       Keyword.get(opts, :owner_pid), Keyword.get(opts, :restarted_from),
       Keyword.get(opts, :restart_generation, 0)}

    :crypto.hash(:sha256, :erlang.term_to_binary(request))
  end

  defp receipt_result(%{identity: id, classification: :accepted}), do: {:ok, id}

  defp receipt_result(%{identity: id, classification: :rejected, reason: reason}),
    do: {:error, {:rejected, id, reason}}

  defp receipt_result(%{identity: id}), do: {:error, {:outcome_unknown, id}}

  defp ensure_backend_available(backend) do
    if TerminalBackends.available?(backend) do
      :ok
    else
      {:error, :backend_unavailable}
    end
  end

  defp exec_with_lane_queue(opts) do
    identity = Keyword.fetch!(opts, :process_id)
    owner = Keyword.get(opts, :owner)
    lane_queue = Keyword.get(opts, :lane_queue, CodingAgent.LaneQueue)

    result =
      try do
        CodingAgent.LaneQueue.run(
          lane_queue,
          :background_exec,
          fn -> do_exec(opts) end,
          %{type: :background_exec, identity: identity}
        )
      rescue
        _ -> {:error, :admission_failed}
      catch
        :exit, {:noproc, _} -> {:error, :admission_unavailable}
        :exit, _ -> {:error, :admission_reply_lost}
      end

    case result do
      {:ok, {:ok, ^identity}} ->
        {:ok, identity}

      {:error, :admission_unavailable} ->
        ProcessStore.classify_launch(identity, :rejected, :admission_unavailable)
        reconcile_result(identity, owner)

      {:error, {:task_start_failed, _}} ->
        ProcessStore.classify_launch(identity, :rejected, :admission_unavailable)
        reconcile_result(identity, owner)

      _ ->
        ProcessStore.classify_launch(identity, :outcome_unknown)
        reconcile_result(identity, owner)
    end
  end

  defp reconcile_result(identity, owner) do
    case receipt(identity, owner) do
      {:ok, receipt} -> receipt_result(receipt)
      _ -> {:error, {:outcome_unknown, identity}}
    end
  end

  defp do_exec(opts) do
    process_id = Keyword.fetch!(opts, :process_id)

    child_spec = %{
      id: {ProcessSession, process_id},
      start: {ProcessSession, :start_link, [opts]},
      restart: :temporary,
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> {:ok, process_id}
      {:ok, _pid, _info} -> {:ok, process_id}
      _ -> reconcile_result(process_id, Keyword.get(opts, :owner))
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
    # Tool calls should not enforce timeouts by default.
    # Allow callers to override, but default is no timeout.
    timeout_ms = Keyword.get(opts, :timeout_ms, :infinity)

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
            cwd: Map.get(record, :cwd),
            backend: Map.get(record, :backend, :local),
            terminal_capabilities: Map.get(record, :terminal_capabilities, []),
            max_log_lines: Map.get(record, :max_log_lines),
            log_line_count: Map.get(record, :log_line_count, length(logs)),
            started_at: Map.get(record, :started_at),
            completed_at: Map.get(record, :completed_at),
            restarted_from: Map.get(record, :restarted_from),
            restart_generation: Map.get(record, :restart_generation, 0)
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
  Read the complete output lines a process produced since the previous
  `read_output/1` call, advancing the read cursor.

  Returns `%{process_id, status, exit_code, command, owner, lines,
  dropped_lines, full_output_path}`; `dropped_lines` counts lines that scrolled out of the
  bounded log before they were read. Works for running and finished
  processes (finished ones are read from `ProcessStore`).
  """
  @spec read_output(String.t()) :: {:ok, map()} | {:error, term()}
  def read_output(process_id) when is_binary(process_id) do
    if ProcessSession.alive?(process_id) do
      try do
        ProcessSession.read_output(process_id)
      catch
        # The session stopped between the liveness check and the call.
        :exit, _reason -> read_output_from_store(process_id)
      end
    else
      read_output_from_store(process_id)
    end
  end

  defp read_output_from_store(process_id) do
    case ProcessStore.get(process_id) do
      {:ok, record, logs} ->
        total = Map.get(record, :total_lines, length(logs))
        cursor = Map.get(record, :read_cursor, 0)
        first_buffered = total - length(logs)
        start = max(cursor, first_buffered)
        :ok = ProcessStore.put_read_cursor(process_id, total)

        {:ok,
         %{
           process_id: process_id,
           status: Map.get(record, :status),
           exit_code: Map.get(record, :exit_code),
           command: Map.get(record, :command),
           owner: Map.get(record, :owner),
           full_output_path: Map.get(record, :full_output_path),
           lines: Enum.drop(logs, start - first_buffered),
           dropped_lines: start - cursor
         }}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Check that `owner` may access `process_id`. A `nil` owner (a caller outside
  any session) may access every process; a session may access only the
  processes it started. Processes owned by someone else report `:not_found`
  so their existence is not disclosed.
  """
  @spec check_owner(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def check_owner(process_id, owner) when is_binary(process_id) do
    case ProcessStore.get(process_id) do
      {:ok, record, _logs} ->
        if is_nil(owner) or Map.get(record, :owner) == owner,
          do: :ok,
          else: {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
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

          if status in [:running, :starting, :lost] do
            # Killing a BEAM owner does not confirm OS/remote termination.
            receipt(process_id, Map.get(record, :owner))
            {:error, {:outcome_unknown, process_id}}
          else
            {:error, :process_not_running}
          end

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Restart a non-running stored process as a fresh supervised process.
  """
  @spec restart(String.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def restart(process_id, opts \\ []) when is_binary(process_id) do
    case ProcessStore.get(process_id) do
      {:ok, record, _logs} ->
        active_status = active_session_status(process_id)

        cond do
          active_status == :running or
              (active_status == nil and Map.get(record, :status) == :running) ->
            {:error, :process_running}

          not is_binary(Map.get(record, :command)) ->
            {:error, :missing_command}

          true ->
            restart_generation = Map.get(record, :restart_generation, 0) + 1

            restart_opts =
              [
                command: Map.fetch!(record, :command),
                cwd: Map.get(record, :cwd),
                env: Map.get(record, :env, %{}) || %{},
                backend: Map.get(record, :backend, :local),
                max_log_lines: Map.get(record, :max_log_lines, 1000),
                timeout_ms: Keyword.get(opts, :timeout_ms, Map.get(record, :timeout_ms)),
                owner: Map.get(record, :owner),
                owner_pid: Keyword.get(opts, :owner_pid),
                restarted_from: process_id,
                restart_generation: restart_generation,
                use_lane_queue: Keyword.get(opts, :use_lane_queue, true)
              ]

            case exec(restart_opts) do
              {:ok, new_process_id} ->
                {:ok, new_process_id,
                 %{
                   restarted_from: process_id,
                   restart_generation: restart_generation,
                   backend: Map.get(record, :backend, :local),
                   command: Map.get(record, :command)
                 }}

              {:error, reason} ->
                {:error, reason}
            end
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp active_session_status(process_id) do
    if ProcessSession.alive?(process_id) do
      case ProcessSession.get_state(process_id) do
        {:ok, state} -> Map.get(state, :status)
        _ -> nil
      end
    end
  end

  @doc """
  Clear a completed process from the store.
  """
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(process_id) when is_binary(process_id) do
    case ProcessStore.get(process_id) do
      {:ok, %{status: status}, _} when status in [:running, :starting, :queued, :lost] ->
        {:error, :process_not_terminal}

      {:ok, _, _} ->
        if ProcessSession.alive?(process_id), do: ProcessSession.stop(process_id)
        ProcessStore.delete(process_id)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
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
    case timeout_ms do
      :infinity ->
        do_wait(process_id, :infinity)

      nil ->
        do_wait(process_id, :infinity)

      ms when is_integer(ms) and ms >= 0 ->
        deadline = System.monotonic_time(:millisecond) + ms
        do_wait(process_id, deadline)

      _ ->
        # Be conservative: invalid values fall back to no timeout.
        do_wait(process_id, :infinity)
    end
  end

  defp do_wait(process_id, :infinity) do
    case poll(process_id, lines: 0) do
      {:ok, %{status: status} = result} when status in [:completed, :error, :killed] ->
        case poll(process_id, lines: 1000) do
          {:ok, result_with_logs} -> {:ok, result_with_logs}
          _ -> {:ok, result}
        end

      {:ok, _} ->
        Process.sleep(100)
        do_wait(process_id, :infinity)

      {:error, reason} ->
        {:error, reason}
    end
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
