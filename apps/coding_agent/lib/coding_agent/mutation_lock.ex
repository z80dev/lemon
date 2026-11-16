defmodule CodingAgent.MutationLock do
  @moduledoc """
  Node-local, re-entrant mutual exclusion for mutating tool calls.

  The agent loop runs every tool call of a batch concurrently. Tools that
  mutate the workspace take locks here so they never interleave:

    * `{:session, id}` - taken by the tool registry around every mutating tool
      (`write`, `edit`, `patch`, `bash`, `fs_checkpoint`), so one session's
      mutating calls run one at a time while read-only calls stay parallel.
    * `{:path, absolute_path}` - taken by file-mutating tools around their
      read-modify-write, so concurrent edits of one file (from any session)
      apply in turn instead of the last write silently winning.

  Locks are granted FIFO, are re-entrant for the holding process, and are
  released automatically when the holder exits (for example when an aborted
  tool task is killed). Callers that need several locks must take them through
  `with_locks/2`, which acquires in sorted order to avoid lock-order deadlocks.

  Queued callers are monitored and removed immediately on `:DOWN`. Acquisition
  returns `{:error, :lock_timeout}` without running the callback after 30 seconds
  by default (a caller policy, not an execution deadline). Pass a finite
  millisecond timeout as the third argument to override it.

  ## Inheritance

  A holder that runs work in helper processes and waits for them (the `eval`
  tool bridge, whose cell holds `{:session, id}` while its inner tool calls run
  in tasks) would deadlock if those helpers took the same lock. `held/0` names
  the keys the calling process holds and `inherit/2` hands them to a helper:
  `with_lock/2` on an inherited key then takes `{:inherited, key, holder}`
  instead, so helpers of one holder still exclude each other (two inner
  mutations never interleave) without waiting on the lock their holder owns.
  This is only sound while the holder outlives every inheritor, so a holder
  MUST wait for or kill each helper before its own `with_lock/2` returns. Keys
  that were not inherited (for example `{:path, _}` taken by an inner file tool)
  are acquired normally.
  """

  use GenServer

  @type key :: term()

  @held_key {__MODULE__, :held}
  @inherited_key {__MODULE__, :inherited}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` while holding `key`, or return `{:error, :lock_timeout}`.
  A key inherited through `inherit/2` takes the holder-scoped substitute key,
  shared only with the holder's other helpers.
  """
  @spec with_lock(key(), (-> result), non_neg_integer()) ::
          result | {:error, :lock_timeout}
        when result: var
  def with_lock(key, fun, timeout \\ 30_000)
      when is_function(fun, 0) and is_integer(timeout) and timeout >= 0 do
    case Process.get(@inherited_key, %{}) do
      %{^key => holder} -> acquire({:inherited, key, holder}, fun, timeout)
      _ -> acquire(key, fun, timeout)
    end
  end

  defp acquire(key, fun, timeout) do
    request = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      try do
        GenServer.call(__MODULE__, {:acquire, key, self(), request, deadline}, timeout + 1_000)
      catch
        :exit, {:timeout, _} ->
          GenServer.cast(__MODULE__, {:cancel, key, request})
          {:error, :lock_timeout}
      end

    case result do
      :ok ->
        Process.put(@held_key, [key | Process.get(@held_key, [])])

        try do
          fun.()
        after
          Process.put(@held_key, List.delete(Process.get(@held_key, []), key))
          GenServer.cast(__MODULE__, {:release, key, self()})
        end

      {:error, :lock_timeout} = error ->
        error
    end
  end

  @doc """
  Keys the calling process currently holds, including inherited ones.
  """
  @spec held() :: [key()]
  def held do
    Enum.uniq(Process.get(@held_key, []) ++ Map.keys(Process.get(@inherited_key, %{})))
  end

  @doc """
  Treat `keys`, held by `holder` (which outlives the caller), as held for the
  caller. See "Inheritance" above for the lifetime obligation on the holder.
  """
  @spec inherit([key()], pid()) :: :ok
  def inherit(keys, holder) when is_list(keys) and is_pid(holder) do
    inherited = Map.new(keys, &{&1, holder})
    Process.put(@inherited_key, Map.merge(Process.get(@inherited_key, %{}), inherited))
    :ok
  end

  @doc """
  Run `fun` while holding every key in `keys` (acquired in sorted order).
  """
  @spec with_locks([key()], (-> result), non_neg_integer()) ::
          result | {:error, :lock_timeout}
        when result: var
  def with_locks(keys, fun, timeout \\ 30_000)
      when is_list(keys) and is_function(fun, 0) and is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout

    keys
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.reduce(fun, fn key, inner ->
      fn -> with_lock(key, inner, max(deadline - System.monotonic_time(:millisecond), 0)) end
    end)
    |> then(& &1.())
  end

  @doc "Lock key for a file path (expanded to an absolute path)."
  @spec path_key(String.t()) :: key()
  def path_key(path) when is_binary(path), do: {:path, Path.expand(path)}

  # Server

  @impl true
  def init(:ok), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, key, pid, request, deadline}, from, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case Map.fetch(state.locks, key) do
      _ when remaining < 0 ->
        {:reply, {:error, :lock_timeout}, state}

      {:ok, %{holder: ^pid} = lock} ->
        {:reply, :ok, put_in(state.locks[key], %{lock | count: lock.count + 1})}

      :error ->
        {:reply, :ok, grant(state, key, pid, :queue.new(), request)}

      {:ok, lock} ->
        ref = Process.monitor(pid)
        timer = Process.send_after(self(), {:expire, key, request}, remaining)

        waiter = %{
          from: from,
          pid: pid,
          ref: ref,
          timer: timer,
          request: request,
          deadline: deadline
        }

        state = put_in(state.monitors[ref], {:waiter, key, request})
        {:noreply, put_in(state.locks[key].waiters, :queue.in(waiter, lock.waiters))}
    end
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    case Map.fetch(state.locks, key) do
      {:ok, %{holder: ^pid, count: count} = lock} when count > 1 ->
        {:noreply, put_in(state.locks[key], %{lock | count: count - 1})}

      {:ok, %{holder: ^pid} = lock} ->
        {:noreply, release(state, key, lock)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:cancel, key, request}, state) do
    case Map.get(state.locks, key) do
      %{request: ^request} = lock -> {:noreply, release(state, key, lock)}
      _ -> {:noreply, remove_waiter(state, key, request, false)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      {:holder, key} ->
        {:noreply, release(state, key, Map.fetch!(state.locks, key))}

      {:waiter, key, request} ->
        {:noreply, remove_waiter(state, key, request, false)}
    end
  end

  def handle_info({:expire, key, request}, state) do
    {:noreply, remove_waiter(state, key, request, true)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp release(state, key, lock) do
    Process.demonitor(lock.monitor, [:flush])
    state = %{state | monitors: Map.delete(state.monitors, lock.monitor)}
    grant_next(state, key, lock.waiters)
  end

  defp grant(state, key, pid, waiters, request) do
    ref = Process.monitor(pid)
    lock = %{holder: pid, count: 1, monitor: ref, waiters: waiters, request: request}

    %{
      state
      | locks: Map.put(state.locks, key, lock),
        monitors: Map.put(state.monitors, ref, {:holder, key})
    }
  end

  defp grant_next(state, key, waiters) do
    case :queue.out(waiters) do
      {:empty, _} ->
        %{state | locks: Map.delete(state.locks, key)}

      {{:value, waiter}, rest} ->
        state = forget_waiter(state, waiter)

        if waiter.deadline < System.monotonic_time(:millisecond) do
          GenServer.reply(waiter.from, {:error, :lock_timeout})
          grant_next(state, key, rest)
        else
          GenServer.reply(waiter.from, :ok)
          grant(state, key, waiter.pid, rest, waiter.request)
        end
    end
  end

  defp remove_waiter(state, key, request, reply?) do
    case Map.get(state.locks, key) do
      nil ->
        state

      lock ->
        {removed, kept} =
          lock.waiters |> :queue.to_list() |> Enum.split_with(&(&1.request == request))

        state =
          Enum.reduce(removed, state, fn waiter, acc ->
            if reply?, do: GenServer.reply(waiter.from, {:error, :lock_timeout})
            forget_waiter(acc, waiter)
          end)

        put_in(state.locks[key].waiters, :queue.from_list(kept))
    end
  end

  defp forget_waiter(state, waiter) do
    Process.cancel_timer(waiter.timer)
    Process.demonitor(waiter.ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, waiter.ref)}
  end
end
