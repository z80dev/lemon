defmodule LemonEvals.PairedCleanup do
  @moduledoc """
  Offline teardown of a paired attempt's private process and native ledgers.

  Configure before runtime boot and verify immediately afterwards. Run recovery
  only after the owning runtime has stopped. Recovery starts no applications,
  admits no work and never releases capacity or infers ownership from a PID or
  session. Only the shared local birth/member proof authorizes group signalling;
  escaped, remote and otherwise unobservable workloads fail closed.
  """

  alias LemonCore.{Durable, NativeProcess, ProcessGroup}

  @table :lemon_evals_paired_cleanup
  @native_manifest {:manifest, %{version: 1, kind: :native_processes}}

  @doc "Bind fresh private ledgers before runtime boot, never an operator's store."
  def configure! do
    path = System.fetch_env!("LEMON_EVAL_PROCESS_STORE")

    for file <- [path, path <> ".native"] do
      {:error, :enoent} = File.lstat(file)
    end

    # NativeProcess establishes the directory with durable creation barriers.
    :ok = NativeProcess.configure!(path <> ".native")

    {:ok, @table} =
      :dets.open_file(@table, file: String.to_charlist(path), type: :set, repair: false)

    try do
      File.chmod!(path, 0o600)
      sync!(path)
      :ok = Durable.sync_directory(Path.dirname(path))
    after
      :ok = :dets.close(@table)
    end

    Application.put_env(:coding_agent, :process_store_path, path)
    :ok
  end

  @doc "Require the booted store and native tracker to own the configured ledgers."
  def verify! do
    path = System.fetch_env!("LEMON_EVAL_PROCESS_STORE")

    %{
      state: %{dets_path: ^path, dets_initialized: true, loaded_from_dets: true},
      info: %{filename: filename}
    } = CodingAgent.ProcessStoreServer.dets_status()

    ^path = to_string(filename)
    NativeProcess.verify!(path <> ".native")
    :ok
  end

  @doc "Recover both ledgers without booting a runtime; unknown evidence is an error."
  def recover(path) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    # Visit both ledgers even when one fails. Never let DETS create missing
    # evidence, or mistake a missing native declaration for an empty workload.
    results =
      Enum.map([{path, :processes}, {path <> ".native", :native}], fn {file, kind} ->
        recover_ledger(file, kind, deadline)
      end)

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :cleanup_unverified}
  end

  defp recover_ledger(path, kind, deadline) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         false <- ledger_open?(path),
         {:ok, @table} <-
           :dets.open_file(@table, file: String.to_charlist(path), type: :set, repair: true) do
      try do
        declared = kind == :processes or :dets.lookup(@table, :manifest) == [@native_manifest]

        if declared do
          :dets.foldl(
            fn row, result ->
              case recover_record(row, kind, deadline) do
                :ok -> result
                _ -> {:error, :cleanup_unverified}
              end
            end,
            :ok,
            @table
          )
        else
          {:error, :cleanup_unverified}
        end
      after
        :ok = :dets.close(@table)
      end
    else
      _ -> {:error, :cleanup_unverified}
    end
  rescue
    _ -> {:error, :cleanup_unverified}
  catch
    _, _ -> {:error, :cleanup_unverified}
  end

  defp ledger_open?(path) do
    Enum.any?(:dets.all(), fn table ->
      case :dets.info(table, :filename) do
        :undefined -> false
        filename -> Path.expand(to_string(filename)) == Path.expand(path)
      end
    end)
  end

  defp recover_record(row, kind, deadline) do
    case row do
      @native_manifest when kind == :native ->
        :ok

      {id, record, logs}
      when is_binary(id) and byte_size(id) > 0 and is_map(record) and
             (is_map(logs) or (kind == :processes and is_list(logs))) ->
        recover_declared_row(row, kind, deadline)

      _ ->
        {:error, :cleanup_unverified}
    end
  rescue
    _ -> {:error, :cleanup_unverified}
  catch
    _, _ -> {:error, :cleanup_unverified}
  end

  defp recover_declared_row(
         {_id,
          %{
            backend: :unsupported,
            workload_identity: nil,
            root_exited: false,
            capacity_held: false,
            termination_confirmed: false,
            launch_classification: :rejected
          }, _logs},
         :native,
         _deadline
       ),
       do: :ok

  defp recover_declared_row(
         {_id,
          %{
            backend: :local,
            workload_identity: identity,
            root_exited: exited,
            capacity_held: held,
            termination_confirmed: confirmed
          }, _logs} = row,
         :native,
         deadline
       )
       when is_boolean(exited) and is_boolean(held) and is_boolean(confirmed) do
    if ProcessGroup.valid_identity?(identity),
      do: recover_row(row, deadline),
      else: {:error, :cleanup_unverified}
  end

  defp recover_declared_row(_row, :native, _deadline), do: {:error, :cleanup_unverified}
  defp recover_declared_row(row, :processes, deadline), do: recover_row(row, deadline)

  # Durable terminal confirmation or a never-admitted queue entry can prove
  # that a process record without a workload witness needs no native recovery.
  defp recover_row({_id, %{termination_confirmed: true, capacity_held: false}, _logs}, _deadline),
    do: :ok

  defp recover_row(
         {_id, %{capacity_held: false, launch_classification: classification} = record, _logs},
         _deadline
       )
       when classification in [:queued, :rejected, :expired, :canceled] do
    if Map.get(record, :workload_identity) == nil,
      do: :ok,
      else: {:error, :cleanup_unverified}
  end

  defp recover_row({id, %{backend: :local, workload_identity: identity} = record, logs}, deadline) do
    if ProcessGroup.valid_identity?(identity) and is_boolean(Map.get(record, :root_exited, false)),
      do: recover_group(id, record, logs, deadline),
      else: {:error, :cleanup_unverified}
  end

  defp recover_row(_row, _deadline), do: {:error, :cleanup_unverified}

  defp recover_group(id, record, logs, deadline) do
    identity = record.workload_identity
    root_exited = Map.get(record, :root_exited, false)

    case ProcessGroup.workload_group_status(identity, root_exited) do
      :terminated ->
        :ok

      {:alive, observed} ->
        # Persist in the SAME ledger, with a host-crash barrier, before signal.
        # An interrupted recovery must retain its surviving-member proof.
        record = remember(id, record, logs, observed)

        if System.monotonic_time(:millisecond) < deadline do
          persist = fn final ->
            _record = remember(id, record, logs, final)
            # A previous failed barrier may have left this same witness in DETS.
            # Unchanged membership must never bypass the host-crash barrier.
            sync!(to_string(:dets.info(@table, :filename)))
            :ok
          end

          case ProcessGroup.signal_workload_group(observed, :sigkill, root_exited, persist) do
            {:terminated, _} ->
              :ok

            {:ok, observed} ->
              record = remember(id, record, logs, observed)
              Process.sleep(25)
              recover_group(id, record, logs, deadline)

            {:error, _, observed} ->
              _record = remember(id, record, logs, observed)
              {:error, :cleanup_unverified}
          end
        else
          {:error, :cleanup_unverified}
        end

      {:unknown, observed} ->
        _record = remember(id, record, logs, observed)
        {:error, :cleanup_unverified}
    end
  end

  defp remember(id, record, logs, identity) do
    updated = Map.put(record, :workload_identity, identity)

    if updated != record do
      :ok = :dets.insert(@table, {id, updated, logs})
      sync!(to_string(:dets.info(@table, :filename)))
    end

    updated
  end

  defp sync!(path) do
    :ok = :dets.sync(@table)
    :ok = Durable.sync_file(path)
  end
end
