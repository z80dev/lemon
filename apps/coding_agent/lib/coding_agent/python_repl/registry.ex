defmodule CodingAgent.PythonRepl.Registry do
  @moduledoc """
  The serialized ownership and lifetime authority for persistent Python kernels.

  Workers are never registered by key. This GenServer owns the key-to-worker
  mapping and monitors both workers and owners, which makes invalidation,
  capacity admission, and delayed `:DOWN` messages race-safe.

  Logical stops synchronously release an entry's ownership, lease, and capacity
  bookkeeping, then physical termination runs outside this GenServer. A worker
  that has not yet died is quarantined by its original monitor; it is excluded
  from capacity, reported as `:unreachable` in snapshots, and retried by
  reaping after a failed stop. Only the registry's worker monitor finalizes that
  quarantine, so a delayed `:DOWN` cannot affect a replacement generation.
  """

  use GenServer

  alias CodingAgent.PythonRepl.{Key, Session, SessionSupervisor, Telemetry}

  @default_max_live_kernels 16
  @default_idle_timeout_ms 1_800_000
  @default_reap_interval_ms 60_000
  @known_phases [:starting, :idle, :running, :cancelling, :stopping]
  @attachable_phases [:starting, :idle, :running]

  @typep effective_key :: Key.t() | {:fork, Key.t(), pid()}
  @opaque lease ::
            {module(), effective_key(), reference(), pos_integer(), pid(), reference()}
  @type allocation :: %{
          pid: pid(),
          generation: pos_integer(),
          reused?: boolean(),
          session_mod: module(),
          lease: lease()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec acquire(GenServer.server(), Key.t(), pid(), keyword()) ::
          {:ok, allocation()} | {:error, term()}
  def acquire(server, %Key{} = key, owner_pid, worker_opts \\ []) when is_pid(owner_pid) do
    GenServer.call(server, {:acquire, key, owner_pid, worker_opts}, :infinity)
  end

  @spec release(GenServer.server(), lease()) :: :ok | {:error, :invalid_lease}
  def release(server, lease) do
    GenServer.call(server, {:release, lease}, :infinity)
  end

  @spec reset(GenServer.server(), Key.t(), pid()) ::
          {:ok, %{reset_performed: boolean(), forked: boolean()}}
  def reset(server, %Key{} = key, owner_pid) when is_pid(owner_pid) do
    GenServer.call(server, {:reset, key, owner_pid}, :infinity)
  end

  @spec detach_owner(GenServer.server(), pid()) :: :ok
  def detach_owner(server, owner_pid) when is_pid(owner_pid) do
    GenServer.call(server, {:detach_owner, owner_pid}, :infinity)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot, :infinity)

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max_live_kernels, @default_max_live_kernels)
    idle = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)
    interval = Keyword.get(opts, :reap_interval_ms, @default_reap_interval_ms)
    now_ms = Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    unless is_integer(max) and max > 0,
      do: raise(ArgumentError, ":max_live_kernels must be positive")

    unless idle == :infinity or (is_integer(idle) and idle > 0),
      do: raise(ArgumentError, ":idle_timeout_ms must be positive or :infinity")

    unless is_integer(interval) and interval > 0,
      do: raise(ArgumentError, ":reap_interval_ms must be positive")

    unless is_function(now_ms, 0),
      do: raise(ArgumentError, ":now_ms must be a zero-arity function")

    state = %{
      entries: %{},
      worker_refs: %{},
      lease_refs: %{},
      owner_refs: %{},
      owner_entries: %{},
      owner_forks: %{},
      stopping: %{},
      stop_task_refs: %{},
      next_generation: 1,
      session_supervisor: Keyword.get(opts, :session_supervisor, SessionSupervisor),
      session_mod: Keyword.get(opts, :session_mod, Session),
      stop_session_fun: Keyword.get(opts, :stop_session_fun, &SessionSupervisor.stop_session/4),
      max_live_kernels: max,
      idle_timeout_ms: idle,
      reap_interval_ms: interval,
      reap_timer_token: nil,
      now_ms: now_ms
    }

    {:ok, maybe_schedule_reap(state)}
  end

  @impl true
  def handle_call({:acquire, key, owner, worker_opts}, {caller, _tag}, state) do
    case acquire_bounds(state, worker_opts) do
      {:ok, max_live_kernels, idle_timeout_ms} ->
        ekey = entry_key(state, key, owner)

        case Map.get(state.entries, ekey) do
          nil ->
            start_entry(
              state,
              ekey,
              key,
              owner,
              caller,
              worker_opts,
              max_live_kernels,
              idle_timeout_ms
            )

          entry ->
            case status(entry, state.session_mod) do
              %{phase: phase} when phase in @attachable_phases ->
                state =
                  state
                  |> attach_owner(ekey, owner)
                  |> put_idle_timeout(ekey, idle_timeout_ms)
                  |> touch(ekey)
                  |> maybe_schedule_reap()

                {state, lease} = checkout(state, ekey, owner, caller)
                entry = Map.fetch!(state.entries, ekey)
                {:reply, {:ok, allocation(entry, true, state.session_mod, lease)}, state}

              _ ->
                state = stop_entry(state, ekey)

                start_entry(
                  state,
                  ekey,
                  key,
                  owner,
                  caller,
                  worker_opts,
                  max_live_kernels,
                  idle_timeout_ms
                )
            end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    case release_lease(state, lease) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, :invalid_lease, state} -> {:reply, {:error, :invalid_lease}, state}
    end
  end

  def handle_call({:reset, key, owner}, _from, state) do
    ekey = entry_key(state, key, owner)

    case Map.get(state.entries, ekey) do
      nil ->
        {:reply, {:ok, %{reset_performed: false, forked: forked?(state, key, owner)}}, state}

      entry ->
        cond do
          not base_entry?(ekey) ->
            reset_by_stopping(state, ekey, true)

          MapSet.size(entry.owners) == 1 and MapSet.member?(entry.owners, owner) ->
            reset_by_stopping(state, ekey, false)

          true ->
            state =
              state
              |> detach_from_entry(ekey, owner)
              |> install_fork(key, owner)

            {:reply, {:ok, %{reset_performed: true, forked: true}}, state}
        end
    end
  end

  def handle_call({:detach_owner, owner}, _from, state) do
    {:reply, :ok, detach_owner_state(state, owner, true)}
  end

  def handle_call(:snapshot, _from, state) do
    phases =
      state.entries
      |> Enum.reduce(empty_phases(), fn {_ekey, entry}, acc ->
        case status(entry, state.session_mod) do
          %{phase: phase} when phase in [:starting, :idle, :running, :cancelling, :stopping] ->
            Map.update!(acc, phase, &(&1 + 1))

          _ ->
            Map.update!(acc, :unreachable, &(&1 + 1))
        end
      end)
      |> Map.update!(:unreachable, &(&1 + map_size(state.stopping)))

    {:reply,
     %{
       capacity: %{
         live: map_size(state.entries),
         max: state.max_live_kernels,
         available: max(state.max_live_kernels - map_size(state.entries), 0)
       },
       phases: phases,
       inflight_cells: map_size(state.lease_refs),
       owners: map_size(state.owner_entries),
       forked_owners: map_size(state.owner_forks),
       reap: %{idle_timeout_ms: state.idle_timeout_ms, interval_ms: state.reap_interval_ms}
     }, state}
  end

  @impl true
  def handle_info(:reap_idle, state), do: {:noreply, reap_idle(state)}

  def handle_info({:reap_idle, token}, %{reap_timer_token: token} = state) do
    state = %{state | reap_timer_token: nil}
    {:noreply, state |> reap_idle() |> maybe_schedule_reap()}
  end

  def handle_info({:reap_idle, _stale_token}, state), do: {:noreply, state}

  def handle_info({:stop_completed, worker_ref, generation, pid, task_token, result}, state) do
    {:noreply, handle_stop_completed(state, worker_ref, generation, pid, task_token, result)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.get(state.worker_refs, ref) do
      %{entry_key: ekey, generation: generation, pid: ^pid} ->
        case Map.get(state.entries, ekey) do
          %{ref: ^ref, generation: ^generation, pid: ^pid} = entry ->
            state = drop_entry(state, ekey)
            emit_session_exit(state, entry, reason)
            {:noreply, state}

          _ ->
            case Map.get(state.stopping, ref) do
              %{generation: ^generation, pid: ^pid} = entry ->
                state = drop_stopping_entry(state, ref)
                emit_session_stop(state, entry, entry.stop_reason)
                {:noreply, state}

              _ ->
                {:noreply, state}
            end
        end

      nil ->
        handle_stop_task_down_or_non_worker(state, ref)

      _stale_or_mismatched_worker ->
        {:noreply, state}
    end
  end

  defp start_entry(
         state,
         ekey,
         key,
         owner,
         caller,
         worker_opts,
         max_live_kernels,
         idle_timeout_ms
       ) do
    case admit(state, max_live_kernels) do
      {:ok, state} ->
        generation = state.next_generation
        opts = worker_options(worker_opts, key, generation)

        try do
          case SessionSupervisor.start_session(state.session_supervisor, state.session_mod, opts) do
            {:ok, pid} ->
              ref = Process.monitor(pid)

              entry = %{
                pid: pid,
                ref: ref,
                key: key,
                generation: generation,
                owners: MapSet.new(),
                leases: MapSet.new(),
                last_use_ms: now_ms(state),
                started_at_ms: now_ms(state),
                idle_timeout_ms: idle_timeout_ms,
                capacity: max_live_kernels
              }

              state = %{
                state
                | entries: Map.put(state.entries, ekey, entry),
                  worker_refs:
                    Map.put(state.worker_refs, ref, %{
                      entry_key: ekey,
                      generation: generation,
                      pid: pid
                    }),
                  next_generation: generation + 1
              }

              state = attach_owner(state, ekey, owner)
              {state, lease} = checkout(state, ekey, owner, caller)
              state = maybe_schedule_reap(state)
              entry = Map.fetch!(state.entries, ekey)
              Telemetry.session_started(map_size(state.entries), entry.capacity)
              {:reply, {:ok, allocation(entry, false, state.session_mod, lease)}, state}

            {:error, {:shutdown, {:startup_failed, detail}}} ->
              Telemetry.session_crashed(
                0,
                map_size(state.entries),
                max_live_kernels,
                :startup_failure
              )

              {:reply, {:error, {:startup_failed, detail}}, state}

            {:error, reason} ->
              Telemetry.session_crashed(
                0,
                map_size(state.entries),
                max_live_kernels,
                :startup_failure
              )

              {:reply, {:error, {:startup_failed, reason}}, state}
          end
        catch
          :exit, _ -> {:reply, {:error, :registry_unavailable}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp admit(state, max_live_kernels)
       when map_size(state.entries) < max_live_kernels,
       do: {:ok, state}

  defp admit(state, max_live_kernels) do
    state = discard_nonlive_entries(state)
    live = map_size(state.entries)

    cond do
      live < max_live_kernels ->
        {:ok, state}

      live > max_live_kernels ->
        {:error, :capacity_exhausted, state}

      ekey = lru_quiescent(state) ->
        {:ok, stop_entry(state, ekey, :capacity_eviction)}

      true ->
        {:error, :capacity_exhausted, state}
    end
  end

  defp discard_nonlive_entries(state) do
    Enum.reduce(Map.keys(state.entries), state, fn ekey, acc ->
      entry = Map.fetch!(acc.entries, ekey)

      if live?(status(entry, acc.session_mod)),
        do: acc,
        else: stop_entry(acc, ekey)
    end)
  end

  defp lru_quiescent(state) do
    state.entries
    |> Enum.filter(fn {_ekey, entry} ->
      evictable?(entry, status(entry, state.session_mod))
    end)
    |> Enum.min_by(fn {_ekey, entry} -> entry.last_use_ms end, fn -> nil end)
    |> case do
      {ekey, _entry} -> ekey
      nil -> nil
    end
  end

  defp attach_owner(state, ekey, owner) do
    entry = Map.fetch!(state.entries, ekey)

    if MapSet.member?(entry.owners, owner) do
      state
    else
      state = ensure_owner_monitor(state, owner)
      entry = %{entry | owners: MapSet.put(entry.owners, owner)}

      %{
        state
        | entries: Map.put(state.entries, ekey, entry),
          owner_entries:
            Map.update(state.owner_entries, owner, MapSet.new([ekey]), &MapSet.put(&1, ekey))
      }
    end
  end

  defp detach_owner_state(state, owner, clear_forks?) do
    state =
      state.owner_entries
      |> Map.get(owner, MapSet.new())
      |> Enum.reduce(state, fn ekey, acc -> detach_from_entry(acc, ekey, owner) end)

    state =
      if clear_forks? do
        %{state | owner_forks: Map.delete(state.owner_forks, owner)}
      else
        state
      end

    maybe_demonitor_owner(state, owner)
  end

  defp detach_from_entry(state, ekey, owner) do
    case Map.get(state.entries, ekey) do
      nil ->
        state

      entry ->
        remaining_owners = MapSet.delete(entry.owners, owner)
        current = status(entry, state.session_mod)

        if MapSet.size(remaining_owners) == 0 or owner_leased?(entry, owner) or
             not quiescent_status?(current) do
          stop_entry(state, ekey, :owner_detached)
        else
          entry = %{entry | owners: remaining_owners}

          %{state | entries: Map.put(state.entries, ekey, entry)}
          |> remove_owner_entry(owner, ekey)
        end
    end
  end

  defp stop_entry(state, ekey, reason \\ :shutdown) do
    case Map.get(state.entries, ekey) do
      nil ->
        state

      entry ->
        state
        |> quarantine_entry(ekey, entry, reason)
        |> start_stop_task(entry.ref)
        |> maybe_schedule_reap()
    end
  end

  defp quarantine_entry(state, ekey, entry, reason) do
    lease_refs =
      Enum.reduce(entry.leases, state.lease_refs, fn lease, refs ->
        caller_ref = lease_monitor(lease)
        Process.demonitor(caller_ref, [:flush])
        Map.delete(refs, caller_ref)
      end)

    state = %{
      state
      | entries: Map.delete(state.entries, ekey),
        lease_refs: lease_refs,
        stopping:
          Map.put(
            state.stopping,
            entry.ref,
            Map.merge(entry, %{
              stop_reason: reason,
              stop_status: :starting,
              stop_task_ref: nil,
              stop_task_token: nil
            })
          )
    }

    Enum.reduce(entry.owners, state, fn owner, acc ->
      acc |> remove_owner_entry(owner, ekey) |> maybe_demonitor_owner(owner)
    end)
  end

  defp start_stop_task(state, worker_ref) do
    case Map.get(state.stopping, worker_ref) do
      %{stop_task_ref: nil} = entry ->
        registry = self()
        task_token = make_ref()
        stop_session_fun = state.stop_session_fun
        session_supervisor = state.session_supervisor
        session_mod = state.session_mod

        {task_pid, task_ref} =
          spawn_monitor(fn ->
            stop_monitor = Process.monitor(entry.pid)

            result =
              try do
                stop_session_fun.(session_supervisor, session_mod, entry.pid, stop_monitor)
              catch
                :exit, reason -> {:error, reason}
              end

            send(
              registry,
              {:stop_completed, worker_ref, entry.generation, entry.pid, task_token, result}
            )
          end)

        stopping_entry =
          Map.merge(entry, %{
            stop_task_ref: task_ref,
            stop_task_token: task_token,
            stop_task_pid: task_pid,
            stop_status: :stopping
          })

        %{
          state
          | stopping: Map.put(state.stopping, worker_ref, stopping_entry),
            stop_task_refs: Map.put(state.stop_task_refs, task_ref, worker_ref)
        }

      _ ->
        state
    end
  end

  defp handle_stop_completed(state, worker_ref, generation, pid, task_token, result) do
    case Map.get(state.stopping, worker_ref) do
      %{
        generation: ^generation,
        pid: ^pid,
        stop_task_token: ^task_token,
        stop_task_ref: task_ref
      } ->
        state = clear_stop_task(state, worker_ref, task_ref)

        case result do
          :ok ->
            put_in(state.stopping[worker_ref].stop_status, :awaiting_down)

          {:error, _reason} ->
            report_stop_failure(state, worker_ref)

          _ ->
            report_stop_failure(state, worker_ref)
        end

      _ ->
        state
    end
  end

  defp handle_stop_task_down_or_non_worker(state, ref) do
    case Map.pop(state.stop_task_refs, ref) do
      {nil, _} ->
        handle_non_worker_down(state, ref)

      {worker_ref, stop_task_refs} ->
        state = %{state | stop_task_refs: stop_task_refs}

        case Map.get(state.stopping, worker_ref) do
          %{stop_task_ref: ^ref} ->
            {:noreply, report_stop_failure(state, worker_ref)}

          _ ->
            {:noreply, state}
        end
    end
  end

  defp clear_stop_task(state, worker_ref, task_ref) do
    Process.demonitor(task_ref, [:flush])

    state
    |> Map.update!(:stop_task_refs, &Map.delete(&1, task_ref))
    |> update_in([:stopping, worker_ref], fn entry -> %{entry | stop_task_ref: nil} end)
  end

  defp report_stop_failure(state, worker_ref) do
    state =
      update_in(state.stopping[worker_ref], fn entry ->
        %{entry | stop_status: :failed, stop_task_ref: nil}
      end)

    Telemetry.fallback(:stop_failed)
    maybe_schedule_reap(state)
  end

  defp drop_stopping_entry(state, worker_ref) do
    case Map.pop(state.stopping, worker_ref) do
      {nil, _} ->
        state

      {entry, stopping} ->
        if entry.stop_task_ref, do: Process.demonitor(entry.stop_task_ref, [:flush])

        %{
          state
          | stopping: stopping,
            worker_refs: Map.delete(state.worker_refs, worker_ref),
            stop_task_refs:
              if(entry.stop_task_ref,
                do: Map.delete(state.stop_task_refs, entry.stop_task_ref),
                else: state.stop_task_refs
              )
        }
    end
  end

  defp drop_entry(state, ekey) do
    case Map.pop(state.entries, ekey) do
      {nil, _} ->
        state

      {entry, entries} ->
        Process.demonitor(entry.ref, [:flush])

        lease_refs =
          Enum.reduce(entry.leases, state.lease_refs, fn lease, refs ->
            caller_ref = lease_monitor(lease)
            Process.demonitor(caller_ref, [:flush])
            Map.delete(refs, caller_ref)
          end)

        state = %{
          state
          | entries: entries,
            worker_refs: Map.delete(state.worker_refs, entry.ref),
            lease_refs: lease_refs
        }

        Enum.reduce(entry.owners, state, fn owner, acc ->
          acc |> remove_owner_entry(owner, ekey) |> maybe_demonitor_owner(owner)
        end)
    end
  end

  defp remove_owner_entry(state, owner, ekey) do
    entries = state.owner_entries |> Map.get(owner, MapSet.new()) |> MapSet.delete(ekey)

    owner_entries =
      if MapSet.size(entries) == 0,
        do: Map.delete(state.owner_entries, owner),
        else: Map.put(state.owner_entries, owner, entries)

    %{state | owner_entries: owner_entries}
  end

  defp ensure_owner_monitor(state, owner) do
    if Map.has_key?(state.owner_refs, owner),
      do: state,
      else: %{state | owner_refs: Map.put(state.owner_refs, owner, Process.monitor(owner))}
  end

  defp maybe_demonitor_owner(state, owner) do
    if Map.has_key?(state.owner_entries, owner) or Map.has_key?(state.owner_forks, owner) do
      state
    else
      case Map.pop(state.owner_refs, owner) do
        {nil, _} ->
          state

        {ref, refs} ->
          Process.demonitor(ref, [:flush])
          %{state | owner_refs: refs}
      end
    end
  end

  defp status(entry, session_mod) do
    try do
      with %{
             phase: phase,
             generation: generation,
             key: key,
             queue_depth: queue_depth,
             active_request_id: active_request_id,
             cells_completed: cells_completed,
             process_alive: true
           } = value <- session_mod.status(entry.pid),
           true <- phase in @known_phases,
           true <- generation == entry.generation,
           true <- key == entry.key,
           true <- is_integer(queue_depth) and queue_depth >= 0,
           true <- is_integer(cells_completed) and cells_completed >= 0,
           true <- valid_phase_status?(phase, queue_depth, active_request_id) do
        value
      else
        _ -> :unreachable
      end
    catch
      :exit, _ -> :unreachable
    end
  end

  defp valid_phase_status?(:starting, _queue_depth, nil), do: true
  defp valid_phase_status?(:idle, 0, nil), do: true

  defp valid_phase_status?(phase, _queue_depth, active_request_id)
       when phase in [:running, :cancelling, :stopping] and is_binary(active_request_id),
       do: active_request_id != ""

  defp valid_phase_status?(_phase, _queue_depth, _active_request_id), do: false

  defp reset_by_stopping(state, ekey, forked?) do
    state = stop_entry(state, ekey, :reset)
    {:reply, {:ok, %{reset_performed: true, forked: forked?}}, state}
  end

  defp handle_non_worker_down(state, ref) do
    case Enum.find(state.owner_refs, fn {_owner, owner_ref} -> owner_ref == ref end) do
      {owner, _ref} ->
        {:noreply, detach_owner_state(state, owner, true)}

      nil ->
        case Map.get(state.lease_refs, ref) do
          nil ->
            {:noreply, state}

          lease ->
            {:ok, state} = release_lease(state, lease)
            {:noreply, state}
        end
    end
  end

  defp checkout(state, ekey, owner, caller) do
    entry = Map.fetch!(state.entries, ekey)
    caller_ref = Process.monitor(caller)
    lease = {__MODULE__, ekey, entry.ref, entry.generation, owner, caller_ref}
    entry = %{entry | leases: MapSet.put(entry.leases, lease), last_use_ms: now_ms(state)}

    state = %{
      state
      | entries: Map.put(state.entries, ekey, entry),
        lease_refs: Map.put(state.lease_refs, caller_ref, lease)
    }

    {state, lease}
  end

  defp release_lease(
         state,
         {__MODULE__, ekey, worker_ref, generation, owner, caller_ref} = lease
       )
       when is_reference(worker_ref) and is_integer(generation) and generation > 0 and
              is_pid(owner) and is_reference(caller_ref) do
    case Map.get(state.lease_refs, caller_ref) do
      ^lease ->
        Process.demonitor(caller_ref, [:flush])
        state = %{state | lease_refs: Map.delete(state.lease_refs, caller_ref)}

        state =
          case Map.get(state.entries, ekey) do
            %{ref: ^worker_ref, generation: ^generation} = entry ->
              if MapSet.member?(entry.leases, lease) do
                entry = %{
                  entry
                  | leases: MapSet.delete(entry.leases, lease),
                    last_use_ms: now_ms(state)
                }

                %{state | entries: Map.put(state.entries, ekey, entry)}
              else
                state
              end

            _ ->
              state
          end

        {:ok, state}

      nil ->
        {:ok, state}

      _other ->
        {:error, :invalid_lease, state}
    end
  end

  defp release_lease(state, _lease), do: {:error, :invalid_lease, state}

  defp lease_monitor({__MODULE__, _ekey, _worker_ref, _generation, _owner, caller_ref}),
    do: caller_ref

  defp owner_leased?(entry, owner) do
    Enum.any?(entry.leases, fn
      {__MODULE__, _ekey, _worker_ref, _generation, ^owner, _caller_ref} -> true
      _ -> false
    end)
  end

  defp acquire_bounds(state, worker_opts) do
    max_live_kernels = Keyword.get(worker_opts, :max_live_kernels, state.max_live_kernels)
    idle_timeout_ms = Keyword.get(worker_opts, :idle_timeout_ms, state.idle_timeout_ms)

    cond do
      not (is_integer(max_live_kernels) and max_live_kernels > 0) ->
        {:error, :invalid_request}

      idle_timeout_ms != :infinity and
          not (is_integer(idle_timeout_ms) and idle_timeout_ms > 0) ->
        {:error, :invalid_request}

      true ->
        {:ok, max_live_kernels, idle_timeout_ms}
    end
  end

  defp worker_options(worker_opts, key, generation) do
    extras =
      worker_opts
      |> List.wrap()
      |> Keyword.take([:max_output_bytes, :max_queued_cells, :runner_path, :helper_source])

    [key: key, cwd: key.cwd, interpreter: key.interpreter, generation: generation] ++
      extras
  end

  defp allocation(entry, reused?, session_mod, lease),
    do: %{
      pid: entry.pid,
      generation: entry.generation,
      reused?: reused?,
      session_mod: session_mod,
      lease: lease
    }

  defp entry_key(state, key, owner),
    do: if(forked?(state, key, owner), do: {:fork, key, owner}, else: key)

  defp base_entry?(%Key{}), do: true
  defp base_entry?(_), do: false

  defp forked?(state, key, owner),
    do:
      state.owner_forks
      |> Map.get(owner, MapSet.new())
      |> MapSet.member?(key)

  defp install_fork(state, key, owner) do
    state
    |> ensure_owner_monitor(owner)
    |> Map.update!(:owner_forks, fn forks ->
      Map.update(forks, owner, MapSet.new([key]), fn keys -> MapSet.put(keys, key) end)
    end)
  end

  defp touch(state, ekey),
    do: update_in(state.entries[ekey].last_use_ms, fn _ -> now_ms(state) end)

  defp put_idle_timeout(state, ekey, idle_timeout_ms),
    do: put_in(state.entries[ekey].idle_timeout_ms, idle_timeout_ms)

  defp live?(%{phase: phase}) when phase in @attachable_phases, do: true
  defp live?(_), do: false

  defp quiescent_status?(%{phase: :idle, queue_depth: 0, active_request_id: nil}),
    do: true

  defp quiescent_status?(_), do: false

  defp evictable?(entry, current),
    do: MapSet.size(entry.leases) == 0 and quiescent_status?(current)

  defp expired?(entry, _state, now),
    do:
      entry.idle_timeout_ms != :infinity and
        now - entry.last_use_ms >= entry.idle_timeout_ms

  defp reap_idle(state) do
    now = now_ms(state)

    state =
      Enum.reduce(Map.keys(state.entries), state, fn ekey, acc ->
        case Map.get(acc.entries, ekey) do
          nil ->
            acc

          entry ->
            current = status(entry, acc.session_mod)

            cond do
              current == :unreachable ->
                reap_entry(acc, ekey, entry, now, :unreachable)

              expired?(entry, acc, now) and evictable?(entry, current) ->
                reap_entry(acc, ekey, entry, now, :idle)

              true ->
                acc
            end
        end
      end)

    Enum.reduce(state.stopping, state, fn
      {worker_ref, %{stop_status: :failed}}, acc -> start_stop_task(acc, worker_ref)
      {_worker_ref, _entry}, acc -> acc
    end)
  end

  defp reap_entry(state, ekey, entry, now, reason) do
    state = stop_entry(state, ekey)

    Telemetry.session_reaped(
      now - entry.last_use_ms,
      map_size(state.entries),
      entry.capacity,
      reason
    )

    state
  end

  defp maybe_schedule_reap(%{reap_timer_token: nil} = state) do
    if map_size(state.stopping) > 0 or state.idle_timeout_ms != :infinity or
         Enum.any?(state.entries, fn {_ekey, entry} ->
           entry.idle_timeout_ms != :infinity
         end) do
      token = make_ref()
      Process.send_after(self(), {:reap_idle, token}, state.reap_interval_ms)
      %{state | reap_timer_token: token}
    else
      state
    end
  end

  defp maybe_schedule_reap(state), do: state

  defp empty_phases,
    do: %{starting: 0, idle: 0, running: 0, cancelling: 0, stopping: 0, unreachable: 0}

  defp now_ms(state), do: state.now_ms.()

  defp emit_session_stop(state, entry, reason) do
    Telemetry.session_stopped(
      now_ms(state) - entry.started_at_ms,
      map_size(state.entries),
      entry.capacity,
      session_stop_reason(reason)
    )
  end

  defp emit_session_crash(state, entry, reason) do
    Telemetry.session_crashed(
      now_ms(state) - entry.started_at_ms,
      max(map_size(state.entries) - 1, 0),
      entry.capacity,
      session_crash_reason(reason)
    )
  end

  defp emit_session_exit(state, entry, reason) do
    case session_exit_kind(reason) do
      {:stop, stop_reason} -> emit_session_stop(state, entry, stop_reason)
      {:crash, crash_reason} -> emit_session_crash(state, entry, crash_reason)
    end
  end

  defp session_exit_kind({:shutdown, :bye}), do: {:stop, :shutdown}
  defp session_exit_kind(:normal), do: {:stop, :shutdown}
  defp session_exit_kind(:shutdown), do: {:stop, :shutdown}
  defp session_exit_kind(reason), do: {:crash, reason}

  defp session_stop_reason(:reset), do: :reset
  defp session_stop_reason(:owner_detached), do: :owner_detached
  defp session_stop_reason(:capacity_eviction), do: :capacity_eviction
  defp session_stop_reason(_reason), do: :shutdown

  defp session_crash_reason({:shutdown, {:port_exit, _status}}), do: :port_exit
  defp session_crash_reason({:shutdown, {:protocol_fault, _detail}}), do: :protocol_fault
  defp session_crash_reason({:shutdown, :startup_timeout}), do: :startup_failure

  defp session_crash_reason({:shutdown, reason})
       when reason in [:interrupt_grace_expired, :no_soft_interrupt],
       do: :cancellation_escalation

  defp session_crash_reason(_reason), do: :unknown
end
