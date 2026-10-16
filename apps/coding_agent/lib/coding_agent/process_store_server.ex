defmodule CodingAgent.ProcessStoreServer do
  @moduledoc """
  GenServer that owns the ProcessStore ETS table and manages DETS persistence.

  Serializes launch admission, lifetime capacity and artifact accounting with
  every record mutation. Reload preserves surviving registered sessions,
  cancels unclaimed queued launches and marks missing live owners as :lost
  without treating their absence as proof of external workload termination.
  """

  use GenServer
  require Logger

  @table :coding_agent_processes
  @dets_table :coding_agent_processes_dets
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300

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

  @doc false
  def transaction(server, fun) when is_function(fun, 0) do
    GenServer.call(server, {:transaction, fun}, 30_000)
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
    # Trap exits to ensure we can close DETS properly
    Process.flag(:trap_exit, true)

    state = %{
      table: @table,
      dets_table: @dets_table,
      dets_path: dets_path(opts),
      ets_initialized: false,
      dets_initialized: false,
      loaded_from_dets: false,
      background_limit: limits.background_process_limit,
      occupied: 0,
      pending_limit: limits.background_pending_limit,
      pending: %{},
      pending_ref_index: %{},
      live_ref_index: %{},
      live_identity_index: %{},
      capacity_subscribers: %{}
    }

    # Initialize tables synchronously during init
    state = initialize_ets(state)
    state = initialize_dets(state)
    state = maybe_load_from_dets(state)

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    state = ensure_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:transaction, fun}, _from, state) do
    state = ensure_tables(state)
    {:reply, fun.(), state}
  end

  def handle_call({:register_launch, id, owner, fingerprint, deadline, owner_pid}, from, state) do
    state = ensure_tables(state)

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

  def handle_call({:claim_launch, id, owner, fingerprint}, {session, _tag}, state) do
    state = ensure_tables(state)

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

  def handle_call({:classify_launch, id, classification, reason}, _from, state) do
    state = ensure_tables(state)

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

  def handle_call({:subscribe_capacity, pid}, _from, state) do
    state =
      if Map.has_key?(state.capacity_subscribers, pid) do
        state
      else
        put_in(state.capacity_subscribers[pid], Process.monitor(pid))
      end

    {:reply, :ok, state}
  end

  def handle_call({:yield_launch, id, owner}, _from, state) do
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

  def handle_call({:yielded_launch, id}, _from, state) do
    yielded =
      case Map.get(state.pending, id) do
        %{caller: nil, owner: owner} when is_pid(owner) -> Process.alive?(owner)
        _ -> false
      end

    {:reply, yielded, state}
  end

  def handle_call(:background_counts, _from, state) do
    state = ensure_tables(state)
    counts = capacity_counts() |> Map.new(fn {key, count} -> {key, min(count, 1_000_000)} end)
    {:reply, Map.put(counts, :limit, state.background_limit), state}
  end

  def handle_call(:background_capacity_available, _from, state) do
    state = ensure_tables(state)
    {:reply, state.occupied < state.background_limit, state}
  end

  def handle_call({:cancel_launch, id, owner}, _from, state) do
    state = ensure_tables(state)

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

  def handle_call({:confirm_termination, id, cause}, _from, state) do
    state = ensure_tables(state)

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

  def handle_call({:launch_receipt, id, owner}, _from, state) do
    state = ensure_tables(state)

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

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    deleted_count = do_cleanup(ttl_seconds)
    {:reply, {:ok, deleted_count}, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    # Test reset wipes launch tombstones and held reservations too, but keeps a
    # record (and its artifact charge) whose output file could not be removed.
    failed? =
      :ets.foldl(
        fn {id, record, _logs}, failed? ->
          case CodingAgent.ProcessStore.remove_output(record) do
            :ok ->
              :ets.delete(@table, id)
              if state.dets_initialized, do: :dets.delete(@dets_table, id)
              failed?

            _ ->
              true
          end
        end,
        false,
        @table
      )

    if state.dets_initialized, do: :dets.sync(@dets_table)

    state = Enum.reduce(Map.keys(state.pending), state, &forget_pending(&2, &1))
    state = Enum.reduce(Map.keys(state.live_identity_index), state, &forget_live(&2, &1))
    reply = if failed?, do: {:error, :output_cleanup_failed}, else: :ok

    {:reply, reply, %{state | loaded_from_dets: false, occupied: capacity_counts().occupied}}
  end

  def handle_call(:dets_status, _from, state) do
    info =
      if state.dets_initialized do
        case :dets.info(@dets_table) do
          :undefined -> %{status: :closed}
          info -> Map.new(info)
        end
      else
        %{status: :not_initialized}
      end

    {:reply, %{info: info, state: Map.drop(state, [:table, :dets_table])}, state}
  end

  def handle_call(
        {:reserve_artifact, process_id, requested, owner_budget, runtime_budget},
        _from,
        state
      ) do
    state = ensure_tables(state)
    {:reply, do_reserve_artifact(process_id, requested, owner_budget, runtime_budget), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)

    ttl_seconds =
      Application.get_env(:coding_agent, :process_store_ttl_seconds, @default_ttl_seconds)

    _deleted_count = do_cleanup(ttl_seconds)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info({:pending_launch_deadline, id}, state) do
    {:noreply, terminalize_pending(state, id, :expired, :admission_deadline)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
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

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Handle linked process exits if needed
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.dets_initialized do
      :dets.close(@dets_table)
    end

    :ok
  end

  # Private Functions
  defp persist_launch(id, record, logs) do
    # No external start may be acknowledged with only volatile provenance.
    true = dets_open?()
    :ok = :dets.insert(@dets_table, {id, record, logs})
    :ok = :dets.sync(@dets_table)
    :ets.insert(@table, {id, record, logs})
    :ok
  rescue
    _ -> exit(:launch_store_unavailable)
  catch
    _, _ -> exit(:launch_store_unavailable)
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
    if Map.has_key?(record, :capacity_held) do
      Map.get(record, :capacity_held) and not Map.get(record, :termination_confirmed, false)
    else
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
    case :ets.lookup(@table, id) do
      [{^id, record, logs}] ->
        if capacity_held?(record) do
          record = Map.merge(record, %{status: :lost, launch_classification: :outcome_unknown})
          persist_launch(id, record, logs)
          notify_capacity(state, {:background_launch_classified, id, :outcome_unknown})
        end

      _ ->
        :ok
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

  defp ensure_tables(state) do
    state =
      state
      |> initialize_ets()
      |> initialize_dets()
      |> maybe_reset_loaded_from_dets()

    state = maybe_load_from_dets(state)

    if state.ets_initialized and state.dets_initialized and state.loaded_from_dets and
         dets_open?() do
      state
    else
      exit(:process_store_unavailable)
    end
  end

  defp initialize_ets(state) do
    if state.ets_initialized do
      state
    else
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          %{state | ets_initialized: true}

        _tid ->
          %{state | ets_initialized: true}
      end
    end
  end

  defp initialize_dets(state) do
    if state.dets_initialized and dets_open?() do
      state
    else
      File.mkdir_p!(Path.dirname(state.dets_path))

      dets_file = String.to_charlist(state.dets_path)

      case :dets.open_file(@dets_table, file: dets_file, type: :set) do
        {:ok, _} ->
          %{state | dets_initialized: true, loaded_from_dets: false}

        {:error, {:already_open, _pid}} ->
          %{state | dets_initialized: true, loaded_from_dets: false}

        {:error, _reason} ->
          Logger.warning("Process launch storage unavailable")
          %{state | dets_initialized: false, loaded_from_dets: false}
      end
    end
  end

  defp maybe_load_from_dets(%{loaded_from_dets: true} = state), do: state

  defp maybe_load_from_dets(state) do
    if state.dets_initialized and state.ets_initialized do
      now = System.system_time(:second)

      :ok =
        :dets.foldl(
          fn {process_id, record, logs}, :ok ->
            record =
              cond do
                Map.get(record, :status) == :queued and
                  is_binary(Map.get(record, :launch_fingerprint)) and
                    not Map.has_key?(state.pending, process_id) ->
                  Map.merge(record, %{
                    status: :canceled,
                    launch_classification: :canceled,
                    launch_reason: :admission_owner_restarted
                  })

                Map.get(record, :status) == :queued and
                    Map.has_key?(state.pending, process_id) ->
                  record

                Map.get(record, :status) in [:running, :starting, :killing, :queued] and
                    not session_alive?(process_id) ->
                  # Losing the BEAM owner is not proof of external termination.
                  record = Map.merge(record, %{status: :lost, error: :lost_on_restart})

                  if is_binary(Map.get(record, :launch_fingerprint)) do
                    Map.put(record, :launch_classification, :outcome_unknown)
                  else
                    Map.put(record, :completed_at, now)
                  end

                true ->
                  record
              end

            :ets.insert(@table, {process_id, record, logs})
            :ok
          end,
          :ok,
          @dets_table
        )

      # Every load, including a late open or a reopened file, restores capacity
      # and owner monitors before the request that triggered it can admit work.
      state
      |> Map.merge(%{loaded_from_dets: true, occupied: capacity_counts().occupied})
      |> reconcile_live_owners()
    else
      state
    end
  rescue
    _ -> exit(:process_store_unavailable)
  catch
    _, _ -> exit(:process_store_unavailable)
  end

  defp maybe_reset_loaded_from_dets(state) do
    if state.loaded_from_dets and state.dets_initialized and state.ets_initialized do
      case :ets.info(@table, :size) do
        0 ->
          case :dets.info(@dets_table, :size) do
            size when is_integer(size) and size > 0 -> %{state | loaded_from_dets: false}
            _ -> state
          end

        _ ->
          state
      end
    else
      state
    end
  end

  defp do_cleanup(ttl_seconds) do
    now = System.system_time(:second)

    expired_ids =
      :ets.foldl(
        fn {process_id, record, _logs}, acc ->
          if expired_record?(record, now, ttl_seconds) do
            [process_id | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    # A finalized session can linger for final polling after its file is closed.
    # Let delete/1 distinguish that safe case from a still-draining capture and
    # preserve the charge when file removal fails.
    deleted_count =
      Enum.count(expired_ids, fn process_id ->
        CodingAgent.ProcessStore.delete(process_id) == :ok
      end)

    if dets_open?() and expired_ids != [] do
      :dets.sync(@dets_table)
    end

    deleted_count
  end

  defp expired_record?(record, now, ttl_seconds) do
    status = Map.get(record, :status)

    if status in [:completed, :error, :killed, :lost, :rejected, :expired, :canceled] and
         Map.get(record, :launch_classification) != :outcome_unknown and
         not capacity_held?(record) do
      completed_at =
        Map.get(record, :completed_at) || Map.get(record, :updated_at) ||
          Map.get(record, :inserted_at)

      is_integer(completed_at) and now - completed_at >= ttl_seconds
    else
      false
    end
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
          :ets.insert(@table, entry)

          # Do not launch a writer with a reservation that restart cannot recover.
          # On failure the ETS charge stays conservative until startup cleanup.
          with :ok <- :dets.insert(@dets_table, entry),
               :ok <- :dets.sync(@dets_table) do
            {:ok, granted}
          else
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
              CodingAgent.ProcessStore.insert_record(id, reclaimed, logs)
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

  defp dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp schedule_cleanup do
    interval =
      Application.get_env(
        :coding_agent,
        :process_store_cleanup_interval_seconds,
        @cleanup_interval_seconds
      )

    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :process_store_path) ||
      Path.join(CodingAgent.Config.agent_dir(), "processes.dets")
  end
end
