defmodule CodingAgent.ProcessStoreServer do
  @moduledoc """
  GenServer that owns the ProcessStore ETS table and manages DETS persistence.

  Serializes launch admission, lifetime capacity and artifact accounting with
  every record mutation. Requests carry data only; no caller closure runs in
  this owner. A storage failure replies `{:error, :store_unavailable}` and
  the owner keeps running.

  ## Restart semantics

  A crashed owner's restart reclaims the live mirror from its ETS heir; a boot
  (first start, application restart or clean stop) reloads DETS. Both apply
  the same live-owner reconciliation: surviving registered sessions are
  preserved and re-monitored, unclaimed queued launches are cancelled and
  missing live owners are marked :lost without treating their absence as
  proof of external workload termination. A lost unmanaged row without a live
  owner or a valid workload witness has no admission charge. Explicit managed
  reservations remain charged until external termination is confirmed, even
  when their BEAM owner has disappeared.

  `CodingAgent.ProcessManager` (and every `CodingAgent.ProcessSession`,
  including one-shot foreground commands) is started before this owner, so a
  store restart never restarts the sessions or stops their process groups.
  """

  use CodingAgent.DurableTable
  require Logger

  @table :coding_agent_processes
  @dets_table :coding_agent_processes_dets
  @default_ttl_seconds 86_400
  @max_log_lines 1000

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Returns the ETS table name for direct access by ProcessStore API.
  """
  def table_name, do: @table

  @doc """
  Ensure the table is initialized. Called by ProcessStore API functions.
  """
  def ensure_table(server \\ __MODULE__) do
    GenServer.call(server, :ensure_table, 5_000)
  end

  @doc """
  Trigger a cleanup of expired processes.
  """
  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  @doc """
  Clear all processes from both ETS and DETS.
  """
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear, 5_000)
  end

  @doc """
  Get DETS table status for debugging.
  """
  def dets_status(server \\ __MODULE__) do
    GenServer.call(server, :dets_status, 5_000)
  end

  @doc """
  Reserve artifact capacity for a process within its owner's aggregate budget,
  reclaiming finished artifacts if needed. See
  `CodingAgent.ProcessStore.reserve_artifact/4`.
  """
  def reserve_artifact(server, process_id, requested, owner_budget, runtime_budget) do
    GenServer.call(
      server,
      {:reserve_artifact, process_id, requested, owner_budget, runtime_budget},
      30_000
    )
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    case CodingAgent.ProcessManager.background_limits(opts) do
      {:ok, limits} -> init_store(opts, limits)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_store(opts, limits) do
    state = %{
      background_limit: limits.background_process_limit,
      occupied: 0,
      pending_limit: limits.background_pending_limit,
      pending: %{},
      pending_ref_index: %{},
      live_ref_index: %{},
      live_identity_index: %{},
      capacity_subscribers: %{}
    }

    state =
      DurableTable.open(state, opts,
        table: @table,
        dets_table: @dets_table,
        path: dets_path(opts),
        normalize: &__MODULE__.normalize_row/2,
        # Its normalization only resolves owners that are gone, so it also
        # applies to a reclaimed mirror whose monitors died with the owner.
        reclaim: &__MODULE__.normalize_row/2,
        timestamp: &__MODULE__.expiry_timestamp/1,
        after_load: &__MODULE__.restore_capacity/1,
        reload_empty: true,
        ttl_key: :process_store_ttl_seconds,
        interval_key: :process_store_cleanup_interval_seconds
      )

    {:ok, state}
  end

  # Requests are data; no caller closure runs here. Storage failure is a
  # reply, never an owner exit: the owner keeps serving and restarts of it
  # cannot cascade into ProcessManager's sessions.
  @impl true
  def handle_call(:dets_status, _from, state), do: {:reply, DurableTable.status(state), state}

  def handle_call(request, from, state) do
    state = ensure_tables(state)

    if state.dets_initialized,
      do: serve(request, from, state),
      else: {:reply, {:error, :store_unavailable}, state}
  rescue
    error ->
      Logger.warning("Process store request failed: #{inspect(error.__struct__)}")
      {:reply, {:error, :store_unavailable}, state}
  catch
    :throw, :store_unavailable -> {:reply, {:error, :store_unavailable}, state}
  end

  defp serve(:ensure_table, _from, state), do: {:reply, :ok, state}

  defp serve({:new_process, id, attachment, record}, _from, state),
    do: {:reply, attach_process(id, attachment, record), state}

  defp serve({:append_logs, id, lines, opts}, _from, state),
    do: {:reply, append_logs(id, lines, opts), state}

  defp serve({:update_record, id, changes, durable}, _from, state),
    do: {:reply, update_record(id, changes, durable), state}

  defp serve({:insert_record, id, record, logs}, _from, state),
    do: {:reply, insert_record(id, record, logs), state}

  defp serve({:delete, id}, _from, state), do: {:reply, delete_process(id), state}

  defp serve({:register_launch, id, owner, fingerprint, deadline, owner_pid}, from, state) do
    reply =
      case :ets.lookup(@table, id) do
        [] ->
          now = System.system_time(:second)

          record = %{
            id: id,
            owner: owner,
            launch_fingerprint: fingerprint,
            launch_classification: :queued,
            admission_deadline_ms: deadline,
            status: :queued,
            capacity_held: false,
            termination_confirmed: false,
            inserted_at: now,
            updated_at: now
          }

          if map_size(state.pending) >= state.pending_limit + state.background_limit do
            record =
              Map.merge(record, %{
                launch_classification: :rejected,
                status: :rejected,
                launch_reason: :overloaded
              })

            persist_launch(id, record, [])
            {:existing, CodingAgent.ProcessStore.receipt(record)}
          else
            persist_launch(id, record, [])
            :new
          end

        [{^id, %{owner: ^owner, launch_fingerprint: ^fingerprint} = record, logs}] ->
          record = reconcile_launch_record(id, record, logs)
          {:existing, CodingAgent.ProcessStore.receipt(record)}

        _ ->
          {:error, :identity_conflict}
      end

    state = if reply == :new, do: track_pending(state, id, from, owner_pid, deadline), else: state
    {:reply, reply, state}
  end

  defp serve({:claim_launch, id, owner, fingerprint}, {session, _tag}, state) do
    reply =
      case :ets.lookup(@table, id) do
        [
          {^id,
           %{owner: ^owner, launch_fingerprint: ^fingerprint, launch_classification: :queued} =
               record, logs}
        ] ->
          cond do
            pending_abandoned?(state, id) ->
              record =
                Map.merge(record, %{
                  launch_classification: :canceled,
                  status: :canceled,
                  launch_reason: :owner_abandoned
                })

              persist_launch(id, record, logs)
              notify_capacity(state, {:background_launch_canceled, id})
              {:error, :admission_canceled}

            System.system_time(:millisecond) >= Map.get(record, :admission_deadline_ms, :infinity) ->
              record = Map.merge(record, %{launch_classification: :expired, status: :expired})
              persist_launch(id, record, logs)
              notify_capacity(state, {:background_launch_classified, id, :expired})
              {:error, :admission_expired}

            state.occupied >= state.background_limit ->
              {:error, :capacity_full}

            true ->
              # Persist both uncertainty and capacity BEFORE external execution.
              record =
                Map.merge(record, %{
                  launch_classification: :outcome_unknown,
                  status: :starting,
                  capacity_held: true,
                  termination_confirmed: false
                })

              persist_launch(id, record, logs)
              :ok
          end

        [{^id, %{owner: ^owner, launch_fingerprint: ^fingerprint} = record, _}] ->
          {:error, {:existing_launch, CodingAgent.ProcessStore.receipt(record)}}

        _ ->
          {:error, :identity_conflict}
      end

    state =
      case reply do
        :ok ->
          state
          |> Map.put(:occupied, state.occupied + 1)
          |> forget_pending(id)
          |> track_live(id, session)

        {:error, :admission_expired} ->
          forget_pending(state, id)

        {:error, :admission_canceled} ->
          forget_pending(state, id)

        _ ->
          state
      end

    {:reply, reply, state}
  end

  defp serve({:classify_launch, id, classification, reason}, _from, state) do
    state =
      case :ets.lookup(@table, id) do
        [{^id, %{status: :cleared}, _}] ->
          state

        [{^id, record, logs}] ->
          # A lost queue reply must not downgrade an acknowledged process, and a
          # confirmed rejection cannot overwrite a start that crossed the boundary.
          current = Map.get(record, :launch_classification)

          if current == :queued or classification == :accepted do
            record =
              record
              |> Map.put(:launch_classification, classification)
              |> Map.put(:launch_reason, reason)
              |> then(fn record ->
                if classification in [:rejected, :expired, :canceled],
                  do: Map.put(record, :status, classification),
                  else: record
              end)

            persist_launch(id, record, logs)
            notify_capacity(state, {:background_launch_classified, id, classification})
            forget_pending(state, id)
          else
            state
          end

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  defp serve({:subscribe_capacity, pid}, _from, state) do
    state =
      if Map.has_key?(state.capacity_subscribers, pid) do
        state
      else
        put_in(state.capacity_subscribers[pid], Process.monitor(pid))
      end

    {:reply, :ok, state}
  end

  defp serve({:yield_launch, id, owner}, _from, state) do
    case {:ets.lookup(@table, id), Map.get(state.pending, id)} do
      {[{^id, %{owner: ^owner, launch_classification: :queued}, _}], pending}
      when is_map(pending) ->
        if is_pid(pending.owner) and pending.owner != pending.caller and
             Process.alive?(pending.owner) do
          Process.demonitor(pending.caller_ref, [:flush])
          refs = List.delete(pending.refs, pending.caller_ref)

          state =
            state
            |> put_in([:pending, id], %{pending | refs: refs, caller: nil})
            |> update_in([:pending_ref_index], &Map.delete(&1, pending.caller_ref))

          {:reply, :ok, state}
        else
          {:reply, {:error, :no_owned_lifetime}, state}
        end

      _ ->
        {:reply, {:error, :not_pending}, state}
    end
  end

  defp serve({:yielded_launch, id}, _from, state) do
    yielded =
      case Map.get(state.pending, id) do
        %{caller: nil, owner: owner} when is_pid(owner) -> Process.alive?(owner)
        _ -> false
      end

    {:reply, yielded, state}
  end

  defp serve(:background_counts, _from, state) do
    counts = capacity_counts() |> Map.new(fn {key, count} -> {key, min(count, 1_000_000)} end)
    {:reply, Map.put(counts, :limit, state.background_limit), state}
  end

  defp serve(:background_capacity_available, _from, state) do
    {:reply, state.occupied < state.background_limit, state}
  end

  defp serve({:cancel_launch, id, owner}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
        [{^id, %{owner: ^owner, launch_classification: :queued} = record, logs}] ->
          record = Map.merge(record, %{launch_classification: :canceled, status: :canceled})
          persist_launch(id, record, logs)
          notify_capacity(state, {:background_launch_canceled, id})
          :ok

        [{^id, %{owner: ^owner, launch_classification: :canceled}, _}] ->
          :ok

        [{^id, %{owner: ^owner}, _}] ->
          {:error, :already_started}

        _ ->
          {:error, :not_found}
      end

    state = if reply == :ok, do: forget_pending(state, id), else: state
    {:reply, reply, state}
  end

  defp serve({:confirm_termination, id, cause}, _from, state) do
    state =
      case :ets.lookup(@table, id) do
        [{^id, %{status: :cleared}, _}] ->
          state

        [{^id, record, logs}] ->
          terminal = Map.get(record, :launch_classification) in [:rejected, :expired, :canceled]

          if Map.get(record, :termination_confirmed, false) or
               ((cause == :startup_failed or match?({:startup_failed, _}, cause)) and terminal) do
            state
          else
            held = capacity_held?(record)
            record = confirmed_record(record, cause)
            persist_launch(id, record, logs)
            notify_capacity(state, :background_capacity_changed)
            state = if held, do: %{state | occupied: state.occupied - 1}, else: state
            state |> forget_pending(id) |> forget_live(id)
          end

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  defp serve({:launch_receipt, id, owner}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
        [{^id, %{owner: ^owner, launch_fingerprint: fingerprint} = record, logs}]
        when is_binary(fingerprint) ->
          record = reconcile_launch_record(id, record, logs)
          {:ok, CodingAgent.ProcessStore.receipt(record)}

        _ ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  defp serve({:cleanup, ttl_seconds}, _from, state) do
    deleted_count = DurableTable.cleanup(state, ttl_seconds, &delete_process/1)
    {:reply, {:ok, deleted_count}, state}
  end

  defp serve(:clear, _from, state) do
    # Test reset wipes launch tombstones and held reservations too, but keeps a
    # record (and its artifact charge) whose output file could not be removed.
    failed? =
      :ets.foldl(
        fn {id, record, _logs}, failed? ->
          case CodingAgent.ProcessStore.remove_output(record) do
            :ok ->
              DurableTable.delete(state.table, id)
              failed?

            _ ->
              true
          end
        end,
        false,
        @table
      )

    DurableTable.sync(state.table)

    state = Enum.reduce(Map.keys(state.pending), state, &forget_pending(&2, &1))
    state = Enum.reduce(Map.keys(state.live_identity_index), state, &forget_live(&2, &1))
    reply = if failed?, do: {:error, :output_cleanup_failed}, else: :ok

    {:reply, reply, %{state | occupied: capacity_counts().occupied}}
  end

  defp serve(
         {:reserve_artifact, process_id, requested, owner_budget, runtime_budget},
         _from,
         state
       ) do
    {:reply, do_reserve_artifact(process_id, requested, owner_budget, runtime_budget), state}
  end

  @impl true
  def handle_info(message, state) do
    serve_info(message, state)
  rescue
    error ->
      Logger.warning("Process store event failed: #{inspect(error.__struct__)}")
      {:noreply, state}
  catch
    :throw, :store_unavailable -> {:noreply, state}
  end

  defp serve_info(:cleanup, state) do
    state = ensure_tables(state)

    DurableTable.periodic_cleanup(state, &delete_process/1)
    {:noreply, state}
  end

  defp serve_info({:pending_launch_deadline, id}, state) do
    {:noreply, terminalize_pending(state, id, :expired, :admission_deadline)}
  end

  defp serve_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      Map.get(state.capacity_subscribers, pid) == ref ->
        {:noreply, update_in(state.capacity_subscribers, &Map.delete(&1, pid))}

      Map.has_key?(state.pending_ref_index, ref) ->
        id = Map.fetch!(state.pending_ref_index, ref)
        {:noreply, terminalize_pending(state, id, :canceled, :owner_abandoned)}

      Map.has_key?(state.live_ref_index, ref) ->
        id = Map.fetch!(state.live_ref_index, ref)
        {:noreply, lose_live_owner(state, id)}

      true ->
        {:noreply, state}
    end
  end

  defp serve_info(_message, state), do: {:noreply, state}

  # Owner-side record operations. Each reads the current tuple in this mailbox.
  defp attach_process(id, %{owner: owner, fingerprint: fingerprint} = attachment, record) do
    case :ets.lookup(@table, id) do
      [{^id, %{status: :cleared}, _}] ->
        {:error, "process identity cleared"}

      [{^id, %{owner: ^owner, launch_fingerprint: ^fingerprint} = launch, logs}]
      when is_binary(fingerprint) ->
        attached =
          attachment.metadata
          |> Enum.reduce(launch, fn {key, value}, acc -> Map.put_new(acc, key, value) end)
          |> Map.put(:updated_at, System.system_time(:second))

        DurableTable.put(@table, {id, attached, logs}, :sync)

      [{^id, %{launch_fingerprint: existing}, _}] when is_binary(existing) ->
        {:error, "process launch identity conflict"}

      _ when is_binary(fingerprint) ->
        {:error, "managed process launch missing"}

      _ ->
        insert_record(id, record, [])
    end
  end

  defp append_logs(id, lines, opts) do
    case :ets.lookup(@table, id) do
      [{^id, %{status: :cleared}, _}] ->
        :ok

      [{^id, record, logs}] ->
        logs = Enum.reverse(lines, logs) |> Enum.take(Keyword.get(opts, :keep, @max_log_lines))
        total = Map.get(record, :total_lines, 0) + length(lines)

        record =
          record
          |> Map.put(:updated_at, System.system_time(:second))
          |> Map.put(:log_line_count, length(logs))
          |> Map.put(:total_lines, Keyword.get(opts, :total_lines, total))
          |> Map.put(:output, Keyword.get(opts, :output, Map.get(record, :output)))
          |> Map.put(:partial_line, Keyword.get(opts, :partial_line, ""))
          |> Map.put(
            :read_cursor,
            Keyword.get(opts, :read_cursor, Map.get(record, :read_cursor, 0))
          )

        insert_record(id, record, logs)

      _ ->
        :ok
    end
  end

  defp update_record(id, changes, durable) do
    case :ets.lookup(@table, id) do
      [{^id, %{status: :cleared}, _}] ->
        :ok

      [{^id, record, logs}] ->
        updated =
          record
          |> Map.merge(changes)
          |> Map.put(:updated_at, System.system_time(:second))

        if durable and is_binary(Map.get(updated, :launch_fingerprint)) do
          # Owned workload provenance must survive a crash before the command
          # is unblocked; do not publish a volatile identity before syncing it.
          :ok = DurableTable.put(@table, {id, updated, logs}, :sync)
          CodingAgent.ProcessStore.notify_change(id)
        else
          insert_record(id, updated, logs)
        end

      _ ->
        :ok
    end
  end

  defp insert_record(id, record, logs) do
    case :ets.lookup(@table, id) do
      [{^id, %{status: :cleared}, _}] ->
        :ok

      _ ->
        :ok = DurableTable.put(@table, {id, record, logs})
        CodingAgent.ProcessStore.notify_change(id)
    end
  end

  defp delete_process(id) do
    case :ets.lookup(@table, id) do
      [{^id, %{status: :cleared}, _}] ->
        :ok

      [{^id, %{launch_fingerprint: fingerprint} = record, _}] when is_binary(fingerprint) ->
        delete_record(id, record)

      [{^id, record, _}] ->
        if capture_open?(id, record),
          do: {:error, :process_alive},
          else: delete_record(id, record)

      [] ->
        :ok
    end
  end

  defp delete_record(id, %{launch_fingerprint: fingerprint} = record)
       when is_binary(fingerprint) do
    held =
      Map.get(
        record,
        :capacity_held,
        Map.get(record, :status) in [:running, :starting, :killing, :lost]
      ) and
        not Map.get(record, :termination_confirmed, false)

    unknown =
      Map.get(record, :launch_classification) == :outcome_unknown and
        not Map.get(record, :termination_confirmed, false)

    pending = Map.get(record, :launch_classification) == :queued

    if held or unknown or pending or capture_open?(id, record) do
      {:error, :process_not_terminal}
    else
      with :ok <- CodingAgent.ProcessStore.remove_output(record) do
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
          |> Map.put(:capacity_held, false)
          |> Map.put(:launch_terminal_status, Map.get(record, :status))
          |> Map.put(:status, :cleared)

        :ok = DurableTable.put(@table, {id, tombstone, []}, :sync)
        CodingAgent.ProcessStore.notify_change(id)
      end
    end
  end

  defp delete_record(id, record) do
    with :ok <- CodingAgent.ProcessStore.remove_output(record) do
      :ok = DurableTable.delete(@table, id)
      CodingAgent.ProcessStore.notify_change(id)
    end
  end

  defp capture_open?(id, record) do
    session_alive?(id) and get_in(record, [:output, :finalized]) != true
  end

  # No external start may be acknowledged with only volatile provenance. A
  # failed write is a `:store_unavailable` reply to the request that needed it.
  defp persist_launch(id, record, logs) do
    :ok = DurableTable.put(@table, {id, record, logs}, :sync)
    CodingAgent.ProcessStore.notify_change(id)
  rescue
    _ -> throw(:store_unavailable)
  end

  defp reconcile_launch_record(id, record, logs) do
    if Map.get(record, :status) in [:running, :starting, :killing] and
         not session_alive?(id) do
      record =
        Map.merge(record, %{status: :lost, launch_classification: :outcome_unknown})

      persist_launch(id, record, logs)
      record
    else
      record
    end
  end

  defp notify_capacity(state, message) do
    Enum.each(state.capacity_subscribers, fn {pid, _ref} -> send(pid, message) end)
  end

  defp capacity_counts do
    :ets.foldl(
      fn {_id, record, _logs}, counts ->
        classification = Map.get(record, :launch_classification)
        status = Map.get(record, :status)

        held = capacity_held?(record)

        counts = if held, do: Map.update!(counts, :occupied, &(&1 + 1)), else: counts

        cond do
          classification == :outcome_unknown or (held and status in [:starting, :lost]) ->
            Map.update!(counts, :unknown, &(&1 + 1))

          held ->
            Map.update!(counts, :active, &(&1 + 1))

          classification in [:queued, :rejected, :expired, :canceled] ->
            Map.update!(counts, classification, &(&1 + 1))

          true ->
            counts
        end
      end,
      %{active: 0, queued: 0, rejected: 0, expired: 0, canceled: 0, unknown: 0, occupied: 0},
      @table
    )
  end

  defp capacity_held?(record) do
    unwitnessed_lost? =
      Map.get(record, :status) == :lost and
        not is_binary(Map.get(record, :launch_fingerprint)) and
        not LemonCore.ProcessGroup.valid_identity?(Map.get(record, :workload_identity)) and
        not session_alive?(Map.get(record, :id))

    cond do
      unwitnessed_lost? ->
        false

      Map.has_key?(record, :capacity_held) ->
        Map.get(record, :capacity_held) and not Map.get(record, :termination_confirmed, false)

      true ->
        Map.get(record, :status) in [:running, :starting, :killing, :lost] and
          not Map.get(record, :termination_confirmed, false)
    end
  end

  defp track_pending(state, id, {caller, _tag}, owner, deadline) do
    caller_ref = Process.monitor(caller)
    owner_ref = if is_pid(owner) and owner != caller, do: Process.monitor(owner)

    timer =
      Process.send_after(
        self(),
        {:pending_launch_deadline, id},
        max(deadline - System.system_time(:millisecond), 0)
      )

    refs = Enum.reject([caller_ref, owner_ref], &is_nil/1)

    state
    |> put_in([:pending, id], %{
      refs: refs,
      timer: timer,
      caller: caller,
      caller_ref: caller_ref,
      owner: owner
    })
    |> update_in([:pending_ref_index], fn index ->
      Enum.reduce(refs, index, &Map.put(&2, &1, id))
    end)
  end

  defp forget_pending(state, id) do
    case Map.get(state.pending, id) do
      nil ->
        state

      pending ->
        Enum.each(pending.refs, &Process.demonitor(&1, [:flush]))
        Process.cancel_timer(pending.timer)

        state
        |> update_in([:pending], &Map.delete(&1, id))
        |> update_in([:pending_ref_index], fn index ->
          Enum.reduce(pending.refs, index, &Map.delete(&2, &1))
        end)
    end
  end

  defp pending_abandoned?(state, id) do
    case Map.get(state.pending, id) do
      nil ->
        true

      pending ->
        (is_pid(pending.caller) and not Process.alive?(pending.caller)) or
          (is_pid(pending.owner) and not Process.alive?(pending.owner))
    end
  end

  defp terminalize_pending(state, id, classification, reason) do
    case :ets.lookup(@table, id) do
      [{^id, %{launch_classification: :queued} = record, logs}] ->
        record =
          Map.merge(record, %{
            launch_classification: classification,
            launch_reason: reason,
            status: classification
          })

        persist_launch(id, record, logs)

        message =
          if classification == :canceled,
            do: {:background_launch_canceled, id},
            else: {:background_launch_classified, id, classification}

        notify_capacity(state, message)

      _ ->
        :ok
    end

    forget_pending(state, id)
  end

  defp confirmed_record(record, cause) do
    record = Map.merge(record, %{capacity_held: false, termination_confirmed: true})

    cond do
      cause == :startup_failed or match?({:startup_failed, _}, cause) ->
        reason = if cause == :startup_failed, do: cause, else: elem(cause, 1)

        Map.merge(record, %{
          status: :error,
          launch_classification: :rejected,
          launch_reason: reason,
          completed_at: System.system_time(:second)
        })

      cause == :external_confirmed ->
        Map.merge(record, %{status: :killed, completed_at: System.system_time(:second)})

      is_binary(Map.get(record, :launch_fingerprint)) ->
        Map.put(record, :launch_classification, :accepted)

      true ->
        record
    end
  end

  defp track_live(state, id, pid) do
    ref = Process.monitor(pid)

    state
    |> put_in([:live_ref_index, ref], id)
    |> put_in([:live_identity_index, id], ref)
  end

  defp forget_live(state, id) do
    case Map.get(state.live_identity_index, id) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])

        state
        |> update_in([:live_ref_index], &Map.delete(&1, ref))
        |> update_in([:live_identity_index], &Map.delete(&1, id))
    end
  end

  defp lose_live_owner(state, id) do
    state =
      case :ets.lookup(@table, id) do
        [{^id, record, logs}] ->
          if capacity_held?(record) do
            record = Map.merge(record, %{status: :lost, launch_classification: :outcome_unknown})
            persist_launch(id, record, logs)
            notify_capacity(state, {:background_launch_classified, id, :outcome_unknown})

            if capacity_held?(record) do
              state
            else
              notify_capacity(state, :background_capacity_changed)
              %{state | occupied: state.occupied - 1}
            end
          else
            state
          end

        _ ->
          state
      end

    forget_live(state, id)
  end

  defp reconcile_live_owners(state) do
    :ets.foldl(
      fn {id, record, _logs}, state ->
        state = forget_live(state, id)

        if capacity_held?(record) do
          case Registry.lookup(CodingAgent.ProcessRegistry, id) do
            [{pid, _}] -> track_live(state, id, pid)
            _ -> state
          end
        else
          state
        end
      end,
      state,
      @table
    )
  end

  defp session_alive?(id) do
    CodingAgent.ProcessSession.alive?(id)
  rescue
    _ -> false
  end

  defp ensure_tables(state), do: DurableTable.ensure(state)

  @doc false
  def normalize_row({process_id, record, logs}, state) do
    record =
      cond do
        record[:status] == :queued and is_binary(record[:launch_fingerprint]) and
            not Map.has_key?(state.pending, process_id) ->
          Map.merge(record, %{
            status: :canceled,
            launch_classification: :canceled,
            launch_reason: :admission_owner_restarted
          })

        record[:status] == :queued and Map.has_key?(state.pending, process_id) ->
          record

        record[:status] in [:running, :starting, :killing, :queued] and
            not session_alive?(process_id) ->
          record = Map.merge(record, %{status: :lost, error: :lost_on_restart})

          if is_binary(record[:launch_fingerprint]) do
            Map.put(record, :launch_classification, :outcome_unknown)
          else
            Map.put(record, :completed_at, System.system_time(:second))
          end

        true ->
          record
      end

    {process_id, reconcile_boot_workload(process_id, record), logs}
  end

  defp reconcile_boot_workload(id, %{status: :lost, workload_identity: identity} = record)
       when is_map(identity) do
    if session_alive?(id) do
      record
    else
      case LemonCore.ProcessGroup.workload_group_status(
             identity,
             Map.get(record, :root_exited, false)
           ) do
        :terminated -> confirmed_record(record, :workload_empty)
        {_status, observed} -> Map.put(record, :workload_identity, observed)
      end
    end
  end

  defp reconcile_boot_workload(_id, record), do: record

  @doc false
  def restore_capacity(state) do
    # Late opens and reopens restore capacity/owner monitors before admission.
    state
    |> Map.put(:occupied, capacity_counts().occupied)
    |> reconcile_live_owners()
  end

  @doc false
  def expiry_timestamp({_id, record, _logs}) do
    if record[:status] in [:completed, :error, :killed, :lost, :rejected, :expired, :canceled] and
         record[:launch_classification] != :outcome_unknown and not capacity_held?(record),
       do: DurableTable.terminal_timestamp(record)
  end

  defp do_reserve_artifact(process_id, requested, owner_budget, runtime_budget) do
    case :ets.lookup(@table, process_id) do
      [{^process_id, %{status: :cleared}, _}] ->
        {:error, :not_found}

      [{^process_id, record, logs}] ->
        owner = Map.get(record, :owner)

        # Project records, not log buffers: aggregate accounting must not copy
        # every process's retained output into the store server's heap.
        records = :ets.select(@table, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

        with true <- dets_open?(),
             {:ok, {owner_usage, runtime_usage, reclaimable}} <-
               artifact_usage(records, process_id, owner) do
          candidates = Enum.sort_by(reclaimable, fn {id, other} -> {finished_at(other), id} end)
          owned = Enum.filter(candidates, fn {_id, other} -> Map.get(other, :owner) == owner end)

          {owner_usage, runtime_usage} =
            reclaim_artifacts(
              owned,
              owner_usage,
              runtime_usage,
              requested,
              owner_budget,
              :owner,
              owner
            )

          {owner_usage, runtime_usage} =
            reclaim_artifacts(
              candidates,
              owner_usage,
              runtime_usage,
              requested,
              runtime_budget,
              :runtime,
              owner
            )

          granted =
            requested
            |> min(owner_budget - owner_usage)
            |> min(runtime_budget - runtime_usage)
            |> max(0)

          output = Map.put(Map.get(record, :output) || %{}, :artifact_capacity, granted)
          entry = {process_id, Map.put(record, :output, output), logs}
          DurableTable.put(@table, entry, :mirror)

          # Do not launch a writer with a reservation that restart cannot recover.
          # On failure the ETS charge stays conservative until startup cleanup.
          case DurableTable.persist(@table, entry, true) do
            :ok -> {:ok, granted}
            _ -> {:error, :artifact_accounting_unavailable}
          end
        else
          _ -> {:error, :artifact_accounting_unavailable}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp artifact_usage(records, process_id, owner) do
    Enum.reduce_while(records, {:ok, {0, 0, []}}, fn
      {id, _other}, acc when id == process_id ->
        {:cont, acc}

      {id, other}, {:ok, {owned, total, candidates}} ->
        case artifact_charge(other) do
          :unknown ->
            {:halt, {:error, :artifact_accounting_unavailable}}

          charge ->
            owned = owned + if(Map.get(other, :owner) == owner, do: charge, else: 0)

            candidates =
              if charge > 0 and reclaimable?(id),
                do: [{id, other} | candidates],
                else: candidates

            {:cont, {:ok, {owned, total + charge, candidates}}}
        end
    end)
  end

  # Deletes the oldest artifacts of stopped sessions until the reservation
  # fits. Records stay readable; they report the reclamation instead of a
  # dangling path.
  defp reclaim_artifacts([], owned, total, _requested, _budget, _scope, _owner),
    do: {owned, total}

  defp reclaim_artifacts([{id, _snapshot} | older], owned, total, requested, budget, scope, owner) do
    usage = if scope == :owner, do: owned, else: total

    if usage + requested <= budget do
      {owned, total}
    else
      # A previous pass may already have reclaimed this file. Re-read its
      # charge, and keep accounting unchanged when deletion fails.
      {owned, total} =
        case :ets.lookup(@table, id) do
          [{^id, record, logs}] ->
            charge = artifact_charge(record)

            if is_integer(charge) and charge > 0 and reclaimable?(id) and
                 CodingAgent.ProcessStore.remove_output(record) == :ok do
              output =
                (Map.get(record, :output) || %{})
                |> Map.merge(%{artifact_capacity: 0, artifact_reclaimed: true})

              reclaimed = record |> Map.put(:full_output_path, nil) |> Map.put(:output, output)
              insert_record(id, reclaimed, logs)
              {owned - if(Map.get(record, :owner) == owner, do: charge, else: 0), total - charge}
            else
              {owned, total}
            end

          _ ->
            {owned, total}
        end

      reclaim_artifacts(older, owned, total, requested, budget, scope, owner)
    end
  end

  # A running process is charged its reserved capacity; a finished one the
  # bytes it wrote (its session shrinks the reservation when it finalizes).
  defp artifact_charge(record) do
    case Map.get(record, :output) do
      %{artifact_capacity: capacity} when is_integer(capacity) and capacity > 0 ->
        capacity

      _ ->
        # Pre-quota persisted records still occupy disk and must count toward
        # aggregate reclamation after upgrading.
        case Map.get(record, :full_output_path) do
          path when is_binary(path) ->
            case File.stat(path) do
              {:ok, %{type: :regular, size: size}} -> size
              {:error, :enoent} -> 0
              _ -> :unknown
            end

          _ ->
            0
        end
    end
  end

  # Only a stopped session's file is safe to delete: a live session may still
  # write to it. Stopped covers finished, lost and orphaned running records.
  defp reclaimable?(process_id), do: not CodingAgent.ProcessSession.alive?(process_id)

  defp finished_at(record),
    do: Map.get(record, :completed_at) || Map.get(record, :inserted_at) || 0

  defp dets_open?, do: DurableTable.open?(@dets_table)

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :process_store_path) ||
      CodingAgent.StatePaths.dets_path("processes.dets")
  end
end
