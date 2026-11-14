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
  Run `fun` while holding `key`. Blocks until the lock is available. A key
  inherited through `inherit/2` is already held by the holder, so this takes
  the holder-scoped substitute key, shared only with the holder's other helpers.
  """
  @spec with_lock(key(), (-> result)) :: result when result: var
  def with_lock(key, fun) when is_function(fun, 0) do
    case Process.get(@inherited_key, %{}) do
      %{^key => holder} -> acquire({:inherited, key, holder}, fun)
      _ -> acquire(key, fun)
    end
  end

  defp acquire(key, fun) do
    :ok = GenServer.call(__MODULE__, {:acquire, key, self()}, :infinity)
    Process.put(@held_key, [key | Process.get(@held_key, [])])

    try do
      fun.()
    after
      Process.put(@held_key, List.delete(Process.get(@held_key, []), key))
      GenServer.call(__MODULE__, {:release, key, self()}, :infinity)
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
  @spec with_locks([key()], (-> result)) :: result when result: var
  def with_locks(keys, fun) when is_list(keys) and is_function(fun, 0) do
    keys
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.reduce(fun, fn key, inner -> fn -> with_lock(key, inner) end end)
    |> then(& &1.())
  end

  @doc "Lock key for a file path (expanded to an absolute path)."
  @spec path_key(String.t()) :: key()
  def path_key(path) when is_binary(path), do: {:path, Path.expand(path)}

  # Server

  @impl true
  def init(:ok), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, key, pid}, from, state) do
    case Map.fetch(state.locks, key) do
      :error ->
        {:reply, :ok, grant(state, key, pid, :queue.new())}

      {:ok, %{holder: ^pid} = lock} ->
        {:reply, :ok, put_in(state.locks[key], %{lock | count: lock.count + 1})}

      {:ok, lock} ->
        lock = %{lock | waiters: :queue.in({from, pid}, lock.waiters)}
        {:noreply, put_in(state.locks[key], lock)}
    end
  end

  def handle_call({:release, key, pid}, _from, state) do
    case Map.fetch(state.locks, key) do
      {:ok, %{holder: ^pid, count: count} = lock} when count > 1 ->
        {:reply, :ok, put_in(state.locks[key], %{lock | count: count - 1})}

      {:ok, %{holder: ^pid} = lock} ->
        Process.demonitor(lock.monitor, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, lock.monitor)}
        {:reply, :ok, grant_next(state, key, lock.waiters)}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {key, monitors} ->
        lock = Map.fetch!(state.locks, key)
        {:noreply, grant_next(%{state | monitors: monitors}, key, lock.waiters)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp grant(state, key, pid, waiters) do
    ref = Process.monitor(pid)
    lock = %{holder: pid, count: 1, monitor: ref, waiters: waiters}

    %{
      state
      | locks: Map.put(state.locks, key, lock),
        monitors: Map.put(state.monitors, ref, key)
    }
  end

  defp grant_next(state, key, waiters) do
    case :queue.out(waiters) do
      {:empty, _} ->
        %{state | locks: Map.delete(state.locks, key)}

      {{:value, {from, pid}}, rest} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          grant(state, key, pid, rest)
        else
          grant_next(state, key, rest)
        end
    end
  end
end
