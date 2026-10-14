defmodule CodingAgent.ProcessStore do
  @moduledoc """
  ETS-backed store for tracking background process execution.

  Stores process metadata (command, cwd, env, start time, owner),
  rolling logs (bounded), exit status, and supports reconnection
  to OS PIDs after restart.

  The actual ETS table is owned by ProcessStoreServer to ensure proper
  lifecycle management and DETS persistence.
  """

  alias CodingAgent.ProcessStoreServer

  @table :coding_agent_processes
  @dets_table :coding_agent_processes_dets
  @max_log_lines 1000
  @default_ttl_seconds 86_400

  @type process_id :: String.t()
  @type process_status :: :running | :completed | :error | :killed | :lost | :queued

  @doc """
  Create a new process entry and return its id.
  """
  @spec new_process(map()) :: process_id()
  def new_process(attrs \\ %{}) when is_map(attrs) do
    ensure_table()

    process_id =
      case Map.get(attrs, :id) do
        id when is_binary(id) and id != "" -> id
        _ -> generate_id()
      end

    now = System.system_time(:second)

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
          completed_at: nil
        },
        attrs
      )

    transaction(fn ->
      record =
        case :ets.lookup(@table, process_id) do
          [{^process_id, %{launch_fingerprint: fingerprint} = launch, _}]
          when is_binary(fingerprint) ->
            # Attaching metadata must not erase or race the serialized claim.
            Map.merge(
              record,
              Map.take(launch, [
                :owner,
                :launch_fingerprint,
                :launch_classification,
                :launch_reason,
                :capacity_held,
                :termination_confirmed,
                :admission_deadline_ms,
                :inserted_at,
                :status
              ])
            )

          _ ->
            record
        end

      if is_binary(Map.get(record, :launch_fingerprint)) do
        true = dets_open?()
        :ok = :dets.insert(@dets_table, {process_id, record, []})
        :ok = :dets.sync(@dets_table)
        :ets.insert(@table, {process_id, record, []})
      else
        insert_record(process_id, record, [])
      end
    end)

    process_id
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
  @spec mark_running(process_id(), integer() | nil, map() | nil) :: :ok
  def mark_running(process_id, os_pid, workload_identity \\ nil)
      when is_binary(process_id) and (is_integer(os_pid) or is_nil(os_pid)) do
    update_record(
      process_id,
      fn record ->
        record
        |> Map.put(:status, :running)
        |> Map.put(:os_pid, os_pid)
        |> Map.put(:workload_identity, workload_identity)
        |> Map.put(:root_exited, false)
        |> Map.put(:started_at, System.system_time(:second))
      end,
      true
    )
  end

  @doc false
  def update_workload_identity(process_id, identity, root_exited) do
    update_record(
      process_id,
      fn record ->
        Map.merge(record, %{workload_identity: identity, root_exited: root_exited})
      end,
      true
    )
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
  """
  @spec append_logs(process_id(), [String.t()]) :: :ok
  def append_logs(_process_id, []), do: :ok

  def append_logs(process_id, lines) when is_binary(process_id) and is_list(lines) do
    ensure_table()

    transaction(fn ->
      case :ets.lookup(@table, process_id) do
        [{^process_id, %{status: :cleared}, _}] ->
          :ok

        [{^process_id, record, logs}] ->
          logs = Enum.reverse(lines, logs) |> Enum.take(@max_log_lines)

          record =
            record
            |> Map.put(:updated_at, System.system_time(:second))
            |> Map.put(:log_line_count, length(logs))
            |> Map.put(:total_lines, Map.get(record, :total_lines, 0) + length(lines))

          insert_record(process_id, record, logs)
          :ok

        _ ->
          :ok
      end
    end)
  end

  @doc """
  Record how many output lines (by `:total_lines` position) have been read.
  """
  @spec put_read_cursor(process_id(), non_neg_integer()) :: :ok
  def put_read_cursor(process_id, cursor)
      when is_binary(process_id) and is_integer(cursor) and cursor >= 0 do
    update_record(process_id, &Map.put(&1, :read_cursor, cursor))
  end

  @doc """
  Mark a process as completed with exit code.
  """
  @spec mark_completed(process_id(), integer()) :: :ok
  def mark_completed(process_id, exit_code) when is_binary(process_id) do
    update_record(process_id, fn record ->
      record
      |> Map.put(:status, :completed)
      |> Map.put(:exit_code, exit_code)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @doc """
  Mark a process as killed.
  """
  @spec mark_killed(process_id()) :: :ok
  def mark_killed(process_id) when is_binary(process_id) do
    update_record(process_id, fn record ->
      record
      |> Map.put(:status, :killed)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @doc false
  def mark_unknown(process_id) do
    update_record(process_id, fn record ->
      Map.merge(record, %{status: :lost, launch_classification: :outcome_unknown})
    end)
  end

  @doc """
  Mark a process as failed with an error.
  """
  @spec mark_error(process_id(), term()) :: :ok
  def mark_error(process_id, error) when is_binary(process_id) do
    update_record(process_id, fn record ->
      record
      |> Map.put(:status, :error)
      |> Map.put(:error, error)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
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
          :ok | {:error, :process_not_terminal | :output_cleanup_failed | :unmanaged_output_path}
  def delete(process_id) when is_binary(process_id) do
    transaction(fn ->
      case :ets.lookup(@table, process_id) do
        [{^process_id, %{launch_fingerprint: fingerprint} = record, _logs}]
        when is_binary(fingerprint) ->
          held =
            Map.get(
              record,
              :capacity_held,
              Map.get(record, :status) in [:running, :starting, :killing, :lost]
            ) and
              not Map.get(record, :termination_confirmed, false)

          if held do
            {:error, :process_not_terminal}
          else
            with :ok <- remove_output(record) do
              tombstone =
                record
                |> Map.take([
                  :id,
                  :owner,
                  :launch_fingerprint,
                  :launch_classification,
                  :launch_reason,
                  :inserted_at,
                  :updated_at,
                  :completed_at,
                  :termination_confirmed
                ])
                |> Map.put(:launch_terminal_status, Map.get(record, :status))
                |> Map.put(:status, :cleared)

              insert_record(process_id, tombstone, [])
            end
          end

        [{^process_id, record, _}] ->
          with :ok <- remove_output(record) do
            :ets.delete(@table, process_id)
            if dets_open?(), do: :dets.delete(@dets_table, process_id)
            :ok
          end

        [] ->
          :ok
      end
    end)
  end

  @doc """
  Clear all processes (tests).
  """
  @spec clear() :: :ok
  def clear do
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
  Insert or update a record directly (used by server during load).
  """
  @spec insert_record(process_id(), map(), [String.t()]) :: :ok
  def insert_record(process_id, record, logs) do
    transaction(fn ->
      :ets.insert(@table, {process_id, record, logs})

      if dets_open?() do
        :ok = :dets.insert(@dets_table, {process_id, record, logs})
      end

      :ok
    end)
  end

  @doc """
  Check if DETS is available.
  """
  @spec dets_open?() :: boolean()
  def dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

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

  defp ensure_table do
    if :ets.info(@table, :owner) == self(),
      do: :ok,
      else: ProcessStoreServer.ensure_table(CodingAgent.ProcessStoreServer)
  end

  defp transaction(fun) do
    if :ets.info(@table, :owner) == self() do
      fun.()
    else
      ProcessStoreServer.transaction(CodingAgent.ProcessStoreServer, fun)
    end
  end

  defp update_record(process_id, fun, durable \\ false) do
    ensure_table()

    transaction(fn ->
      case :ets.lookup(@table, process_id) do
        [{^process_id, %{status: :cleared}, _}] ->
          :ok

        [{^process_id, record, logs}] ->
          updated =
            record
            |> fun.()
            |> Map.put(:updated_at, System.system_time(:second))

          if durable and is_binary(Map.get(updated, :launch_fingerprint)) do
            # Owned workload provenance must survive a crash before the command
            # is unblocked; do not publish a volatile identity before syncing it.
            :ok = :dets.insert(@dets_table, {process_id, updated, logs})
            :ok = :dets.sync(@dets_table)
            :ets.insert(@table, {process_id, updated, logs})
          else
            insert_record(process_id, updated, logs)
          end

          :ok

        _ ->
          :ok
      end
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
