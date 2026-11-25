defmodule CodingAgent.DurableTable do
  @moduledoc """
  Shared storage lifecycle for serialized domain owners.

  `use DurableTable` makes the domain server the ETS/DETS owner; there is no
  second process or write mailbox. `open/3` loads the original DETS tuples
  synchronously, applying the domain's restart callback before readiness.
  A nil DETS table deliberately keeps a store transient: it gets no heir and
  starts empty after every owner restart.

  ## Restart semantics

  `CodingAgent.RuntimeTables` is the mirror's ETS heir. When an owner crashes
  (an exception, an exit or `:kill`), the heir keeps the live table and the
  restarted owner reclaims it: the mirror stays authoritative, its expiry index
  is rebuilt, DETS rows are loaded only for keys the mirror lacks, and the
  domain's boot normalization is not applied. A domain may pass a `reclaim`
  row callback for owner-local state that did not survive (for example join
  reservations, or live-owner checks). In-flight work keeps its state, so a
  live worker's later transition is still accepted. A row whose ETS write
  landed just before the crash may be newer than its DETS copy until its next
  write.

  A clean stop (`:normal`, `:shutdown`, an application stop or VM boot) drops
  the heir, so the next owner starts from DETS and applies restart
  normalization to rows whose owners are gone.

  Every mutation must run in the owner and use `put/3`, `delete/2` or `clear/1`.
  The mirror has `read_concurrency`; two private ETS indexes hold only eligible
  expiration timestamps and keys. Sweeps walk the expired prefix, never fold
  retained rows or copy their logs/events. Deletion uses `:ets.select_delete/2`.
  Index maintenance is O(log n), sweep work O(expired * log n), with no work
  proportional to unexpired rows (and no sweep worker tasks).

  Callbacks return unchanged-format tuples and either an expiration base time
  in milliseconds or nil. Cleanup TTLs remain caller-selected seconds. A domain
  deletion callback may refuse deletion (for example, an open output artifact);
  the entry then remains indexed for a later sweep. Status retains the stores'
  existing `info` and `state` projection.
  """

  require Logger

  defmacro __using__(_opts) do
    quote do
      use GenServer
      alias CodingAgent.DurableTable

      @impl true
      def format_status(status) do
        Map.new(status, fn
          {:state, _} -> {:state, :redacted}
          {:message, _} -> {:message, :redacted}
          {:reason, _} -> {:reason, :redacted}
          {:log, _} -> {:log, []}
          pair -> pair
        end)
      end

      @impl true
      def terminate(reason, state), do: DurableTable.close(state, reason)
    end
  end

  def open(state, opts, config) do
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :table, Keyword.fetch!(config, :table))
    dets_table = Keyword.get(opts, :dets_table, Keyword.get(config, :dets_table))
    path = Keyword.get(opts, :dets_path) || Keyword.get(config, :path)
    reclaimed? = not is_nil(dets_table) and reclaim_from_heir(table)

    if not reclaimed? and :ets.whereis(table) == :undefined do
      :ets.new(table, [
        :named_table,
        Keyword.get(config, :access, :public),
        :set,
        read_concurrency: true
      ])
    end

    storage = %{
      expiry: :ets.new(__MODULE__, [:ordered_set, :private]),
      by_id: :ets.new(__MODULE__, [:set, :private]),
      timestamp: Keyword.fetch!(config, :timestamp),
      normalize: Keyword.get(config, :normalize, fn row, _state -> row end),
      after_load: Keyword.get(config, :after_load, fn state -> state end),
      before_load: Keyword.get(opts, :before_dets_load),
      row_arity: Keyword.get(config, :row_arity, 3),
      ttl_key: Keyword.fetch!(config, :ttl_key),
      interval_key: Keyword.fetch!(config, :interval_key),
      reload_empty: Keyword.get(config, :reload_empty, false),
      reclaim: Keyword.get(config, :reclaim, fn row, _state -> row end),
      dets_table: dets_table
    }

    Process.put({__MODULE__, table}, storage)

    state =
      Map.merge(state, %{
        table: table,
        dets_table: dets_table,
        dets_path: path,
        ets_initialized: true,
        dets_initialized: false,
        loaded_from_dets: is_nil(dets_table),
        reclaimed: reclaimed?
      })

    if reclaimed?, do: restore_reclaimed(state, storage)

    state = ensure(state)
    schedule_cleanup(state)
    state
  end

  # The heir holds a crashed owner's live mirror; take it back before creating
  # a fresh table. The transfer message is consumed here so domain owners need
  # no handler for it.
  defp reclaim_from_heir(table) do
    case CodingAgent.RuntimeTables.reclaim(table) do
      :ok ->
        receive do
          {:"ETS-TRANSFER", _tid, _from, _data} -> true
        after
          0 -> true
        end

      :none ->
        false
    end
  end

  # Reclaimed rows are already in the mirror; the private indexes are not.
  defp restore_reclaimed(state, storage) do
    :ets.foldl(
      fn row, :ok ->
        case storage.reclaim.(row, state) do
          ^row -> index(state.table, row)
          updated -> put(state.table, updated, :mirror)
        end

        :ok
      end,
      :ok,
      state.table
    )
  end

  @doc """
  Prepare the table for an owner call: keep the heir current, open DETS late
  when it was unavailable, and load rows the mirror does not hold yet.
  """
  def ensure(state) do
    storage = storage(state.table)
    if state.dets_table, do: keep_heir(state.table)
    state = open_dets(state)

    reload? =
      storage.reload_empty and state.loaded_from_dets and state.dets_initialized and
        :ets.info(state.table, :size) == 0 and :dets.info(state.dets_table, :size) > 0

    state = if reload?, do: %{state | loaded_from_dets: false}, else: state

    if state.dets_initialized and not state.loaded_from_dets do
      if is_function(storage.before_load, 0), do: storage.before_load.()

      :ok =
        :dets.foldl(
          fn row, :ok ->
            # A reclaimed mirror is newer than DETS; only absent keys load.
            if state.reclaimed and :ets.member(state.table, elem(row, 0)),
              do: :ok,
              else: put(state.table, storage.normalize.(row, state), :mirror)
          end,
          :ok,
          state.dets_table
        )

      storage.after_load.(%{state | loaded_from_dets: true})
    else
      state
    end
  end

  defp keep_heir(table) do
    with pid when is_pid(pid) <- Process.whereis(CodingAgent.RuntimeTables),
         true <- :ets.info(table, :owner) == self(),
         false <- :ets.info(table, :heir) == pid do
      :ets.setopts(table, {:heir, pid, :durable_table})
    end

    :ok
  end

  defp open_dets(%{dets_table: nil} = state), do: state

  defp open_dets(state) do
    if open?(state.dets_table) do
      %{state | dets_initialized: true}
    else
      File.mkdir_p!(Path.dirname(state.dets_path))

      case CodingAgent.StatePaths.open_dets(state.dets_table, state.dets_path) do
        {:ok, _} ->
          %{state | dets_initialized: true, loaded_from_dets: false}

        {:error, {:already_open, _pid}} ->
          %{state | dets_initialized: true, loaded_from_dets: false}

        {:error, {:state_dir_locked, pid}} ->
          CodingAgent.StatePaths.warn_locked(pid)
          %{state | dets_initialized: false, loaded_from_dets: false}

        {:error, _reason} ->
          Logger.warning("Durable table storage unavailable")
          %{state | dets_initialized: false, loaded_from_dets: false}
      end
    end
  end

  def sync(table) do
    dets_table = storage(table).dets_table
    if open?(dets_table), do: :dets.sync(dets_table), else: :ok
  end

  def persist(table, row, sync? \\ false) do
    dets_table = storage(table).dets_table
    true = open?(dets_table)

    with :ok <- :dets.insert(dets_table, row) do
      if sync?, do: :dets.sync(dets_table), else: :ok
    end
  end

  def put(table, row, mode \\ :write) do
    storage = storage(table)

    if mode == :sync do
      :ok = persist(table, row, true)
    end

    :ets.insert(table, row)
    index(table, row)

    if mode == :write and open?(storage.dets_table),
      do: :ok = :dets.insert(storage.dets_table, row)

    :ok
  end

  defp index(table, row) do
    storage = storage(table)
    id = elem(row, 0)
    unindex(storage, id)

    case storage.timestamp.(row) do
      timestamp when is_integer(timestamp) ->
        :ets.insert(storage.expiry, {{timestamp, id}})
        :ets.insert(storage.by_id, {id, timestamp})

      nil ->
        :ok
    end
  end

  defp unindex(storage, id) do
    case :ets.take(storage.by_id, id) do
      [{^id, timestamp}] -> :ets.delete(storage.expiry, {timestamp, id})
      [] -> :ok
    end
  end

  def delete(table, id) do
    storage = storage(table)
    head = put_elem(Tuple.duplicate(:_, storage.row_arity), 0, id)
    :ets.select_delete(table, [{head, [], [true]}])
    unindex(storage, id)
    if open?(storage.dets_table), do: :ok = :dets.delete(storage.dets_table, id)
    :ok
  end

  def clear(state) do
    storage = storage(state.table)
    :ets.delete_all_objects(state.table)
    :ets.delete_all_objects(storage.expiry)
    :ets.delete_all_objects(storage.by_id)

    if open?(state.dets_table) do
      :ok = :dets.delete_all_objects(state.dets_table)
      :ok = :dets.sync(state.dets_table)
    end

    :ok
  end

  def cleanup(state, ttl_seconds, delete_fn \\ nil) do
    storage = storage(state.table)
    cutoff = System.system_time(:millisecond) - ttl_seconds * 1_000
    ids = expired(storage.expiry, :ets.first(storage.expiry), cutoff, [])
    delete_fn = delete_fn || fn id -> delete(state.table, id) end
    count = Enum.count(ids, fn id -> delete_fn.(id) == :ok end)
    if ids != [] and open?(state.dets_table), do: :ok = :dets.sync(state.dets_table)
    count
  end

  defp expired(_table, :"$end_of_table", _cutoff, ids), do: ids

  defp expired(table, {timestamp, id} = key, cutoff, ids) when timestamp <= cutoff,
    do: expired(table, :ets.next(table, key), cutoff, [id | ids])

  defp expired(_table, _key, _cutoff, ids), do: ids

  def periodic_cleanup(state, delete_fn \\ nil) do
    ttl = Application.get_env(:coding_agent, storage(state.table).ttl_key, 86_400)
    cleanup(state, ttl, delete_fn)
    schedule_cleanup(state)
    :ok
  end

  defp schedule_cleanup(state) do
    interval = Application.get_env(:coding_agent, storage(state.table).interval_key, 300)
    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  def status(state) do
    info =
      if open?(state.dets_table),
        do: Map.new(:dets.info(state.dets_table)),
        else: %{status: :not_initialized}

    %{info: info, state: Map.drop(state, [:table, :dets_table])}
  end

  def open?(nil), do: false
  def open?(table), do: :dets.info(table) != :undefined

  @doc """
  Close DETS on owner termination. A clean stop also drops the heir so the
  next owner boots from DETS; a crash leaves the mirror with the heir.
  """
  def close(state, reason) do
    if clean_stop?(reason) and :ets.info(state.table, :owner) == self(),
      do: :ets.setopts(state.table, {:heir, :none})

    if open?(state.dets_table), do: :dets.close(state.dets_table)
    :ok
  end

  defp clean_stop?(reason),
    do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  def terminal_timestamp(record) do
    case record[:completed_at] || record[:updated_at] || record[:inserted_at] do
      timestamp when is_integer(timestamp) -> timestamp * 1_000
      _ -> nil
    end
  end

  defp storage(table),
    do: Process.get({__MODULE__, table}) || raise("table mutation outside owner")
end
