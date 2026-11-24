defmodule LemonGateway.Slots do
  @moduledoc """
  Global FIFO execution permits owned by live Run processes.

  Acquisition is asynchronous: the owner receives `{:slot_granted, permit_ref}`.
  Cancellation removes waiting admission, but a running owner retains its permit
  until release or death so cancellation cannot oversubscribe the executor.

  The limit is `[gateway] max_concurrent_runs`, re-read on every
  `:config_reloaded` event: a raised limit grants waiting runs at once, a lowered
  one stops new grants until running permits drain below it. A start-time `:max`
  option pins the limit and disables reloading.
  """
  use GenServer

  require Logger

  # `LemonCore.Config.Gateway`'s default, for a test replacement config that
  # omits the key.
  @default_max 2

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  def acquire(run_id, run_pid \\ self())
      when is_binary(run_id) and run_id != "" and is_pid(run_pid) do
    GenServer.cast(__MODULE__, {:acquire, run_id, run_pid})
  end

  def release(permit_ref) when is_reference(permit_ref) do
    GenServer.cast(__MODULE__, {:release, permit_ref})
  end

  def cancel_by_run_id(run_id, reason \\ :user_requested) when is_binary(run_id) do
    GenServer.cast(__MODULE__, {:cancel, run_id, reason})
  end

  def stats(table \\ __MODULE__) do
    case :ets.lookup(table, :stats) do
      [{:stats, stats}] -> {:ok, stats}
      [] -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
  end

  @impl true
  def init({name, opts}) do
    pinned? = Keyword.has_key?(opts, :max)

    max =
      Keyword.get_lazy(opts, :max, fn ->
        LemonCore.GatewayConfig.get(:max_concurrent_runs, @default_max)
      end)

    if valid_max?(max) do
      :ets.new(name, [:named_table, :protected, read_concurrency: true])
      unless pinned?, do: :ok = LemonCore.Bus.subscribe("system")

      state = %{
        table: name,
        max: max,
        runs: %{},
        permits: %{},
        monitors: %{},
        waitq: :queue.new()
      }

      {:ok, publish(state)}
    else
      {:stop, {:invalid_max_concurrent_runs, max}}
    end
  end

  @impl true
  def handle_cast({:acquire, run_id, pid}, state) do
    state =
      if Map.has_key?(state.runs, run_id) or not Process.alive?(pid) do
        state
      else
        monitor = Process.monitor(pid)
        entry = %{pid: pid, monitor: monitor, permit: nil}

        %{
          state
          | runs: Map.put(state.runs, run_id, entry),
            monitors: Map.put(state.monitors, monitor, run_id),
            waitq: :queue.in(run_id, state.waitq)
        }
      end

    {:noreply, state |> grant() |> publish()}
  end

  def handle_cast({:release, permit}, state) do
    state =
      case Map.get(state.permits, permit) do
        nil -> state
        run_id -> remove(state, run_id)
      end

    {:noreply, state |> grant() |> publish()}
  end

  def handle_cast({:cancel, run_id, reason}, state) do
    state =
      case Map.get(state.runs, run_id) do
        nil ->
          state

        entry ->
          GenServer.cast(entry.pid, {:cancel, reason})
          if is_nil(entry.permit), do: remove(state, run_id), else: state
      end

    {:noreply, state |> grant() |> publish()}
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :config_reloaded}, state) do
    max = LemonCore.GatewayConfig.get(:max_concurrent_runs, @default_max)

    state =
      if valid_max?(max) do
        %{state | max: max}
      else
        Logger.error(
          "gateway.max_concurrent_runs must be a positive integer; keeping #{state.max}"
        )

        state
      end

    {:noreply, state |> grant() |> publish()}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      case Map.get(state.monitors, monitor) do
        nil -> state
        run_id -> remove(state, run_id)
      end

    {:noreply, state |> grant() |> publish()}
  end

  # Other `system` bus traffic.
  def handle_info(_message, state), do: {:noreply, state}

  defp valid_max?(max), do: is_integer(max) and max > 0

  defp grant(state) when map_size(state.permits) >= state.max, do: state

  defp grant(state) do
    case :queue.out(state.waitq) do
      {:empty, _} ->
        state

      {{:value, run_id}, waitq} ->
        state = %{state | waitq: waitq}
        entry = Map.fetch!(state.runs, run_id)

        if Process.alive?(entry.pid) do
          permit = make_ref()
          send(entry.pid, {:slot_granted, permit})

          %{
            state
            | runs: Map.put(state.runs, run_id, %{entry | permit: permit}),
              permits: Map.put(state.permits, permit, run_id)
          }
          |> grant()
        else
          state |> remove(run_id) |> grant()
        end
    end
  end

  defp remove(state, run_id) do
    {entry, runs} = Map.pop!(state.runs, run_id)
    Process.demonitor(entry.monitor, [:flush])

    %{
      state
      | runs: runs,
        permits: Map.delete(state.permits, entry.permit),
        monitors: Map.delete(state.monitors, entry.monitor),
        waitq:
          if(is_nil(entry.permit),
            do: :queue.filter(&(&1 != run_id), state.waitq),
            else: state.waitq
          )
    }
  end

  defp publish(state) do
    :ets.insert(
      state.table,
      {:stats,
       %{
         in_flight: map_size(state.permits),
         waitq: :queue.len(state.waitq),
         max: state.max
       }}
    )

    state
  end
end
