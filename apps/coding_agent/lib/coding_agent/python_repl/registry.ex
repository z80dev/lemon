defmodule CodingAgent.PythonRepl.Registry do
  @moduledoc """
  The serialized ownership and lifetime authority for persistent Python kernels.

  Workers are never registered by key. This GenServer owns the key-to-worker
  mapping and monitors both workers and owners, which makes invalidation,
  capacity admission, and delayed `:DOWN` messages race-safe.
  """

  use GenServer

  alias CodingAgent.PythonRepl.{Key, Session, SessionSupervisor}

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
          {:ok, %{reset_performed: boolean(), forked: boolean()}} | {:error, :stop_failed}
  def reset(server, %Key{} = key, owner_pid) when is_pid(owner_pid) do
    GenServer.call(server, {:reset, key, owner_pid}, :infinity)
  end

  @spec detach_owner(GenServer.server(), pid()) :: :ok | {:error, :stop_failed}
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
      next_generation: 1,
      session_supervisor: Keyword.get(opts, :session_supervisor, SessionSupervisor),
      session_mod: Keyword.get(opts, :session_mod, Session),
      max_live_kernels: max,
      idle_timeout_ms: idle,
      reap_interval_ms: interval,
      now_ms: now_ms
    }

    if idle != :infinity, do: Process.send_after(self(), :reap_idle, interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, key, owner, worker_opts}, {caller, _tag}, state) do
    ekey = entry_key(state, key, owner)

    case Map.get(state.entries, ekey) do
      nil ->
        start_entry(state, ekey, key, owner, caller, worker_opts)

      entry ->
        case status(entry, state.session_mod) do
          %{phase: phase} when phase in @attachable_phases ->
            state = state |> attach_owner(ekey, owner) |> touch(ekey)
            {state, lease} = checkout(state, ekey, owner, caller)
            entry = Map.fetch!(state.entries, ekey)
            {:reply, {:ok, allocation(entry, true, state.session_mod, lease)}, state}

          _ ->
            case stop_entry(state, ekey) do
              {:ok, state} -> start_entry(state, ekey, key, owner, caller, worker_opts)
              {:error, reason, state} -> {:reply, {:error, reason}, state}
            end
        end
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
            case detach_from_entry(state, ekey, owner) do
              {:ok, state} ->
                state = install_fork(state, key, owner)
                {:reply, {:ok, %{reset_performed: true, forked: true}}, state}

              {:error, state} ->
                {:reply, {:error, :stop_failed}, state}
            end
        end
    end
  end

  def handle_call({:detach_owner, owner}, _from, state) do
    case detach_owner_state(state, owner, true) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:reply, {:error, :stop_failed}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    phases =
      Enum.reduce(state.entries, empty_phases(), fn {_ekey, entry}, acc ->
        case status(entry, state.session_mod) do
          %{phase: phase} when phase in [:starting, :idle, :running, :cancelling, :stopping] ->
            Map.update!(acc, phase, &(&1 + 1))

          _ ->
            Map.update!(acc, :unreachable, &(&1 + 1))
        end
      end)

    {:reply,
     %{
       capacity: %{
         live: map_size(state.entries),
         max: state.max_live_kernels,
         available: max(state.max_live_kernels - map_size(state.entries), 0)
       },
       phases: phases,
       owners: map_size(state.owner_entries),
       forked_owners: map_size(state.owner_forks),
       reap: %{idle_timeout_ms: state.idle_timeout_ms, interval_ms: state.reap_interval_ms}
     }, state}
  end

  @impl true
  def handle_info(:reap_idle, state) do
    now = now_ms(state)

    state =
      Enum.reduce(Map.keys(state.entries), state, fn ekey, acc ->
        case Map.get(acc.entries, ekey) do
          nil ->
            acc

          entry ->
            current = status(entry, acc.session_mod)

            if current == :unreachable or
                 (expired?(entry, acc, now) and evictable?(entry, current)) do
              stop_entry_or_keep(acc, ekey)
            else
              acc
            end
        end
      end)

    if state.idle_timeout_ms != :infinity,
      do: Process.send_after(self(), :reap_idle, state.reap_interval_ms)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.worker_refs, ref) do
      %{entry_key: ekey, generation: generation, pid: ^pid} ->
        case Map.get(state.entries, ekey) do
          %{ref: ^ref, generation: ^generation, pid: ^pid} ->
            {:noreply, drop_entry(state, ekey)}

          _ ->
            {:noreply, state}
        end

      nil ->
        handle_non_worker_down(state, ref)

      _stale_or_mismatched_worker ->
        {:noreply, state}
    end
  end

  defp start_entry(state, ekey, key, owner, caller, worker_opts) do
    with {:ok, state} <- admit(state) do
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
              last_use_ms: now_ms(state)
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
            entry = Map.fetch!(state.entries, ekey)
            {:reply, {:ok, allocation(entry, false, state.session_mod, lease)}, state}

          {:error, {:shutdown, {:startup_failed, detail}}} ->
            {:reply, {:error, {:startup_failed, detail}}, state}

          {:error, reason} ->
            {:reply, {:error, {:startup_failed, reason}}, state}
        end
      catch
        :exit, _ -> {:reply, {:error, :registry_unavailable}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp admit(state) when map_size(state.entries) < state.max_live_kernels,
    do: {:ok, state}

  defp admit(state) do
    with {:ok, state} <- discard_nonlive_entries(state) do
      cond do
        map_size(state.entries) < state.max_live_kernels ->
          {:ok, state}

        ekey = lru_quiescent(state) ->
          stop_entry(state, ekey)

        true ->
          {:error, :capacity_exhausted, state}
      end
    end
  end

  defp discard_nonlive_entries(state) do
    Enum.reduce_while(Map.keys(state.entries), {:ok, state}, fn ekey, {:ok, acc} ->
      entry = Map.fetch!(acc.entries, ekey)

      if live?(status(entry, acc.session_mod)) do
        {:cont, {:ok, acc}}
      else
        case stop_entry(acc, ekey) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, reason, acc} -> {:halt, {:error, reason, acc}}
        end
      end
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
    result =
      state.owner_entries
      |> Map.get(owner, MapSet.new())
      |> Enum.reduce_while({:ok, state}, fn ekey, {:ok, acc} ->
        case detach_from_entry(acc, ekey, owner) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, acc} -> {:halt, {:error, acc}}
        end
      end)

    case result do
      {:ok, state} ->
        state =
          if clear_forks? do
            %{state | owner_forks: Map.delete(state.owner_forks, owner)}
          else
            state
          end

        {:ok, maybe_demonitor_owner(state, owner)}

      {:error, state} ->
        {:error, state}
    end
  end

  defp detach_from_entry(state, ekey, owner) do
    case Map.get(state.entries, ekey) do
      nil ->
        {:ok, state}

      entry ->
        remaining_owners = MapSet.delete(entry.owners, owner)
        current = status(entry, state.session_mod)

        if MapSet.size(remaining_owners) == 0 or owner_leased?(entry, owner) or
             not quiescent_status?(current) do
          case stop_entry(state, ekey) do
            {:ok, state} -> {:ok, state}
            {:error, _reason, state} -> {:error, state}
          end
        else
          entry = %{entry | owners: remaining_owners}

          state =
            %{state | entries: Map.put(state.entries, ekey, entry)}
            |> remove_owner_entry(owner, ekey)

          {:ok, state}
        end
    end
  end

  defp stop_entry(state, ekey) do
    case Map.get(state.entries, ekey) do
      nil ->
        {:ok, state}

      entry ->
        case SessionSupervisor.stop_session(
               state.session_supervisor,
               state.session_mod,
               entry.pid,
               entry.ref
             ) do
          :ok -> {:ok, drop_entry(state, ekey)}
          {:error, _reason} -> {:error, :stop_failed, state}
        end
    end
  end

  defp stop_entry_or_keep(state, ekey) do
    case stop_entry(state, ekey) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
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
    case stop_entry(state, ekey) do
      {:ok, state} ->
        {:reply, {:ok, %{reset_performed: true, forked: forked?}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_non_worker_down(state, ref) do
    case Enum.find(state.owner_refs, fn {_owner, owner_ref} -> owner_ref == ref end) do
      {owner, _ref} ->
        case detach_owner_state(state, owner, true) do
          {:ok, state} -> {:noreply, state}
          {:error, state} -> {:stop, :stop_failed, state}
        end

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

  defp live?(%{phase: phase}) when phase in @attachable_phases, do: true
  defp live?(_), do: false

  defp quiescent_status?(%{phase: :idle, queue_depth: 0, active_request_id: nil}),
    do: true

  defp quiescent_status?(_), do: false

  defp evictable?(entry, current),
    do: MapSet.size(entry.leases) == 0 and quiescent_status?(current)

  defp expired?(entry, state, now),
    do: state.idle_timeout_ms != :infinity and now - entry.last_use_ms >= state.idle_timeout_ms

  defp empty_phases,
    do: %{starting: 0, idle: 0, running: 0, cancelling: 0, stopping: 0, unreachable: 0}

  defp now_ms(state), do: state.now_ms.()
end
