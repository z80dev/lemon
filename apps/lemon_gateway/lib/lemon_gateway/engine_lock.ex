defmodule LemonGateway.EngineLock do
  @moduledoc """
  FIFO admission queue for engine-session Registry names.

  The acquiring process owns the unique name in `RunRegistry`; this process
  only orders contenders and monitors reservations and waiters. Explicit release
  unregisters the name before advancing the queue. No sweep or age-based transfer.
  """
  use GenServer

  @type thread_key :: term()

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
    acquire_until(thread_key, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp acquire_until(thread_key, deadline) do
    timeout_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    with {:ok, release} <-
           GenServer.call(__MODULE__, {:acquire, thread_key, timeout_ms}, timeout_ms + 1_000) do
      case Registry.register(LemonGateway.RunRegistry, {:engine_session, thread_key}, nil) do
        {:ok, _} ->
          {:ok,
           fn ->
             Registry.unregister(LemonGateway.RunRegistry, {:engine_session, thread_key})
             release.()
           end}

        {:error, {:already_registered, _}} ->
          release.()

          if System.monotonic_time(:millisecond) < deadline do
            acquire_until(thread_key, deadline)
          else
            {:error, :timeout}
          end
      end
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{locks: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:acquire, thread_key, timeout_ms}, {pid, _ref} = from, state) do
    state =
      case {Map.get(state.locks, thread_key),
            Registry.lookup(LemonGateway.RunRegistry, {:engine_session, thread_key})} do
        {nil, [{owner, _}]} ->
          {state, _release} = grant_lock(state, thread_key, owner)
          state

        _ ->
          state
      end

    case Map.get(state.locks, thread_key) do
      nil ->
        {state, release_fun} = grant_lock(state, thread_key, pid)

        {:reply, {:ok, release_fun}, state}

      _locked ->
        timer_ref = Process.send_after(self(), {:lock_timeout, thread_key, from}, timeout_ms)
        waiter = %{from: from, pid: pid, timer_ref: timer_ref, mon_ref: Process.monitor(pid)}

        waiters =
          Map.update(
            state.waiters,
            thread_key,
            :queue.from_list([waiter]),
            &:queue.in(waiter, &1)
          )

        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_cast({:release, thread_key, pid}, state) do
    case Map.get(state.locks, thread_key) do
      %{owner: ^pid, mon_ref: mon_ref} ->
        Process.demonitor(mon_ref, [:flush])
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
          GenServer.reply(from, {:error, :timeout})
        end

        waiters =
          if :queue.is_empty(queue),
            do: Map.delete(state.waiters, thread_key),
            else: Map.put(state.waiters, thread_key, queue)

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.waiters, state, fn {key, queue}, acc ->
        {kept, removed} =
          queue |> :queue.to_list() |> Enum.split_with(&(&1.mon_ref != ref))

        Enum.each(removed, &Process.cancel_timer(&1.timer_ref))

        waiters =
          if kept == [],
            do: Map.delete(acc.waiters, key),
            else: Map.put(acc.waiters, key, :queue.from_list(kept))

        %{acc | waiters: waiters}
      end)

    case Enum.find(state.locks, fn {_key, lock} -> lock.mon_ref == ref end) do
      {key, _} -> {:noreply, release_and_next(state, key)}
      nil -> {:noreply, state}
    end
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
        Process.demonitor(waiter.mon_ref, [:flush])
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
        Process.demonitor(waiter.mon_ref, [:flush])
        {:queue.from_list(kept), true}

      _ ->
        {:queue.from_list(list), false}
    end
  end
end
