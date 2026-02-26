defmodule LemonGateway.EngineLock do
  @moduledoc """
  Mutex lock preventing concurrent engine runs on the same session.

  Provides fair FIFO queueing with configurable timeouts. Monitors lock
  holders and automatically releases locks when processes die. Periodically
  sweeps stale locks that exceed `max_lock_age_ms`.
  """
  use GenServer
  require Logger

  @type thread_key :: term()
  @default_max_lock_age_ms 300_000
  @default_reap_interval_ms 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires the engine lock for the given thread key.

  Returns `{:ok, release_fn}` where `release_fn` is a zero-arity function
  that must be called to release the lock. Returns `{:error, :timeout}`
  if the lock cannot be acquired within `timeout_ms`.
  """
  @spec acquire(thread_key(), non_neg_integer()) ::
          {:ok, (-> :ok)} | {:error, :timeout}
  def acquire(thread_key, timeout_ms \\ 60_000) do
    GenServer.call(__MODULE__, {:acquire, thread_key, timeout_ms}, timeout_ms + 1_000)
  end

  @impl true
  def init(opts) do
    opts = normalize_opts(opts)
    max_lock_age_ms = max_lock_age_ms(opts)
    reap_interval_ms = reap_interval_ms(opts, max_lock_age_ms)
    sweep_ref = maybe_schedule_sweep(reap_interval_ms)

    {:ok,
     %{
       locks: %{},
       waiters: %{},
       max_lock_age_ms: max_lock_age_ms,
       reap_interval_ms: reap_interval_ms,
       sweep_ref: sweep_ref
     }}
  end

  @impl true
  def handle_call({:acquire, thread_key, timeout_ms}, {pid, _ref} = from, state) do
    case Map.get(state.locks, thread_key) do
      nil ->
        {state, release_fun} = grant_lock(state, thread_key, pid)

        Logger.debug(
          "EngineLock granted immediately key=#{inspect(thread_key)} owner=#{inspect(pid)}"
        )

        {:reply, {:ok, release_fun}, state}

      _locked ->
        timer_ref = Process.send_after(self(), {:lock_timeout, thread_key, from}, timeout_ms)
        waiter = %{from: from, pid: pid, timer_ref: timer_ref}

        waiters =
          Map.update(
            state.waiters,
            thread_key,
            :queue.from_list([waiter]),
            &:queue.in(waiter, &1)
          )

        Logger.debug(
          "EngineLock queued waiter key=#{inspect(thread_key)} owner=#{inspect(pid)} timeout_ms=#{timeout_ms}"
        )

        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_cast({:release, thread_key, pid}, state) do
    case Map.get(state.locks, thread_key) do
      %{owner: ^pid, mon_ref: mon_ref} ->
        Process.demonitor(mon_ref, [:flush])
        Logger.debug("EngineLock released key=#{inspect(thread_key)} owner=#{inspect(pid)}")
        {:noreply, release_and_next(state, thread_key)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:lock_timeout, thread_key, from}, state) do
    case Map.get(state.waiters, thread_key) do
      nil ->
        {:noreply, state}

      queue ->
        {queue, found} = drop_waiter(queue, from)

        if found do
          Logger.warning(
            "EngineLock waiter timeout key=#{inspect(thread_key)} from=#{inspect(from)}"
          )

          GenServer.reply(from, {:error, :timeout})
        end

        waiters =
          if :queue.is_empty(queue),
            do: Map.delete(state.waiters, thread_key),
            else: Map.put(state.waiters, thread_key, queue)

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {thread_key, _} =
      Enum.find(state.locks, fn {_key, lock} ->
        lock.owner == pid
      end) || {nil, nil}

    if thread_key do
      {:noreply, release_and_next(state, thread_key)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:sweep_locks, state) do
    state = reap_stale_locks(state)
    sweep_ref = maybe_schedule_sweep(state.reap_interval_ms)
    {:noreply, %{state | sweep_ref: sweep_ref}}
  end

  defp grant_lock(state, thread_key, pid) do
    mon_ref = Process.monitor(pid)

    locks =
      Map.put(state.locks, thread_key, %{
        owner: pid,
        mon_ref: mon_ref,
        acquired_at_ms: System.monotonic_time(:millisecond)
      })

    release_fun = fn -> GenServer.cast(__MODULE__, {:release, thread_key, pid}) end
    {%{state | locks: locks}, release_fun}
  end

  defp release_and_next(state, thread_key) do
    locks = Map.delete(state.locks, thread_key)

    case Map.get(state.waiters, thread_key) do
      nil ->
        %{state | locks: locks}

      queue ->
        {{:value, waiter}, queue} = :queue.out(queue)
        Process.cancel_timer(waiter.timer_ref)
        {state, release_fun} = grant_lock(%{state | locks: locks}, thread_key, waiter.pid)
        GenServer.reply(waiter.from, {:ok, release_fun})

        waiters =
          if :queue.is_empty(queue),
            do: Map.delete(state.waiters, thread_key),
            else: Map.put(state.waiters, thread_key, queue)

        %{state | waiters: waiters}
    end
  end

  defp drop_waiter(queue, from) do
    list = :queue.to_list(queue)

    {kept, removed} = Enum.split_with(list, fn waiter -> waiter.from != from end)

    case removed do
      [waiter] ->
        Process.cancel_timer(waiter.timer_ref)
        {:queue.from_list(kept), true}

      _ ->
        {:queue.from_list(list), false}
    end
  end

  defp max_lock_age_ms(opts) do
    configured =
      Application.get_env(:lemon_gateway, :engine_lock_max_hold_ms, @default_max_lock_age_ms)

    case Map.get(opts, :max_lock_age_ms, configured) do
      :infinity -> :infinity
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_lock_age_ms
    end
  end

  defp reap_interval_ms(_opts, :infinity), do: nil

  defp reap_interval_ms(opts, max_lock_age_ms) when is_integer(max_lock_age_ms) do
    configured =
      Application.get_env(
        :lemon_gateway,
        :engine_lock_reap_interval_ms,
        min(max_lock_age_ms, @default_reap_interval_ms)
      )

    case Map.get(opts, :reap_interval_ms, configured) do
      value when is_integer(value) and value > 0 -> value
      _ -> min(max_lock_age_ms, @default_reap_interval_ms)
    end
  end

  defp maybe_schedule_sweep(nil), do: nil

  defp maybe_schedule_sweep(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :sweep_locks, interval_ms)
  end

  defp reap_stale_locks(state) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.reduce(Map.keys(state.locks), state, fn thread_key, acc ->
      case Map.get(acc.locks, thread_key) do
        nil ->
          acc

        lock ->
          if stale_lock?(lock, now_ms, acc.max_lock_age_ms) do
            age_ms = lock_age_ms(lock, now_ms)

            Logger.warning(
              "Reclaiming stale engine lock #{inspect(thread_key)} after #{age_ms}ms"
            )

            Process.demonitor(lock.mon_ref, [:flush])
            release_and_next(acc, thread_key)
          else
            acc
          end
      end
    end)
  end

  defp stale_lock?(lock, now_ms, max_lock_age_ms) do
    owner_dead? = not Process.alive?(lock.owner)

    expired? =
      case {Map.get(lock, :acquired_at_ms), max_lock_age_ms} do
        {acquired_at_ms, value} when is_integer(acquired_at_ms) and is_integer(value) ->
          now_ms - acquired_at_ms > value

        _ ->
          false
      end

    owner_dead? or expired?
  end

  defp lock_age_ms(lock, now_ms) do
    case Map.get(lock, :acquired_at_ms) do
      acquired_at_ms when is_integer(acquired_at_ms) ->
        max(now_ms - acquired_at_ms, 0)

      _ ->
        0
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(_), do: %{}
end
