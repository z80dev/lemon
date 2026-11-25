defmodule LemonRouter.Slots do
  @moduledoc """
  Global FIFO execution permits owned by live `LemonRouter.RunProcess` owners.

  Acquisition is asynchronous: the owner receives `{:slot_granted, permit_ref}`.
  Cancellation removes waiting admission, but a running owner retains its permit
  until release or death so cancellation cannot oversubscribe the executor.

  The limit is `[gateway] max_concurrent_runs`, re-read on every
  `:config_reloaded` event: a raised limit grants waiting runs at once, a lowered
  one stops new grants until running permits drain below it. A start-time `:max`
  option pins the limit and disables reloading.

  ## Lending a blocked run's permit

  A run that blocks on work needing its own permits (a synchronous `agent`
  delegation or join) lends its permit with `suspend/2`: the permit stops
  counting and the next waiter, typically the child, is admitted. `resume/3`
  returns the run to the front of the queue and, with `:wait`, blocks until
  it holds a permit again; `:nowait` (abort paths) re-queues without blocking.
  A run may hold several suspensions (parallel tool calls); it re-queues when
  the last one ends or its holder dies. Releasing or losing the Run ends all
  of them. Blocked parents therefore never hold capacity their descendants
  need, so delegation depth and fan-in cannot stall admission.
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

  @doc """
  Lend `run_id`'s granted permit while the caller blocks. Returns a token for
  `resume/3`, or `{:error, :not_holding}` when the run holds no permit here.
  """
  @spec suspend(String.t(), GenServer.server()) :: {:ok, reference()} | {:error, :not_holding}
  def suspend(run_id, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:suspend, run_id})
  end

  @doc """
  End a suspension. `:wait` blocks until the run holds a permit again (or no
  longer exists); `:nowait` re-queues the run at the front without waiting.
  """
  @spec resume(reference(), :wait | :nowait, GenServer.server()) :: :ok
  def resume(token, mode \\ :wait, server \\ __MODULE__)

  def resume(token, :wait, server) when is_reference(token),
    do: GenServer.call(server, {:resume, token}, :infinity)

  def resume(token, :nowait, server) when is_reference(token),
    do: GenServer.cast(server, {:resume, token})

  @doc """
  Slot lender for the executor's `:slot_lender` run option: lend `run_id`'s
  permit while the calling tool process blocks, or `:none` when it holds none
  here or the permit authority is gone.
  """
  @spec lend(String.t()) :: {:ok, reference()} | :none
  def lend(run_id) when is_binary(run_id) do
    case suspend(run_id) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> :none
    end
  catch
    :exit, _reason -> :none
  end

  @doc "Ends a `lend/1` suspension (see `resume/3`); a lost authority is a no-op."
  @spec return(reference(), :wait | :nowait) :: :ok
  def return(token, mode) when is_reference(token) and mode in [:wait, :nowait] do
    resume(token, mode)
  catch
    :exit, _reason -> :ok
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
        waitq: :queue.new(),
        # Suspensions: token => run_id, holder monitor => token, and every
        # lent run's permit => run_id (lent permits are not in `permits`).
        lenders: %{},
        lend_monitors: %{},
        lent_permits: %{}
      }

      {:ok, publish(state)}
    else
      {:stop, {:invalid_max_concurrent_runs, max}}
    end
  end

  @impl true
  def handle_call({:suspend, run_id}, {holder, _tag}, state) do
    case Map.get(state.runs, run_id) do
      %{permit: permit} = entry when is_reference(permit) ->
        token = make_ref()
        monitor = Process.monitor(holder)
        lent = entry[:lent] || %{tokens: %{}, waiters: []}
        lent = %{lent | tokens: Map.put(lent.tokens, token, monitor)}

        state = %{
          state
          | runs: Map.put(state.runs, run_id, Map.put(entry, :lent, lent)),
            permits: Map.delete(state.permits, permit),
            lent_permits: Map.put(state.lent_permits, permit, run_id),
            # A run re-queued by an ended suspension is lent again instead.
            waitq: :queue.filter(&(&1 != run_id), state.waitq),
            lenders: Map.put(state.lenders, token, run_id),
            lend_monitors: Map.put(state.lend_monitors, monitor, token)
        }

        {:reply, {:ok, token}, state |> grant() |> publish()}

      _ ->
        {:reply, {:error, :not_holding}, state}
    end
  end

  def handle_call({:resume, token}, from, state) do
    {:noreply, state |> end_suspension(token, from) |> grant() |> publish()}
  end

  @impl true
  def handle_cast({:resume, token}, state) do
    {:noreply, state |> end_suspension(token, nil) |> grant() |> publish()}
  end

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
      case Map.get(state.permits, permit) || Map.get(state.lent_permits, permit) do
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
      case {Map.get(state.monitors, monitor), Map.get(state.lend_monitors, monitor)} do
        {run_id, _token} when is_binary(run_id) -> remove(state, run_id)
        {nil, token} when is_reference(token) -> end_suspension(state, token, nil)
        _ -> state
      end

    {:noreply, state |> grant() |> publish()}
  end

  # Other `system` bus traffic.
  def handle_info(_message, state), do: {:noreply, state}

  # The last ended suspension re-queues its run at the front. `from` (a
  # waiting resume) is answered once the run holds a permit or is gone.
  defp end_suspension(state, token, from) do
    with run_id when is_binary(run_id) <- Map.get(state.lenders, token),
         %{lent: %{tokens: tokens} = lent} = entry <- Map.get(state.runs, run_id) do
      {monitor, tokens} = Map.pop(tokens, token)
      Process.demonitor(monitor, [:flush])

      state = %{
        state
        | lenders: Map.delete(state.lenders, token),
          lend_monitors: Map.delete(state.lend_monitors, monitor)
      }

      cond do
        map_size(tokens) > 0 ->
          # Another blocked call of the same run still lends its permit.
          if from, do: GenServer.reply(from, :ok)
          put_lent(state, run_id, entry, %{lent | tokens: tokens})

        true ->
          waiters = if from, do: [from | lent.waiters], else: lent.waiters
          state = put_lent(state, run_id, entry, %{tokens: %{}, waiters: waiters})

          if :queue.member(run_id, state.waitq),
            do: state,
            else: %{state | waitq: :queue.in_r(run_id, state.waitq)}
      end
    else
      _ ->
        if from, do: GenServer.reply(from, :ok)
        %{state | lenders: Map.delete(state.lenders, token)}
    end
  end

  defp put_lent(state, run_id, entry, lent),
    do: %{state | runs: Map.put(state.runs, run_id, %{entry | lent: lent})}

  defp valid_max?(max), do: is_integer(max) and max > 0

  defp grant(state) when map_size(state.permits) >= state.max, do: state

  defp grant(state) do
    case :queue.out(state.waitq) do
      {:empty, _} ->
        state

      {{:value, run_id}, waitq} ->
        state = %{state | waitq: waitq}
        entry = Map.fetch!(state.runs, run_id)

        cond do
          not Process.alive?(entry.pid) ->
            state |> remove(run_id) |> grant()

          is_map(entry[:lent]) ->
            # A resumed run takes its own permit back; its Run never noticed.
            Enum.each(entry.lent.waiters, &GenServer.reply(&1, :ok))

            %{
              state
              | runs: Map.put(state.runs, run_id, Map.delete(entry, :lent)),
                permits: Map.put(state.permits, entry.permit, run_id),
                lent_permits: Map.delete(state.lent_permits, entry.permit)
            }
            |> grant()

          true ->
            permit = make_ref()
            send(entry.pid, {:slot_granted, permit})

            %{
              state
              | runs: Map.put(state.runs, run_id, %{entry | permit: permit}),
                permits: Map.put(state.permits, permit, run_id)
            }
            |> grant()
        end
    end
  end

  defp remove(state, run_id) do
    {entry, runs} = Map.pop!(state.runs, run_id)
    Process.demonitor(entry.monitor, [:flush])

    state =
      case entry[:lent] do
        %{tokens: tokens, waiters: waiters} ->
          Enum.each(waiters, &GenServer.reply(&1, :ok))
          Enum.each(tokens, fn {_token, monitor} -> Process.demonitor(monitor, [:flush]) end)

          %{
            state
            | lenders: Map.drop(state.lenders, Map.keys(tokens)),
              lend_monitors: Map.drop(state.lend_monitors, Map.values(tokens))
          }

        nil ->
          state
      end

    %{
      state
      | runs: runs,
        permits: Map.delete(state.permits, entry.permit),
        lent_permits: Map.delete(state.lent_permits, entry.permit),
        monitors: Map.delete(state.monitors, entry.monitor),
        waitq: :queue.filter(&(&1 != run_id), state.waitq)
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
