defmodule LemonGateway.EngineLock do
  @moduledoc false
  use GenServer

  @type thread_key :: term()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec acquire(thread_key(), non_neg_integer()) ::
          {:ok, (-> :ok)} | {:error, :timeout}
  def acquire(thread_key, timeout_ms \\ 60_000) do
    GenServer.call(__MODULE__, {:acquire, thread_key, timeout_ms}, timeout_ms + 1_000)
  end

  @impl true
  def init(_opts) do
    {:ok, %{locks: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:acquire, thread_key, timeout_ms}, {pid, _ref} = from, state) do
    case Map.get(state.locks, thread_key) do
      nil ->
        {state, release_fun} = grant_lock(state, thread_key, pid)
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

  defp grant_lock(state, thread_key, pid) do
    mon_ref = Process.monitor(pid)
    locks = Map.put(state.locks, thread_key, %{owner: pid, mon_ref: mon_ref})
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
end
