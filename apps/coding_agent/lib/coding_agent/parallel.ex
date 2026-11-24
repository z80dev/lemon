defmodule CodingAgent.Parallel do
  @moduledoc """
  Concurrency control utilities for task execution.

  Native task lineages share the monitored TaskSemaphore; background runs have
  their own BackgroundRunSemaphore, so idle `/bg` sessions never block a task.
  """

  defmodule Semaphore do
    @moduledoc """
    A counting semaphore implemented as a GenServer.

    Limits the number of concurrent operations. Callers block on `acquire`
    until a slot becomes available, then must call `release/1` when done.

    Slots belong to the acquiring process and are reclaimed when it exits.
    An anonymous acquisition (`acquire/1`) always consumes its own slot,
    including repeated acquisitions by the same caller. A keyed acquisition
    (`acquire/3`) is re-entrant along a lineage: when the caller's key or any
    listed ancestor key already holds a slot, the caller joins that slot instead
    of taking another. A slot is freed when its last holder releases or exits.
    This lets a child block on its own descendants without deadlocking the pool.
    Each successful acquisition needs its own release.
    """

    use GenServer

    @type t :: GenServer.server()

    @spec start_link(pos_integer()) :: GenServer.on_start()
    def start_link(max_concurrency) when is_integer(max_concurrency) and max_concurrency > 0 do
      GenServer.start_link(__MODULE__, max_concurrency)
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) when is_list(opts) do
      max = Keyword.fetch!(opts, :max)
      name = Keyword.get(opts, :name)

      if name do
        GenServer.start_link(__MODULE__, max, name: name)
      else
        GenServer.start_link(__MODULE__, max)
      end
    end

    @doc """
    Acquire a slot of its own. Blocks until a slot is available.
    """
    @spec acquire(t()) :: :ok
    def acquire(semaphore), do: acquire(semaphore, nil, [])

    @doc """
    Acquire a slot for `key`, joining the slot already held by `key` or by any
    of its `lineage` keys (nearest ancestor first). Blocks until granted.
    """
    @spec acquire(t(), term(), [term()]) :: :ok
    def acquire(semaphore, key, lineage) when is_list(lineage) do
      # Caller policy is to wait for capacity until release or caller death.
      # The server defers its reply and monitors waiters; a call timeout without
      # cancelling the queued acquisition could leak a subsequently granted slot.
      GenServer.call(semaphore, {:acquire, key, lineage}, :infinity)
    end

    @doc """
    Release one acquisition held by the calling process, allowing a waiter to
    proceed. Releases from processes that hold nothing are ignored.
    """
    @spec release(t()) :: :ok
    def release(semaphore) do
      GenServer.cast(semaphore, {:release, self()})
    end

    @doc """
    Returns the current number of available slots.
    """
    @spec available(t()) :: non_neg_integer()
    def available(semaphore) do
      GenServer.call(semaphore, :available)
    end

    # -- Server callbacks --

    @impl true
    def init(max) do
      {:ok, %{max: max, waiters: :queue.new(), holders: %{}, monitors: %{}, slots: %{}}}
    end

    @impl true
    def handle_call({:acquire, key, lineage}, {pid, _tag} = from, state) do
      ref = Process.monitor(pid)
      # An anonymous acquisition is keyed by its own, never-shared reference.
      key = if is_nil(key), do: ref, else: key

      case grantable(state, key, lineage) do
        {:ok, slot} ->
          {:reply, :ok, grant(state, pid, ref, slot)}

        :wait ->
          state = %{
            state
            | waiters: :queue.in(ref, state.waiters),
              monitors: Map.put(state.monitors, ref, {:waiter, from, key, lineage})
          }

          {:noreply, state}
      end
    end

    def handle_call(:available, _from, state) do
      {:reply, max(state.max - map_size(state.slots), 0), state}
    end

    @impl true
    def handle_cast({:release, pid}, state) do
      case Map.get(state.holders, pid, []) do
        [ref | _rest] ->
          Process.demonitor(ref, [:flush])
          {:noreply, state |> remove_holder(pid, ref) |> drain_waiters()}

        [] ->
          {:noreply, state}
      end
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
      case Map.get(state.monitors, ref) do
        {:holder, ^pid, _slot} ->
          {:noreply, state |> remove_holder(pid, ref) |> drain_waiters()}

        {:waiter, _from, _key, _lineage} ->
          {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

        nil ->
          {:noreply, state}
      end
    end

    defp grantable(state, key, lineage) do
      cond do
        slot = Enum.find([key | lineage], &Map.has_key?(state.slots, &1)) -> {:ok, slot}
        map_size(state.slots) < state.max -> {:ok, key}
        true -> :wait
      end
    end

    defp grant(state, pid, ref, slot) do
      %{
        state
        | slots: Map.update(state.slots, slot, 1, &(&1 + 1)),
          holders: Map.update(state.holders, pid, [ref], &[ref | &1]),
          monitors: Map.put(state.monitors, ref, {:holder, pid, slot})
      }
    end

    defp remove_holder(state, pid, ref) do
      {:holder, ^pid, slot} = Map.fetch!(state.monitors, ref)

      holders =
        case List.delete(Map.fetch!(state.holders, pid), ref) do
          [] -> Map.delete(state.holders, pid)
          refs -> Map.put(state.holders, pid, refs)
        end

      slots =
        case Map.fetch!(state.slots, slot) do
          1 -> Map.delete(state.slots, slot)
          count -> Map.put(state.slots, slot, count - 1)
        end

      %{state | slots: slots, holders: holders, monitors: Map.delete(state.monitors, ref)}
    end

    # Waiters are granted in FIFO order. A waiter whose lineage already holds a
    # slot needs no free slot, so it may be granted past a blocked head.
    defp drain_waiters(state) do
      {waiters, state} =
        state.waiters
        |> :queue.to_list()
        |> Enum.reduce({[], state}, fn ref, {kept, state} ->
          case Map.get(state.monitors, ref) do
            {:waiter, {pid, _tag} = from, key, lineage} ->
              case {Process.alive?(pid), grantable(state, key, lineage)} do
                {false, _grant} ->
                  Process.demonitor(ref, [:flush])
                  {kept, %{state | monitors: Map.delete(state.monitors, ref)}}

                {true, {:ok, slot}} ->
                  GenServer.reply(from, :ok)
                  {kept, grant(state, pid, ref, slot)}

                {true, :wait} ->
                  {[ref | kept], state}
              end

            _ ->
              {kept, state}
          end
        end)

      %{state | waiters: :queue.from_list(Enum.reverse(waiters))}
    end
  end

  @doc """
  Returns the default max concurrency based on the number of schedulers.
  """
  @spec default_max_concurrency() :: pos_integer()
  def default_max_concurrency do
    System.schedulers_online()
  end
end
