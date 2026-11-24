defmodule CodingAgent.ProcessStore do
  @moduledoc """
  ETS-backed store for tracking background process execution.

  Stores process metadata (command, cwd, env, start time, owner),
  rolling logs (bounded), exit status, and supports reconnection
  to OS PIDs after restart.

  `:output` holds the session's capture statistics (see
  `CodingAgent.ProcessSession`). Artifact storage is accounted per owner:
  `reserve_artifact/4` grants each new process a capacity within both its owner's
  budget and the runtime budget, reclaiming stopped processes' artifacts oldest first.

  The actual ETS table is owned by ProcessStoreServer to ensure proper
  lifecycle management and DETS persistence.
  """

  alias CodingAgent.DurableTable
  alias CodingAgent.ProcessStoreServer

  @table :coding_agent_processes
  @dets_table :coding_agent_processes_dets
  @max_log_lines 1000
  @default_ttl_seconds 86_400
  @empty_output %{
    received_bytes: 0,
    retained_bytes: 0,
    discarded_bytes: 0,
    artifact_bytes: 0,
    artifact_capacity: 0,
    artifact_discarded_bytes: 0,
    artifact_truncated: false,
    artifact_error: nil,
    artifact_reclaimed: false,
    artifact_size_unknown: false,
    finalized: false
  }

  @type process_id :: String.t()
  @type process_status ::
          :queued
          | :starting
          | :running
          | :killing
          | :completed
          | :error
          | :killed
          | :lost
          | :rejected
          | :expired
          | :canceled

  @doc """
  Create an unmanaged process entry, or attach capture metadata to an existing
  managed launch, and return its id.

  Managed attachments must match the registered id, owner and fingerprint.
  Missing, conflicting or cleared launch identities fail closed; attachment
  preserves existing lifecycle, workload provenance, output and logs.
  """
  @spec new_process(map()) :: process_id()
  def new_process(attrs \\ %{}) when is_map(attrs) do
    process_id =
      case Map.get(attrs, :id) do
        id when is_binary(id) and id != "" -> id
        _ -> generate_id()
      end

    now = System.system_time(:second)

    metadata =
      attrs
      |> Map.take([
        :command,
        :cwd,
        :env,
        :backend,
        :terminal_capabilities,
        :max_log_lines,
        :full_output_path,
        :timeout_ms,
        :restarted_from,
        :restart_generation
      ])
      |> Map.put_new(:log_line_count, 0)
      |> Map.put_new(:total_lines, 0)
      |> Map.put_new(:read_cursor, 0)
      |> Map.put_new(:output, @empty_output)

    record =
      Map.merge(
        %{
          id: process_id,
          status: :queued,
          inserted_at: now,
          updated_at: now,
          command: nil,
          cwd: nil,
          env: %{},
          backend: :local,
          terminal_capabilities: [],
          max_log_lines: @max_log_lines,
          timeout_ms: nil,
          log_line_count: 0,
          total_lines: 0,
          read_cursor: 0,
          restarted_from: nil,
          restart_generation: 0,
          owner: nil,
          os_pid: nil,
          exit_code: nil,
          started_at: nil,
          completed_at: nil,
          output: @empty_output
        },
        attrs
      )

    attachment = %{
      owner: Map.get(attrs, :owner),
      fingerprint: Map.get(attrs, :launch_fingerprint),
      metadata: metadata
    }

    case call({:new_process, process_id, attachment, record}) do
      :ok -> process_id
      {:error, :store_unavailable} -> exit(:store_unavailable)
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Register a logical launch before admission. Only the first registration may
  submit work; subsequent registrations reconcile the same identity.
  """
  def register_launch(id, owner, fingerprint, deadline, owner_pid) do
    GenServer.call(
      ProcessStoreServer,
      {:register_launch, id, owner, fingerprint, deadline, owner_pid}
    )
  end

  @doc false
  def claim_launch(id, owner, fingerprint) do
    GenServer.call(ProcessStoreServer, {:claim_launch, id, owner, fingerprint})
  end

  @doc false
  def classify_launch(id, classification, reason \\ nil) do
    GenServer.call(ProcessStoreServer, {:classify_launch, id, classification, reason})
  end

  @doc false
  def cancel_launch(id, owner) do
    GenServer.call(ProcessStoreServer, {:cancel_launch, id, owner})
  end

  @doc false
  def yield_launch(id, owner), do: GenServer.call(ProcessStoreServer, {:yield_launch, id, owner})

  @doc false
  def yielded_launch?(id), do: GenServer.call(ProcessStoreServer, {:yielded_launch, id})

  @doc false
  def confirm_termination(id, cause \\ :workload_empty) do
    GenServer.call(ProcessStoreServer, {:confirm_termination, id, cause})
  end

  @doc false
  def admission_counts, do: GenServer.call(ProcessStoreServer, :background_counts)

  @doc false
  def capacity_available?, do: GenServer.call(ProcessStoreServer, :background_capacity_available)

  @doc false
  def subscribe_capacity(pid) do
    GenServer.call(ProcessStoreServer, {:subscribe_capacity, pid})
  end

  @doc """
  Redacted acceptance provenance. Unknown is not a confirmed rejection and must
  never be retried with a fresh identity automatically.
  """
  def launch_receipt(id, owner) do
    GenServer.call(ProcessStoreServer, {:launch_receipt, id, owner})
  end

  @doc false
  def receipt(record) do
    %{
      identity: record.id,
      classification: Map.get(record, :launch_classification, :outcome_unknown),
      reason: Map.get(record, :launch_reason),
      status: Map.get(record, :launch_terminal_status, Map.get(record, :status))
    }
  end

  @doc """
  Mark a process as running with its OS PID.
  """
  @spec mark_running(process_id(), integer() | nil, map() | nil) ::
          :ok | {:error, :store_unavailable}
  def mark_running(process_id, os_pid, workload_identity \\ nil)
      when is_binary(process_id) and (is_integer(os_pid) or is_nil(os_pid)) do
    update_record(
      process_id,
      %{
        status: :running,
        os_pid: os_pid,
        workload_identity: workload_identity,
        root_exited: false,
        started_at: System.system_time(:second)
      },
      true
    )
  end

  @doc false
  def update_workload_identity(process_id, identity, root_exited) do
    update_record(process_id, %{workload_identity: identity, root_exited: root_exited}, true)
  end

  @doc """
  Append a log line to a process's log buffer (bounded).
  """
  @spec append_log(process_id(), String.t()) :: :ok
  def append_log(process_id, line) when is_binary(process_id) and is_binary(line) do
    append_logs(process_id, [line])
  end

  @doc """
  Append log lines (oldest first) to a process's log buffer (bounded) in one
  write. `:total_lines` counts every line ever appended, including lines that
  have since scrolled out of the buffer.

  Options (used by `CodingAgent.ProcessSession` to mirror its retained tail):
  - `:keep` - number of newest lines to retain (default: 1000)
  - `:total_lines` - absolute line total, including lines never retained
  - `:output` - capture statistics stored as the record's `:output`
  """
  @spec append_logs(process_id(), [String.t()], keyword()) :: :ok | {:error, :store_unavailable}
  def append_logs(process_id, lines, opts \\ [])

  def append_logs(_process_id, [], []), do: :ok

  def append_logs(process_id, lines, opts)
      when is_binary(process_id) and is_list(lines) and is_list(opts) do
    call({:append_logs, process_id, lines, opts})
  end

  @doc """
  Replace a process's capture statistics.
  """
  @spec put_output(process_id(), map()) :: :ok | {:error, :store_unavailable}
  def put_output(process_id, output) when is_binary(process_id) and is_map(output) do
    update_record(process_id, %{output: output})
  end

  @doc false
  def put_service(process_id, service) do
    update_record(process_id, %{service: service})
  end

  @doc """
  Reserve artifact capacity for `process_id` within both aggregate budgets and
  return the granted bytes (at most `requested`, possibly 0).

  Live sessions are charged their reserved capacity; finalized sessions shrink
  that charge to the bytes actually written (unless size is unknown after a
  failure). Reclaim stopped sessions' artifacts oldest first, within the owner
  first, then runtime-wide. Failed deletions keep their charge and reference.
  Records remain readable with `output.artifact_reclaimed: true` and no path
  after successful reclamation. A live session's artifact is never deleted.
  Processes without an owner share the nil-owner budget. Reservations are
  serialized with all record mutations/deletion by `ProcessStoreServer`.
  Returns `:artifact_accounting_unavailable` if legacy usage cannot be measured
  or the reservation cannot be durably recorded; no writer may launch then.
  """
  @spec reserve_artifact(process_id(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :not_found | :artifact_accounting_unavailable}
  def reserve_artifact(process_id, requested, owner_budget, runtime_budget)
      when is_binary(process_id) and is_integer(requested) and requested > 0 and
             is_integer(owner_budget) and owner_budget > 0 and
             is_integer(runtime_budget) and runtime_budget > 0 do
    ProcessStoreServer.reserve_artifact(
      CodingAgent.ProcessStoreServer,
      process_id,
      requested,
      owner_budget,
      runtime_budget
    )
  end

  @doc """
  Record how many output lines (by `:total_lines` position) have been read.
  """
  @spec put_read_cursor(process_id(), non_neg_integer()) :: :ok | {:error, :store_unavailable}
  def put_read_cursor(process_id, cursor)
      when is_binary(process_id) and is_integer(cursor) and cursor >= 0 do
    update_record(process_id, %{read_cursor: cursor})
  end

  @doc """
  Mark a process as completed with exit code.
  """
  @spec mark_completed(process_id(), integer()) :: :ok | {:error, :store_unavailable}
  def mark_completed(process_id, exit_code) when is_binary(process_id) do
    update_record(process_id, %{
      status: :completed,
      exit_code: exit_code,
      completed_at: System.system_time(:second)
    })
  end

  @doc """
  Mark a process as killed.
  """
  @spec mark_killed(process_id()) :: :ok | {:error, :store_unavailable}
  def mark_killed(process_id) when is_binary(process_id) do
    update_record(process_id, %{status: :killed, completed_at: System.system_time(:second)})
  end

  @doc false
  def mark_unknown(process_id) do
    update_record(process_id, %{status: :lost, launch_classification: :outcome_unknown})
  end

  @doc """
  Mark a process as failed with an error.
  """
  @spec mark_error(process_id(), term()) :: :ok | {:error, :store_unavailable}
  def mark_error(process_id, error) when is_binary(process_id) do
    update_record(process_id, %{
      status: :error,
      error: error,
      completed_at: System.system_time(:second)
    })
  end

  @doc """
  Get process record and logs.
  """
  @spec get(process_id()) :: {:ok, map(), [String.t()]} | {:error, :not_found}
  def get(process_id) when is_binary(process_id) do
    ensure_table()

    case :ets.lookup(@table, process_id) do
      [{^process_id, %{status: :cleared}, _}] -> {:error, :not_found}
      [{^process_id, record, logs}] -> {:ok, record, Enum.reverse(logs)}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  List all processes with optional status filter.
  """
  @spec list(process_status() | :all) :: [{process_id(), map()}]
  def list(status_filter \\ :all) do
    ensure_table()

    :ets.foldl(
      fn {process_id, record, _logs}, acc ->
        if Map.get(record, :status) != :cleared and
             (status_filter == :all or Map.get(record, :status) == status_filter) do
          [{process_id, record} | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
    |> Enum.reverse()
  end

  @doc """
  Get recent log lines for a process.
  """
  @spec get_logs(process_id(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, :not_found}
  def get_logs(process_id, line_count \\ 100)
      when is_binary(process_id) and is_integer(line_count) do
    ensure_table()

    case :ets.lookup(@table, process_id) do
      [{^process_id, %{status: :cleared}, _}] ->
        {:error, :not_found}

      [{^process_id, _record, logs}] ->
        # logs are stored newest first, so take first N then reverse for chronological order
        {:ok, logs |> Enum.take(line_count) |> Enum.reverse()}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Delete a process from the store.
  """
  @spec delete(process_id()) ::
          :ok
          | {:error,
             :process_alive
             | :process_not_terminal
             | :output_cleanup_failed
             | :unmanaged_output_path
             | :store_unavailable}
  def delete(process_id) when is_binary(process_id), do: call({:delete, process_id})

  @doc """
  Clear all processes (tests).
  """
  @spec clear() :: :ok | {:error, :output_cleanup_failed}
  def clear do
    # Stop sessions outside the store server: their terminate callback writes
    # final capture statistics through that server.
    Enum.each(list(), fn {id, _record} ->
      CodingAgent.ProcessSession.stop(id)
    end)

    ProcessStoreServer.clear(CodingAgent.ProcessStoreServer)
  end

  @doc """
  Cleanup completed/error/killed processes older than the TTL (seconds).
  """
  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ @default_ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:ok, _count} = ProcessStoreServer.cleanup(CodingAgent.ProcessStoreServer, ttl_seconds)
    :ok
  end

  @doc """
  Insert or replace a record unless its identity was cleared.
  """
  @spec insert_record(process_id(), map(), [String.t()]) :: :ok | {:error, :store_unavailable}
  def insert_record(process_id, record, logs),
    do: call({:insert_record, process_id, record, logs})

  @doc """
  Check if DETS is available.
  """
  @spec dets_open?() :: boolean()
  def dets_open?, do: DurableTable.open?(@dets_table)

  @doc false
  def remove_output(record) do
    case Map.get(record, :full_output_path) do
      path when is_binary(path) ->
        # Only delete artifacts allocated by ProcessSession, never arbitrary
        # persisted path metadata.
        if Path.dirname(path) == Path.expand(System.tmp_dir!()) and
             Regex.match?(~r/\Alemon-process-[0-9a-f]{32}\.log\z/, Path.basename(path)) do
          case File.rm(path) do
            result when result in [:ok, {:error, :enoent}] -> :ok
            _ -> {:error, :output_cleanup_failed}
          end
        else
          {:error, :unmanaged_output_path}
        end

      _ ->
        :ok
    end
  end

  # Private Functions

  # Record/log read-modify-writes run in the reservation/cleanup owner's
  # mailbox as data, never as caller closures. Otherwise a cursor or status
  # write can restore a reclaimed path or overwrite a concurrently granted
  # capacity with its stale snapshot.
  defp call(request), do: GenServer.call(ProcessStoreServer, request, 30_000)

  # A failed availability check is not an empty table: readers exit.
  defp ensure_table do
    case ProcessStoreServer.ensure_table(ProcessStoreServer) do
      :ok -> :ok
      {:error, reason} -> exit(reason)
    end
  end

  # `changes` merge into the current record; `durable` syncs owned workload
  # provenance before the reply.
  defp update_record(process_id, changes, durable \\ false),
    do: call({:update_record, process_id, changes, durable})

  @doc false
  def notify_change(process_id) do
    LemonCore.Bus.broadcast("process_state:#{process_id}", {:process_state, :changed, process_id})
    :ok
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
