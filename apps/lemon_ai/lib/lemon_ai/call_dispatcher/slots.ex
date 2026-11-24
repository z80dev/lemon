defmodule LemonAi.CallDispatcher.Slots do
  @moduledoc false
  use GenServer

  @default_cap 10

  # The root supervisor owns this table: authority/dispatcher restarts must not
  # erase leases for callbacks or streams that are still running.
  def init_table do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
  end

  def start_link(opts) do
    provider = Keyword.fetch!(opts, :provider)
    GenServer.start_link(__MODULE__, provider, name: via(provider))
  end

  def via(provider), do: {:via, Registry, {LemonAi.CallDispatcherRegistry, provider}}

  def ensure_started(provider) do
    case GenServer.whereis(via(provider)) do
      nil ->
        if :ets.member(__MODULE__, {:provider, provider}) do
          # Reject this attempt, even if recovery succeeds. DynamicSupervisor
          # normally restarts crashed authorities; this also recovers providers
          # after their dynamic supervisor itself was replaced.
          _ = start_authority(provider)
          {:error, :admission_unavailable}
        else
          start_authority(provider)
        end

      pid ->
        {:ok, pid}
    end
  rescue
    ArgumentError -> {:error, :admission_unavailable}
  catch
    :exit, _ -> {:error, :admission_unavailable}
  end

  defp start_authority(provider) do
    case DynamicSupervisor.start_child(
           LemonAi.ProviderSupervisor,
           {__MODULE__, provider: provider}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      _ -> {:error, :admission_unavailable}
    end
  end

  def call(provider, request, timeout \\ 5_000) do
    with {:ok, pid} <- ensure_started(provider) do
      GenServer.call(pid, request, timeout)
    end
  catch
    :exit, _ -> {:error, :admission_unavailable}
  end

  def providers do
    :ets.select(__MODULE__, [{{{:provider, :"$1"}, :_}, [], [:"$1"]}])
  end

  def release(provider, lease) do
    # A completed stream must not be resurrected by authority recovery.
    :ets.delete(__MODULE__, {:lease, provider, lease})

    case GenServer.whereis(via(provider)) do
      nil -> :ok
      pid -> GenServer.call(pid, {:release, lease})
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(provider) do
    :ets.insert_new(__MODULE__, {{:provider, provider}, @default_cap})
    [{{:provider, ^provider}, cap}] = :ets.lookup(__MODULE__, {:provider, provider})

    monitors =
      :ets.match_object(__MODULE__, {{:lease, provider, :_}, :_})
      |> Map.new(fn {{:lease, ^provider, lease}, owner} ->
        {Process.monitor(owner), lease}
      end)

    {:ok, %{provider: provider, cap: cap, monitors: monitors, waiters: :queue.new()}}
  end

  @impl true
  def handle_call({:acquire, lease, timeout}, {owner, _} = from, state) do
    cond do
      map_size(state.monitors) < state.cap ->
        state = grant(state, owner, lease)
        {:reply, {:ok, {state.provider, lease}}, state}

      timeout == 0 ->
        {:reply, {:error, :max_concurrency}, state}

      true ->
        ref = make_ref()
        timer = Process.send_after(self(), {:waiter_timeout, ref}, timeout)
        waiter = {ref, from, owner, timer, lease}
        state = %{state | waiters: :queue.in(waiter, state.waiters)}

        :telemetry.execute(
          [:lemon_ai, :dispatcher, :queued],
          %{system_time: System.system_time()},
          %{provider: state.provider}
        )

        {:noreply, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    case Enum.find(state.monitors, fn {_monitor, ref} -> ref == lease end) do
      nil ->
        {cancelled, remaining} =
          Enum.split_with(:queue.to_list(state.waiters), &match?({_, _, _, _, ^lease}, &1))

        Enum.each(cancelled, fn {_, _, _, timer, _} -> Process.cancel_timer(timer) end)
        {:reply, :ok, %{state | waiters: :queue.from_list(remaining)}}

      {monitor, _} ->
        {:reply, :ok, release_monitor(state, monitor)}
    end
  end

  def handle_call({:set_cap, cap}, _from, state) do
    :ets.insert(__MODULE__, {{:provider, state.provider}, cap})
    {:reply, :ok, grant_waiters(%{state | cap: cap})}
  end

  def handle_call(:get_cap, _from, state), do: {:reply, state.cap, state}
  def handle_call(:active, _from, state), do: {:reply, map_size(state.monitors), state}

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{cap: state.cap, active: map_size(state.monitors), queued: :queue.len(state.waiters)},
     state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, release_monitor(state, monitor)}
  end

  def handle_info({:waiter_timeout, ref}, state) do
    {expired, remaining} =
      Enum.split_with(:queue.to_list(state.waiters), &match?({^ref, _, _, _, _}, &1))

    for {_, from, _, _, _} <- expired, do: GenServer.reply(from, {:error, :max_concurrency})
    {:noreply, %{state | waiters: :queue.from_list(remaining)}}
  end

  defp grant(state, owner, lease) do
    # Persist before replying; recovery must include an interrupted grant.
    :ets.insert(__MODULE__, {{:lease, state.provider, lease}, owner})
    monitor = Process.monitor(owner)
    %{state | monitors: Map.put(state.monitors, monitor, lease)}
  end

  defp release_monitor(state, monitor) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        state

      {lease, monitors} ->
        Process.demonitor(monitor, [:flush])
        :ets.delete(__MODULE__, {:lease, state.provider, lease})
        grant_waiters(%{state | monitors: monitors})
    end
  end

  defp grant_waiters(state) do
    with true <- map_size(state.monitors) < state.cap,
         {{:value, {_, from, owner, timer, lease}}, remaining} <- :queue.out(state.waiters) do
      _ = Process.cancel_timer(timer)
      state = grant(%{state | waiters: remaining}, owner, lease)
      GenServer.reply(from, {:ok, {state.provider, lease}})
      grant_waiters(state)
    else
      _ -> state
    end
  end
end
