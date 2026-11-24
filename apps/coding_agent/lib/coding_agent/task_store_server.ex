defmodule CodingAgent.TaskStoreServer do
  @moduledoc """
  GenServer that owns the TaskStore ETS table and manages DETS persistence.

  All record, event, lifecycle, and followup-suppression mutations pass
  through the server mailbox, so a mutation always reads the latest tuple and
  writes one coherent ETS/DETS snapshot.

  ## Restart semantics

  `CodingAgent.DurableTable` gives the mirror an ETS heir. A crashed owner's
  restart reclaims the live table: queued and running tasks keep their status
  and their workers' later finishes are accepted. Followup join reservations
  are owner state, so reclaim drops their tokens; a join that observed the
  owner going down returns an error and its completions follow up normally.

  Only a boot (first start, application restart or a clean owner stop) loads
  from DETS and normalizes: queued, running, tracking-lost and interrupted
  tasks become `:lost` (or `:interrupted` when crash resume can continue
  them), and that outcome is persisted.
  """

  use CodingAgent.DurableTable

  @table :coding_agent_tasks
  @dets_table :coding_agent_tasks_dets
  @default_ttl_seconds 86_400
  @max_events 100
  @terminal_statuses [:completed, :error, :lost, :killed, :cancelled]

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Returns the ETS table name for direct access by TaskStore API.
  """
  def table_name, do: @table

  @doc """
  Ensure the table is initialized. Called by TaskStore API functions.
  """
  def ensure_table(server \\ __MODULE__) do
    GenServer.call(server, :ensure_table, 5_000)
  end

  @doc "Insert or replace a complete task tuple through the serialized owner."
  @spec insert_record(String.t(), map(), [term()], GenServer.server()) :: :ok
  def insert_record(task_id, record, events, server \\ __MODULE__) do
    GenServer.call(server, {:insert_record, task_id, record, events}, 10_000)
  end

  @doc "Atomically update a task record while preserving its current events."
  @spec update_record(String.t(), (map() -> map()), GenServer.server()) :: :ok
  def update_record(task_id, update_fn, server \\ __MODULE__) do
    GenServer.call(server, {:update_record, task_id, update_fn}, 10_000)
  end

  @doc "Atomically append a bounded event while preserving the current record."
  @spec append_event(String.t(), term(), GenServer.server()) :: :ok
  def append_event(task_id, event, server \\ __MODULE__) do
    GenServer.call(server, {:append_event, task_id, event}, 10_000)
  end

  @doc "Apply a monotonic, idempotent lifecycle transition."
  @spec transition(String.t(), atom(), (map() -> map()), GenServer.server()) :: :ok
  def transition(task_id, target_status, update_fn, server \\ __MODULE__) do
    GenServer.call(server, {:transition, task_id, target_status, update_fn}, 10_000)
  end

  @doc "Start another turn only on a successfully completed idle or parked child."
  def begin_agent_turn(task_id) do
    GenServer.call(__MODULE__, {:begin_agent_turn, task_id}, 10_000)
  end

  @doc "Durably checkpoint a data-only launch before the child's first prompt."
  def checkpoint_launch(task_id, session_id, descriptor) do
    GenServer.call(__MODULE__, {:checkpoint_launch, task_id, session_id, descriptor}, 10_000)
  end

  @doc "Consume one crash continuation attempt without reopening terminal results."
  def claim_restore(task_id, parent_run_id, owner) do
    GenServer.call(__MODULE__, {:claim_restore, task_id, parent_run_id, owner}, 10_000)
  end

  @doc "Atomically reserve task followups for a join owned by the calling process."
  @spec begin_auto_followup_join([String.t()], reference(), GenServer.server()) :: :ok
  def begin_auto_followup_join(task_ids, join_token, server \\ __MODULE__) do
    GenServer.call(server, {:begin_auto_followup_join, task_ids, join_token}, 10_000)
  end

  @doc "Resolve a join reservation and permanently suppress the selected task followups."
  @spec finish_auto_followup_join(
          [String.t()],
          [String.t()],
          reference(),
          GenServer.server()
        ) :: :ok
  def finish_auto_followup_join(task_ids, suppressed_task_ids, join_token, server \\ __MODULE__) do
    GenServer.call(
      server,
      {:finish_auto_followup_join, task_ids, suppressed_task_ids, join_token},
      10_000
    )
  end

  @doc "Delete a task from ETS and DETS through the serialized owner."
  @spec delete_task(String.t(), GenServer.server()) :: :ok
  def delete_task(task_id, server \\ __MODULE__) do
    GenServer.call(server, {:delete_task, task_id}, 10_000)
  end

  @doc """
  Trigger a cleanup of expired tasks.
  """
  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  @doc """
  Clear all tasks from both ETS and DETS.
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

  @doc "Return whether the owned DETS table is open."
  @spec dets_open?(GenServer.server()) :: boolean()
  def dets_open?(server \\ __MODULE__) do
    GenServer.call(server, :dets_open?, 5_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state =
      DurableTable.open(%{join_reservations: %{}, join_monitor_refs: %{}}, opts,
        table: @table,
        dets_table: @dets_table,
        path: dets_path(opts),
        normalize: &__MODULE__.normalize_row/2,
        reclaim: &__MODULE__.reclaim_row/2,
        after_load: &__MODULE__.persist_restored_rows/1,
        timestamp: &__MODULE__.expiry_timestamp/1,
        ttl_key: :task_store_ttl_seconds,
        interval_key: :task_store_cleanup_interval_seconds
      )

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    state = ensure_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:insert_record, task_id, record, events}, _from, state) do
    state = ensure_tables(state)
    do_insert_record(task_id, record, events)
    {:reply, :ok, state}
  end

  def handle_call({:update_record, task_id, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        updated =
          record
          |> update_fn.()
          |> Map.put(:updated_at, System.system_time(:second))

        do_insert_record(task_id, updated, events)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:append_event, task_id, event}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        updated_events = [event | events] |> Enum.take(@max_events)
        updated_record = Map.put(record, :updated_at, System.system_time(:second))
        do_insert_record(task_id, updated_record, updated_events)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:transition, task_id, target_status, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        if transition_allowed?(Map.get(record, :status, :queued), target_status) do
          updated =
            record
            |> update_fn.()
            |> Map.put(:updated_at, System.system_time(:second))

          mode =
            if target_status in @terminal_statuses and
                 (is_map(record[:launch_descriptor]) or
                    (record[:orchestration_worker] == true and
                       CodingAgent.Tools.Task.Restore.enabled?())),
               do: durable_mode(state),
               else: :write

          do_insert_record(task_id, updated, events, mode)
        end

        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:checkpoint_launch, task_id, session_id, descriptor}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, %{status: :running} = record, events}] ->
        record =
          record
          |> Map.put(:session_id, session_id)
          |> Map.put(:launch_descriptor, descriptor)
          |> Map.put(:session_file, descriptor && descriptor.start_opts[:session_file])

        do_insert_record(task_id, record, events, durable_mode(state))

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:claim_restore, task_id, parent_run_id, owner}, _from, state) do
    state = ensure_tables(state)

    reply =
      case :ets.lookup(@table, task_id) do
        [{^task_id, %{status: :interrupted, parent_run_id: ^parent_run_id} = record, events}] ->
          attempts = Map.get(record, :restart_attempt, 0)

          if CodingAgent.Tools.Task.Restore.enabled?() and
               CodingAgent.Tools.Task.Restore.resumable?(record[:launch_descriptor]) and
               attempts < CodingAgent.Tools.Task.Restore.max_attempts() and
               DurableTable.open?(state.dets_table) do
            updated =
              record
              |> Map.drop([:error, :completed_at])
              |> Map.merge(%{
                status: :running,
                agent_state: :running,
                owner: owner,
                parent_session_id: elem(owner, 0),
                restart_attempt: attempts + 1,
                updated_at: System.system_time(:second)
              })
              |> Map.update(:agent_turn, 1, &(&1 + 1))

            do_insert_record(task_id, updated, events, :sync)
            {:ok, updated}
          else
            {:error, :not_resumable}
          end

        _ ->
          {:error, :not_interrupted}
      end

    {:reply, reply, state}
  end

  def handle_call({:begin_agent_turn, task_id}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, %{status: :completed, agent_state: phase} = record, events}]
      when phase in [:idle, :parked] ->
        now = System.system_time(:second)

        record =
          record
          |> Map.drop([
            :result,
            :error,
            :completed_at,
            :auto_followup_suppressed_at,
            :wait_observed_at,
            :auto_followup_join_tokens
          ])
          |> Map.merge(%{
            status: :running,
            agent_state: :running,
            started_at: now,
            updated_at: now
          })
          |> Map.update(:agent_turn, 1, &(&1 + 1))

        do_insert_record(task_id, record, events)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, "Child cannot start another turn; read history://#{task_id}"}, state}
    end
  end

  def handle_call({:begin_auto_followup_join, task_ids, join_token}, {owner, _tag}, state) do
    state = ensure_tables(state)
    task_ids = Enum.uniq(task_ids)

    Enum.each(task_ids, fn task_id ->
      update_task_record(task_id, fn record ->
        tokens = Map.get(record, :auto_followup_join_tokens, [])
        Map.put(record, :auto_followup_join_tokens, Enum.uniq([join_token | tokens]))
      end)
    end)

    state = track_join_reservation(state, join_token, owner, task_ids)
    {:reply, :ok, state}
  end

  def handle_call(
        {:finish_auto_followup_join, task_ids, suppressed_task_ids, join_token},
        _from,
        state
      ) do
    state = ensure_tables(state)
    suppressed = MapSet.new(suppressed_task_ids)

    Enum.each(Enum.uniq(task_ids), fn task_id ->
      update_task_record(task_id, fn record ->
        current_turn? = join_token in Map.get(record, :auto_followup_join_tokens, [])
        record = remove_join_token(record, join_token)

        if current_turn? and MapSet.member?(suppressed, task_id) do
          Map.put(record, :auto_followup_suppressed_at, System.system_time(:second))
        else
          record
        end
      end)
    end)

    {:reply, :ok, release_join_reservation(state, join_token)}
  end

  def handle_call({:delete_task, task_id}, _from, state) do
    state = ensure_tables(state)
    record = :ets.lookup_element(state.table, task_id, 2, %{})
    DurableTable.delete(state.table, task_id)

    notify_change(task_id, record)

    {:reply, :ok, state}
  end

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    deleted_count = DurableTable.cleanup(state, ttl_seconds, &delete_expired_task/1)
    {:reply, {:ok, deleted_count}, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)
    state = release_all_join_reservations(state)

    DurableTable.clear(state)
    {:reply, :ok, state}
  end

  def handle_call(:dets_status, _from, state) do
    {:reply, DurableTable.status(state), state}
  end

  def handle_call(:dets_open?, _from, state) do
    {:reply, DurableTable.open?(state.dets_table), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)
    DurableTable.periodic_cleanup(state, &delete_expired_task/1)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.join_monitor_refs, monitor_ref) do
      {nil, _join_monitor_refs} ->
        {:noreply, state}

      {join_token, join_monitor_refs} ->
        {reservation, join_reservations} = Map.pop(state.join_reservations, join_token)

        Enum.each(reservation.task_ids, fn task_id ->
          update_task_record(task_id, &remove_join_token(&1, join_token))
        end)

        {:noreply,
         %{state | join_reservations: join_reservations, join_monitor_refs: join_monitor_refs}}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Handle linked process exits if needed
    {:noreply, state}
  end

  # Private Functions

  defp ensure_tables(state), do: DurableTable.ensure(state)

  # Owner restart only: live task state stands; join reservations died with
  # the previous owner.
  @doc false
  def reclaim_row({task_id, record, events}, _state) do
    if Map.has_key?(record, :auto_followup_join_tokens),
      do: {task_id, Map.delete(record, :auto_followup_join_tokens), events},
      else: {task_id, record, events}
  end

  # Boot only: no worker survived, so non-terminal tasks are resolved.
  @doc false
  def normalize_row({task_id, record, events}, _state) do
    record =
      record
      |> Map.delete(:auto_followup_join_tokens)
      |> then(fn record ->
        if record[:agent_state] in [:running, :idle, :parked],
          do: Map.put(record, :agent_state, :aborted),
          else: record
      end)
      |> then(fn record ->
        status = Map.get(record, :status)

        if status in [:queued, :running, :tracking_lost, :interrupted] do
          resumable? =
            status in [:running, :interrupted] and
              CodingAgent.Tools.Task.Restore.enabled?() and
              CodingAgent.Tools.Task.Restore.resumable?(record[:launch_descriptor]) and
              Map.get(record, :restart_attempt, 0) < CodingAgent.Tools.Task.Restore.max_attempts()

          record
          |> Map.put(:status, if(resumable?, do: :interrupted, else: :lost))
          |> Map.put(:error, if(resumable?, do: :outcome_unknown, else: :lost_on_restart))
          |> Map.put(:completed_at, System.system_time(:second))
        else
          record
        end
      end)

    {task_id, record, events}
  end

  @doc false
  def persist_restored_rows(state) do
    :ets.foldl(
      fn
        {_, %{status: status}, _} = row, :ok when status in [:lost, :interrupted] ->
          DurableTable.persist(state.table, row)

        _row, :ok ->
          :ok
      end,
      :ok,
      state.table
    )

    :ok = DurableTable.sync(state.table)
    state
  end

  defp do_insert_record(task_id, record, events, mode \\ :write) do
    :ok = DurableTable.put(@table, {task_id, record, events}, mode)
    notify_change(task_id, record)
  end

  defp durable_mode(state), do: if(DurableTable.open?(state.dets_table), do: :sync, else: :write)

  defp delete_expired_task(task_id) do
    record = :ets.lookup_element(@table, task_id, 2, %{})
    :ok = DurableTable.delete(@table, task_id)
    notify_change(task_id, record)
  end

  defp notify_change(task_id, record) do
    LemonCore.Bus.broadcast("task_state:#{task_id}", {:task_state, :changed, task_id})

    if is_binary(record[:parent_run_id]) do
      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(record.parent_run_id),
        {:task_state, :changed, task_id}
      )
    end

    :ok
  end

  defp update_task_record(task_id, update_fn) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        updated =
          record
          |> update_fn.()
          |> Map.put(:updated_at, System.system_time(:second))

        do_insert_record(task_id, updated, events)

      _ ->
        :ok
    end
  end

  defp track_join_reservation(state, join_token, owner, task_ids) do
    case Map.get(state.join_reservations, join_token) do
      nil ->
        monitor_ref = Process.monitor(owner)

        reservation = %{
          owner: owner,
          monitor_ref: monitor_ref,
          task_ids: task_ids
        }

        %{
          state
          | join_reservations: Map.put(state.join_reservations, join_token, reservation),
            join_monitor_refs: Map.put(state.join_monitor_refs, monitor_ref, join_token)
        }

      _reservation ->
        state
    end
  end

  defp release_join_reservation(state, join_token) do
    case Map.pop(state.join_reservations, join_token) do
      {nil, _join_reservations} ->
        state

      {%{monitor_ref: monitor_ref}, join_reservations} ->
        Process.demonitor(monitor_ref, [:flush])

        %{
          state
          | join_reservations: join_reservations,
            join_monitor_refs: Map.delete(state.join_monitor_refs, monitor_ref)
        }
    end
  end

  defp release_all_join_reservations(state) do
    Enum.each(state.join_reservations, fn {_join_token, %{monitor_ref: monitor_ref}} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    %{state | join_reservations: %{}, join_monitor_refs: %{}}
  end

  defp remove_join_token(record, join_token) do
    Map.update(record, :auto_followup_join_tokens, [], fn tokens ->
      Enum.reject(tokens, &(&1 == join_token))
    end)
  end

  defp transition_allowed?(status, _target_status) when status in @terminal_statuses,
    do: false

  defp transition_allowed?(:running, :running), do: false
  defp transition_allowed?(:queued, :running), do: true
  defp transition_allowed?(status, :tracking_lost) when status in [:queued, :running], do: true

  defp transition_allowed?(:tracking_lost, target_status),
    do: target_status in @terminal_statuses

  defp transition_allowed?(status, target_status)
       when status in [:queued, :running, :interrupted],
       do: target_status in @terminal_statuses

  defp transition_allowed?(_status, _target_status), do: false

  @doc false
  def expiry_timestamp({_id, record, _events}) do
    if record[:status] in [:interrupted | @terminal_statuses] and record[:agent_state] != :idle,
      do: DurableTable.terminal_timestamp(record)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :task_store_path) ||
      CodingAgent.StatePaths.dets_path("tasks.dets")
  end
end
