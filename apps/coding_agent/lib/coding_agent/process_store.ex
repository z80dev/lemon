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

    insert_record(process_id, record, [])
    process_id
  end

  @doc """
  Register a logical launch before admission. Only the first registration may
  submit work; subsequent registrations reconcile the same identity.
  """
  def register_launch(id, owner, fingerprint) do
    GenServer.call(ProcessStoreServer, {:register_launch, id, owner, fingerprint})
  end

  @doc false
  def claim_launch(id, owner, fingerprint) do
    GenServer.call(ProcessStoreServer, {:claim_launch, id, owner, fingerprint})
  end

  @doc false
  def classify_launch(id, classification, reason \\ nil) do
    GenServer.call(ProcessStoreServer, {:classify_launch, id, classification, reason})
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
  @spec mark_running(process_id(), integer() | nil) :: :ok
  def mark_running(process_id, os_pid)
      when is_binary(process_id) and (is_integer(os_pid) or is_nil(os_pid)) do
    update_record(process_id, fn record ->
      record
      |> Map.put(:status, :running)
      |> Map.put(:os_pid, os_pid)
      |> Map.put(:started_at, System.system_time(:second))
    end)
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

    case :ets.lookup(@table, process_id) do
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
  @spec delete(process_id()) :: :ok
  def delete(process_id) when is_binary(process_id) do
    case :ets.lookup(@table, process_id) do
      [{^process_id, %{launch_fingerprint: fingerprint} = record, _logs}]
      when is_binary(fingerprint) ->
        remove_output(record)

        tombstone =
          record
          |> Map.take([
            :id, :owner, :launch_fingerprint, :launch_classification, :launch_reason,
            :inserted_at, :updated_at, :completed_at, :termination_confirmed
          ])
          |> Map.put(:launch_terminal_status, Map.get(record, :status))
          |> Map.put(:status, :cleared)

        insert_record(process_id, tombstone, [])

      records ->
        Enum.each(records, fn {_, record, _} -> remove_output(record) end)
        :ets.delete(@table, process_id)

        if dets_open?(), do: :dets.delete(@dets_table, process_id)
    end

    :ok
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
    :ets.insert(@table, {process_id, record, logs})

    if dets_open?() do
      :dets.insert(@dets_table, {process_id, record, logs})
    end

    :ok
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
             Regex.match?(~r/^lemon-process-[0-9a-f]{32}\.log$/, Path.basename(path)) do
          File.rm(path)
        end

      _ ->
        :ok
    end

    :ok
  end

  # Private Functions

  defp ensure_table do
    ProcessStoreServer.ensure_table(CodingAgent.ProcessStoreServer)
  end

  defp update_record(process_id, fun) do
    ensure_table()

    case :ets.lookup(@table, process_id) do
      [{^process_id, record, logs}] ->
        updated =
          record
          |> fun.()
          |> Map.put(:updated_at, System.system_time(:second))

        insert_record(process_id, updated, logs)
        :ok

      _ ->
        :ok
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
