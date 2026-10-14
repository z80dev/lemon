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
  - :admission_wait_ms - Caller yield budget; queued work remains owned and cancellable
  - :admission_timeout_ms - Finite deadline to start admission, independent of process lifetime

  Returns `{:ok, identity}` for an accepted launch, `{:queued, identity}` after
  the caller's admission yield budget, or a bounded
  `{:error, {:rejected, identity, reason} | {:outcome_unknown, identity}}`.
  `receipt/2` reconciles acceptance without rerunning external effects.
  """
  @spec exec(keyword()) :: {:ok, String.t()} | {:queued, String.t()} | {:error, term()}
  def exec(opts) do
    exec_launch(Keyword.get(opts, :launch_id) || generate_id(), opts)
  end

  defp exec_launch(identity, opts) do
    with {:ok, limits} <- background_limits(),
         :ok <- validate_launch(identity, opts),
         {:ok, backend} <- TerminalBackends.validate(Keyword.get(opts, :backend, :local)) do
      opts =
        opts
        |> Keyword.put(:backend, backend)
        |> Keyword.put(:process_id, identity)
        |> Keyword.put(:admission_caller_pid, self())
        |> Keyword.put_new(:cwd, File.cwd!())
        |> Keyword.put_new(:env, %{})
        |> Keyword.update(:timeout_ms, nil, fn
          :infinity -> nil
          timeout -> timeout
        end)
        |> Keyword.put(
          :admission_timeout_ms,
          Keyword.get(opts, :admission_timeout_ms) || limits.background_admission_timeout_ms
        )
        |> Keyword.put(
          :admission_wait_ms,
          Keyword.get(opts, :admission_wait_ms) || limits.background_admission_wait_ms
        )

      deadline = System.system_time(:millisecond) + Keyword.fetch!(opts, :admission_timeout_ms)
      opts = Keyword.put(opts, :admission_deadline_ms, deadline)

      fingerprint = request_fingerprint(opts)
      opts = Keyword.put(opts, :launch_fingerprint, fingerprint)

      case ProcessStore.register_launch(
             identity,
             Keyword.get(opts, :owner),
             fingerprint,
             deadline,
             Keyword.get(opts, :owner_pid)
           ) do
        :new -> admit_new_launch(backend, opts)
        {:existing, receipt} -> receipt_result(receipt)
        {:error, :identity_conflict} -> {:error, {:rejected, identity, :identity_conflict}}
      end
    else
      {:error, :unknown_backend} ->
        {:error, :unknown_terminal_backend}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, {:outcome_unknown, identity}}
  catch
    :exit, _ -> {:error, {:outcome_unknown, identity}}
  end

  defp admit_new_launch(backend, opts) do
    with :ok <- ensure_backend_available(backend),
         :ok <- TerminalBackendPolicy.validate(backend) do
      exec_with_lane_queue(opts)
    else
      {:error, reason} -> reject_launch(opts, backend_rejection(reason))
    end
  rescue
    _ -> reject_launch(opts, :backend_validation_failed)
  end

  defp backend_rejection(:backend_unavailable), do: :unavailable_terminal_backend
  defp backend_rejection({:terminal_backend_denied, _}), do: :terminal_backend_denied
  defp backend_rejection({:terminal_backend_not_allowed, _}), do: :terminal_backend_not_allowed
  defp backend_rejection(_), do: :backend_configuration_rejected

  defp reject_launch(opts, reason) do
    identity = Keyword.fetch!(opts, :process_id)
    ProcessStore.classify_launch(identity, :rejected, reason)
    reconcile_result(identity, Keyword.get(opts, :owner))
  end

  @doc false
  def background_limits(opts \\ []) do
    defaults = [
      background_process_limit: 8,
      background_pending_limit: 32,
      background_admission_timeout_ms: 5_000,
      background_admission_wait_ms: 1_000
    ]

    limits =
      Map.new(defaults, fn {key, default} ->
        {key, Keyword.get(opts, key, Application.get_env(:coding_agent, key, default))}
      end)

    case Enum.find(limits, fn {key, value} ->
           minimum = if key == :background_pending_limit, do: 0, else: 1

           maximum =
             if key in [:background_process_limit, :background_pending_limit],
               do: 1_000_000,
               else: 86_400_000

           not (is_integer(value) and value >= minimum and value <= maximum)
         end) do
      nil -> {:ok, limits}
      {key, _} -> {:error, {:invalid_background_limit, key}}
    end
  end

  @doc "Bounded, redacted counts of active, queued, rejected, expired and unknown launches."
  def admission_counts do
    ProcessStore.admission_counts()
  catch
    :exit, _ -> {:error, :admission_store_unavailable}
  end

  @doc "Cancel a queued launch under its exact session owner, before it can start."
  def cancel(identity, owner \\ nil) do
    ProcessStore.cancel_launch(identity, owner)
  catch
    :exit, _ -> {:error, {:outcome_unknown, identity}}
  end

  @doc """
  Internal operator recovery after independently confirming external termination.
  This is an assertion, not an OS/remote liveness probe, and is not an agent tool.
  The original uncertain execution receipt is retained; only capacity is released.
  """
  def confirm_external_termination(identity, owner) do
    case receipt(identity, owner) do
      {:ok, %{classification: :outcome_unknown, status: :starting}} ->
        {:error, :launch_still_starting}

      {:ok, %{classification: :outcome_unknown}} ->
        release_external_capacity(identity)

      {:error, :not_found} ->
        # Pre-cutover records have no validated request fingerprint, but their
        # lost process capacity still requires owner-scoped explicit recovery.
        case ProcessStore.get(identity) do
          {:ok, %{owner: ^owner, status: :lost}, _} ->
            release_external_capacity(identity)

          _ ->
            {:error, :not_found}
        end

      {:ok, _} ->
        {:error, :not_unknown}

      error ->
        error
    end
  end

  defp release_external_capacity(identity) do
    with :ok <- ProcessStore.confirm_termination(identity, :external_confirmed) do
      case Registry.lookup(CodingAgent.ProcessRegistry, identity) do
        [{pid, _}] -> send(pid, :external_termination_confirmed)
        _ -> :ok
      end

      :ok
    end
  end

  @doc "Return a redacted launch receipt, scoped to the exact launch owner."
  def receipt(identity, owner \\ nil) do
    ProcessStore.launch_receipt(identity, owner)
  catch
    :exit, _ -> {:error, :receipt_unavailable}
  end

  defp validate_launch(identity, opts) do
    command = Keyword.get(opts, :command)
    env = Keyword.get(opts, :env, %{})
    owner = Keyword.get(opts, :owner)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    owner_pid = Keyword.get(opts, :owner_pid)

    valid_wait =
      Enum.all?([:admission_timeout_ms, :admission_wait_ms], fn key ->
        value = Keyword.get(opts, key)
        is_nil(value) or (is_integer(value) and value > 0 and value <= 86_400_000)
      end)

    timeout = Keyword.get(opts, :timeout_ms)
    max_lines = Keyword.get(opts, :max_log_lines, 1000)

    valid_execution =
      (timeout in [nil, :infinity] or (is_integer(timeout) and timeout >= 0)) and
        is_integer(max_lines) and max_lines >= 0

    valid_env =
      is_map(env) and
        Enum.all?(env, fn {key, value} ->
          is_binary(key) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) and
            is_binary(value) and not String.contains?(value, <<0>>)
        end)

    if is_binary(identity) and byte_size(identity) in 1..128 and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, identity) and
         is_binary(command) and byte_size(command) > 0 and
         not String.contains?(command, <<0>>) and is_binary(cwd) and
         not String.contains?(cwd, <<0>>) and valid_env and
         valid_wait and valid_execution and (is_nil(owner) or is_binary(owner)) and
         (is_nil(owner_pid) or is_pid(owner_pid)) do
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
       Keyword.get(opts, :restart_generation, 0), Keyword.get(opts, :max_retained_bytes),
       Keyword.get(opts, :max_artifact_bytes), Keyword.get(opts, :max_owner_artifact_bytes),
       Keyword.get(opts, :max_runtime_artifact_bytes)}

    :crypto.hash(:sha256, :erlang.term_to_binary(request))
  end

  defp receipt_result(%{identity: id, classification: :accepted}), do: {:ok, id}

  defp receipt_result(%{identity: id, classification: :queued}), do: {:queued, id}

  defp receipt_result(%{identity: id, classification: classification})
       when classification in [:expired, :canceled],
       do: {:error, {classification, id}}

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
        CodingAgent.LaneQueue.run_background(
          lane_queue,
          identity,
          fn -> do_exec(opts) end,
          %{
            type: :background_exec,
            identity: identity,
            owner: owner,
            owner_pid: Keyword.get(opts, :owner_pid),
            admission_timeout_ms: Keyword.get(opts, :admission_timeout_ms),
            admission_deadline_ms: Keyword.fetch!(opts, :admission_deadline_ms),
            admission_wait_ms: Keyword.get(opts, :admission_wait_ms)
          }
        )
      rescue
        _ -> {:error, :admission_failed}
      catch
        :exit, {:noproc, _} -> {:error, :admission_unavailable}
        :exit, {:timeout, _} -> {:error, :admission_wait_yield}
        :exit, _ -> {:error, :admission_reply_lost}
      end

    case result do
      {:ok, {:ok, ^identity}} ->
        {:ok, identity}

      {:queued, ^identity} ->
        {:queued, identity}

      {:error, :admission_wait_yield} ->
        if is_pid(Keyword.get(opts, :owner_pid)), do: ProcessStore.yield_launch(identity, owner)
        reconcile_result(identity, owner)

      {:error, {:background_rejected, classification, reason}} ->
        ProcessStore.classify_launch(identity, classification, reason)
        reconcile_result(identity, owner)

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
  @spec exec_sync(keyword()) ::
          {:ok, map() | String.t()} | {:queued, String.t()} | {:error, term()}
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
          sync_result(process_id, timeout_ms)

        {:queued, process_id} ->
          {:queued, process_id}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp sync_result(process_id, timeout_ms) do
    case wait_for_completion(process_id, timeout_ms) do
      {:error, :timeout} -> {:error, {:outcome_unknown, process_id}}
      result -> result
    end
  rescue
    _ -> {:error, {:outcome_unknown, process_id}}
  catch
    :exit, _ -> {:error, {:outcome_unknown, process_id}}
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
            restart_generation: Map.get(record, :restart_generation, 0),
            output: Map.get(record, :output)
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
  dropped_lines, full_output_path, output}`; `dropped_lines` counts lines that scrolled out of the
  bounded log before they were read, and `output` holds capture statistics
  (see `CodingAgent.ProcessSession`; `nil` for records stored before they
  existed). Works for running and finished processes (finished ones are read
  from `ProcessStore`).
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
           dropped_lines: start - cursor,
           output: Map.get(record, :output)
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
    case ProcessStore.get(process_id) do
      {:ok, %{launch_classification: :queued, owner: owner}, _} ->
        cancel(process_id, owner)

      _ ->
        kill_started(process_id, signal)
    end
  catch
    :exit, _ -> {:error, {:outcome_unknown, process_id}}
  end

  defp kill_started(process_id, signal) do
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
  @spec restart(String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:queued, String.t(), map()} | {:error, term()}
  def restart(process_id, opts \\ []) when is_binary(process_id) do
    case ProcessStore.get(process_id) do
      {:ok, record, _logs} ->
        active_status = active_session_status(process_id)

        cond do
          (Map.get(record, :launch_classification) == :outcome_unknown or
             Map.get(record, :status) == :lost) and
              not Map.get(record, :termination_confirmed, false) ->
            {:error, {:outcome_unknown, process_id}}

          active_status in [:running, :killing, :starting] or
              (active_status == nil and
                 Map.get(record, :status) in [:running, :killing, :starting]) ->
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
                restart_generation: restart_generation
              ]

            case exec(restart_opts) do
              {classification, new_process_id} when classification in [:ok, :queued] ->
                {classification, new_process_id,
                 %{
                   restarted_from: process_id,
                   restart_generation: restart_generation,
                   backend: Map.get(record, :backend, :local)
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
      {:ok, %{status: status}, _}
      when status in [:running, :starting, :killing, :queued, :lost] ->
        {:error, :process_not_terminal}

      {:ok, _, _} ->
        if ProcessSession.alive?(process_id), do: ProcessSession.stop(process_id)
        ProcessStore.delete(process_id)

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
  Get occupied live-process capacity, including conservatively held unknown work.
  """
  @spec active_count() :: non_neg_integer() | {:error, :admission_store_unavailable}
  def active_count do
    case admission_counts() do
      %{occupied: occupied} -> occupied
      error -> error
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    case background_limits(opts) do
      {:ok, _limits} ->
        DynamicSupervisor.init(
          strategy: :one_for_one,
          max_restarts: 100,
          max_seconds: 60
        )

      {:error, reason} ->
        {:stop, reason}
    end
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

      {:ok, %{status: :lost}} ->
        {:error, {:outcome_unknown, process_id}}

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

        {:ok, %{status: :lost}} ->
          {:error, {:outcome_unknown, process_id}}

        {:ok, _} ->
          Process.sleep(100)
          do_wait(process_id, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
