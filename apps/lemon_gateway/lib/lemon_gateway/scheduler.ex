defmodule LemonGateway.Scheduler do
  @moduledoc """
  Concurrency-limited execution scheduler.

  Manages a pool of execution slots (`max_concurrent_runs`). Submission resolves
  and acknowledges its conversation worker in the caller, outside this mailbox.
  Production workers attach a generation token to slot requests. Duplicate or
  overlapping tokenized requests are ignored, and timed-out generations are
  explicitly expired before a worker requests another slot.
  """
  use GenServer
  require Logger

  alias LemonCore.Introspection
  alias LemonGateway.ExecutionRequest

  # Timeout for slot requests - workers should not wait forever
  @slot_request_timeout_ms 30_000

  @max_waiting_workers 1_024

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Submits an execution request with a caller-fixed, nonempty run ID."
  @spec submit_execution(ExecutionRequest.t()) ::
          :ok
          | {:error,
             :invalid_run_id
             | :outcome_unknown
             | :worker_unavailable
             | :worker_startup_timeout
             | :worker_start_failed}
  def submit_execution(%ExecutionRequest{run_id: run_id} = request)
      when is_binary(run_id) and run_id != "" do
    request = ExecutionRequest.ensure_conversation_key(request)
    LemonGateway.ThreadWorker.submit(request)
  end

  def submit_execution(%ExecutionRequest{}), do: {:error, :invalid_run_id}

  @doc "Requests an execution slot for the given worker. Grants immediately or queues the request."
  @spec request_slot(pid(), term()) :: :ok
  def request_slot(worker_pid, thread_key) do
    GenServer.cast(__MODULE__, {:request_slot, worker_pid, thread_key})
  end

  @doc "Requests a slot for one worker generation, deduplicating overlaps."
  @spec request_slot(pid(), term(), reference()) :: :ok
  def request_slot(worker_pid, thread_key, token) when is_reference(token) do
    GenServer.cast(__MODULE__, {:request_slot, worker_pid, thread_key, token})
  end

  @doc "Cancels one outstanding tokenized slot request."
  @spec cancel_slot_request(pid(), reference()) :: :ok
  def cancel_slot_request(worker_pid, token) when is_pid(worker_pid) and is_reference(token) do
    GenServer.cast(__MODULE__, {:cancel_slot_request, worker_pid, token})
  end

  @doc "Releases an execution slot, allowing the next queued worker to proceed."
  @spec release_slot(reference()) :: :ok
  def release_slot(slot_ref) do
    GenServer.cast(__MODULE__, {:release_slot, slot_ref})
  end

  @doc "Cancels an exact run ID, including work still waiting for a slot."
  def cancel_execution(run_id, reason) when is_binary(run_id) do
    GenServer.cast(__MODULE__, {:cancel_execution, run_id, reason})
  end

  @doc "Cancels a running execution by sending a cancel cast to the run process."
  @spec cancel(pid(), term()) :: :ok
  def cancel(run_pid, reason \\ :user_requested) do
    if is_pid(run_pid), do: GenServer.cast(run_pid, {:cancel, reason})
    :ok
  end

  @doc "Reads published slot counters without messaging the scheduler."
  def stats do
    case :ets.lookup(__MODULE__, :stats) do
      [{:stats, stats}] -> {:ok, stats}
      [] -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
  end

  @impl true
  def handle_cast(message, state), do: publish_result(dispatch_cast(message, state))

  @impl true
  def handle_info(message, state), do: publish_result(dispatch_info(message, state))

  defp publish_result({:noreply, state} = result) do
    if :ets.info(__MODULE__, :owner) == self() do
      :ets.insert(
        __MODULE__,
        {:stats,
         %{
           in_flight: map_size(state.in_flight),
           waitq: :queue.len(state.waitq),
           max: state.max
         }}
      )
    end

    result
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])

    max =
      case LemonGateway.Config.get(:max_concurrent_runs) do
        n when is_integer(n) and n > 0 ->
          n

        _ ->
          Logger.warning("Invalid max_concurrent_runs config, using default 10")
          10
      end

    :ets.insert(__MODULE__, {:stats, %{in_flight: 0, waitq: 0, max: max}})

    # Schedule periodic cleanup of stale slot requests
    schedule_slot_timeout_check()

    {:ok,
     %{
       max: max,
       in_flight: %{},
       waitq: :queue.new(),
       monitors: %{},
       worker_counts: %{},
       # Track when slot requests were queued for timeout handling
       slot_request_times: %{}
     }}
  end

  defp dispatch_cast({:cancel_execution, run_id, reason}, state) do
    Registry.select(LemonGateway.ThreadRegistry, [
      {{:"$1", :"$2", :_}, [], [:"$2"]}
    ])
    |> Enum.each(&GenServer.cast(&1, {:cancel_queued, run_id, reason}))

    {:noreply, state}
  end

  defp dispatch_cast({:request_slot, worker_pid, thread_key}, state) do
    grant_or_queue_slot(worker_pid, thread_key, nil, state)
  end

  defp dispatch_cast({:request_slot, worker_pid, thread_key, token}, state) do
    if tokenized_request_outstanding?(state, worker_pid) do
      Logger.debug(
        "Scheduler ignored overlapping slot request worker=#{inspect(worker_pid)} " <>
          "thread_key=#{inspect(thread_key)} token=#{inspect(token)}"
      )

      {:noreply, state}
    else
      grant_or_queue_slot(worker_pid, thread_key, token, state)
    end
  end

  defp dispatch_cast({:cancel_slot_request, worker_pid, token}, state) do
    state = cancel_tokenized_request(state, worker_pid, token)
    {:noreply, grant_until_full(state)}
  end

  defp dispatch_cast({:release_slot, slot_ref}, state) do
    {state, removed} = pop_in_flight(state, slot_ref)
    state = maybe_demonitor_worker(state, removed)

    Logger.debug(
      "Scheduler released slot slot_ref=#{inspect(slot_ref)} in_flight=#{map_size(state.in_flight)}/#{state.max}"
    )

    Introspection.record(
      :scheduled_job_completed,
      %{
        in_flight: map_size(state.in_flight),
        max: state.max,
        thread_key: inspect(removed[:thread_key])
      },
      engine: "lemon",
      provenance: :direct
    )

    emit_scheduler_telemetry(:slot_released, %{
      in_flight: map_size(state.in_flight),
      max: state.max,
      waitq: :queue.len(state.waitq)
    })

    {:noreply, grant_until_full(state)}
  end

  defp grant_or_queue_slot(worker_pid, thread_key, token, state) do
    cond do
      map_size(state.in_flight) >= state.max and
          :queue.len(state.waitq) >= @max_waiting_workers ->
        send(worker_pid, {:slot_request_rejected, token, :execution_queue_full})
        {:noreply, state}

      map_size(state.in_flight) < state.max ->
        slot_ref = make_ref()
        {state, mon_ref} = ensure_monitor(state, worker_pid)

        in_flight =
          Map.put(state.in_flight, slot_ref, %{
            worker: worker_pid,
            thread_key: thread_key,
            token: token,
            mon_ref: mon_ref,
            granted_at_ms: System.monotonic_time(:millisecond)
          })

        case safe_send_slot_granted(worker_pid, slot_ref, token) do
          :ok ->
            Logger.debug(
              "Scheduler granted slot worker=#{inspect(worker_pid)} thread_key=#{inspect(thread_key)} " <>
                "in_flight=#{map_size(in_flight)}/#{state.max}"
            )

            emit_scheduler_telemetry(:slot_granted, %{
              in_flight: map_size(in_flight),
              max: state.max,
              waitq: :queue.len(state.waitq),
              wait_ms: 0
            })

            {:noreply, %{state | in_flight: in_flight}}

          {:error, :dead_worker} ->
            Logger.warning(
              "Scheduler: worker #{inspect(worker_pid)} died before slot could be granted, skipping"
            )

            state = maybe_demonitor_worker(state, %{worker: worker_pid, mon_ref: mon_ref})
            {:noreply, grant_until_full(state)}
        end

      true ->
        {state, mon_ref} = ensure_monitor(state, worker_pid)
        queued_at_ms = System.monotonic_time(:millisecond)

        waitq =
          :queue.in(
            %{
              worker: worker_pid,
              thread_key: thread_key,
              token: token,
              mon_ref: mon_ref,
              queued_at_ms: queued_at_ms
            },
            state.waitq
          )

        slot_request_times = Map.put(slot_request_times(state), worker_pid, queued_at_ms)

        Logger.debug(
          "Scheduler queued slot request worker=#{inspect(worker_pid)} thread_key=#{inspect(thread_key)} " <>
            "in_flight=#{map_size(state.in_flight)}/#{state.max} waitq=#{:queue.len(waitq)}"
        )

        emit_scheduler_telemetry(:slot_queued, %{
          in_flight: map_size(state.in_flight),
          max: state.max,
          waitq: :queue.len(waitq)
        })

        {:noreply,
         state |> Map.put(:waitq, waitq) |> Map.put(:slot_request_times, slot_request_times)}
    end
  end

  defp dispatch_info({:DOWN, mon_ref, :process, pid, reason}, state) do
    Logger.debug("Scheduler: worker #{inspect(pid)} down with reason #{inspect(reason)}")

    state =
      case Map.get(state.monitors, pid) do
        ^mon_ref -> cleanup_worker(state, pid)
        _ -> state
      end

    {:noreply, grant_until_full(state)}
  end

  # Handle slot request timeout check
  defp dispatch_info(:slot_timeout_check, state) do
    state = cleanup_stale_slot_requests(state)
    schedule_slot_timeout_check()
    {:noreply, state}
  end

  # Catch-all for unknown messages to prevent crashes
  defp dispatch_info(msg, state) do
    Logger.warning("Scheduler received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp schedule_slot_timeout_check do
    Process.send_after(self(), :slot_timeout_check, @slot_request_timeout_ms)
  end

  # Remove slot requests that have been waiting too long.
  # IMPORTANT: We thread `state` through the reduce so that demonitor
  # side-effects (monitor map + worker_counts cleanup) are persisted.
  defp cleanup_stale_slot_requests(state) do
    now = System.monotonic_time(:millisecond)

    {fresh_waitq, stale_count, fresh_request_times, updated_state} =
      :queue.to_list(state.waitq)
      |> Enum.reduce({:queue.new(), 0, %{}, state}, fn
        %{queued_at_ms: queued_at, worker: worker} = entry, {q, stale_acc, times_acc, acc_state}
        when is_integer(queued_at) and is_pid(worker) ->
          if now - queued_at > @slot_request_timeout_ms do
            # Stale request - worker has been waiting too long
            Logger.warning(
              "Scheduler: dropping stale slot request for worker #{inspect(worker)}, " <>
                "queued #{div(now - queued_at, 1000)}s ago"
            )

            # Clean up monitor for this stale request, threading state
            acc_state = maybe_demonitor_worker(acc_state, entry)
            maybe_notify_slot_expired(entry)
            {q, stale_acc + 1, times_acc, acc_state}
          else
            {:queue.in(entry, q), stale_acc, Map.put(times_acc, worker, queued_at), acc_state}
          end

        malformed, {q, stale_acc, times_acc, acc_state} ->
          Logger.warning("Scheduler: dropping malformed waitq entry: #{inspect(malformed)}")
          {q, stale_acc + 1, times_acc, acc_state}
      end)

    if stale_count > 0 do
      Logger.warning("Scheduler: cleaned up #{stale_count} stale slot requests")
    end

    updated_state
    |> Map.put(:waitq, fresh_waitq)
    |> Map.put(:slot_request_times, fresh_request_times)
  end

  # Safely send slot grant message with error handling
  defp safe_send_slot_granted(worker_pid, slot_ref, token) do
    try do
      if Process.alive?(worker_pid) do
        if is_reference(token) do
          send(worker_pid, {:slot_granted, slot_ref, token})
        else
          send(worker_pid, {:slot_granted, slot_ref})
        end

        :ok
      else
        {:error, :dead_worker}
      end
    catch
      :exit, {:noproc, _} -> {:error, :dead_worker}
      :exit, _ -> {:error, :dead_worker}
    end
  end

  defp maybe_grant_next(state) do
    if map_size(state.in_flight) < state.max do
      case :queue.out(state.waitq) do
        {{:value, entry}, waitq} ->
          worker_pid = entry.worker
          thread_key = entry.thread_key
          mon_ref = entry.mon_ref
          slot_ref = make_ref()

          # Check if worker is still alive before granting
          case safe_send_slot_granted(worker_pid, slot_ref, Map.get(entry, :token)) do
            :ok ->
              in_flight =
                Map.put(state.in_flight, slot_ref, %{
                  worker: worker_pid,
                  thread_key: thread_key,
                  token: Map.get(entry, :token),
                  mon_ref: mon_ref,
                  granted_at_ms: System.monotonic_time(:millisecond)
                })

              wait_ms = wait_time_ms(entry)
              slot_request_times = Map.delete(slot_request_times(state), worker_pid)

              emit_scheduler_telemetry(:slot_granted, %{
                in_flight: map_size(in_flight),
                max: state.max,
                waitq: :queue.len(waitq),
                wait_ms: wait_ms
              })

              state
              |> Map.put(:in_flight, in_flight)
              |> Map.put(:waitq, waitq)
              |> Map.put(:slot_request_times, slot_request_times)

            {:error, :dead_worker} ->
              # Worker died while waiting - clean up and try next
              Logger.warning(
                "Scheduler: worker #{inspect(worker_pid)} died while waiting in queue, skipping"
              )

              state = maybe_demonitor_worker(state, entry)
              # Recursively try next in queue
              maybe_grant_next(%{state | waitq: waitq})
          end

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp grant_until_full(state) do
    grant_until_full(state, 0)
  end

  defp grant_until_full(state, depth) when depth > 1000 do
    Logger.warning("grant_until_full exceeded max iterations, deferring remaining grants")
    state
  end

  defp grant_until_full(state, depth) do
    if map_size(state.in_flight) < state.max and not :queue.is_empty(state.waitq) do
      state |> maybe_grant_next() |> grant_until_full(depth + 1)
    else
      state
    end
  end

  defp ensure_monitor(state, pid) do
    case Map.get(state.monitors, pid) do
      nil ->
        mon_ref = Process.monitor(pid)
        monitors = Map.put(state.monitors, pid, mon_ref)
        counts = Map.update(state.worker_counts, pid, 1, &(&1 + 1))
        {%{state | monitors: monitors, worker_counts: counts}, mon_ref}

      mon_ref ->
        counts = Map.update(state.worker_counts, pid, 1, &(&1 + 1))
        {%{state | worker_counts: counts}, mon_ref}
    end
  end

  defp maybe_demonitor_worker(state, nil), do: state

  defp maybe_demonitor_worker(state, %{worker: pid}) do
    case Map.get(state.worker_counts, pid) do
      nil ->
        state

      1 ->
        if mon_ref = Map.get(state.monitors, pid) do
          Process.demonitor(mon_ref, [:flush])
        end

        monitors = Map.delete(state.monitors, pid)
        counts = Map.delete(state.worker_counts, pid)
        %{state | monitors: monitors, worker_counts: counts}

      count ->
        counts = Map.put(state.worker_counts, pid, count - 1)
        %{state | worker_counts: counts}
    end
  end

  defp pop_in_flight(state, slot_ref) do
    case Map.pop(state.in_flight, slot_ref) do
      {nil, in_flight} ->
        {%{state | in_flight: in_flight}, nil}

      {entry, in_flight} ->
        {%{state | in_flight: in_flight}, entry}
    end
  end

  defp cleanup_worker(state, pid) do
    {in_flight, removed_entries} =
      Enum.reduce(state.in_flight, {%{}, []}, fn {slot_ref, entry}, {acc, removed} ->
        if entry.worker == pid do
          {acc, [Map.put(entry, :slot_ref, slot_ref) | removed]}
        else
          {Map.put(acc, slot_ref, entry), removed}
        end
      end)

    {waitq, removed_waitq} = drop_waitq_worker(state.waitq, pid)
    removed_count = length(removed_entries) + removed_waitq

    counts =
      case Map.get(state.worker_counts, pid) do
        nil ->
          state.worker_counts

        count ->
          new_count = count - removed_count

          if new_count > 0 do
            Map.put(state.worker_counts, pid, new_count)
          else
            Map.delete(state.worker_counts, pid)
          end
      end

    monitors = Map.delete(state.monitors, pid)
    slot_request_times = Map.delete(slot_request_times(state), pid)

    state
    |> Map.put(:in_flight, in_flight)
    |> Map.put(:waitq, waitq)
    |> Map.put(:monitors, monitors)
    |> Map.put(:worker_counts, counts)
    |> Map.put(:slot_request_times, slot_request_times)
  end

  defp drop_waitq_worker(queue, pid) do
    list = :queue.to_list(queue)

    {kept, removed} =
      Enum.split_with(list, fn
        %{worker: w} when is_pid(w) -> w != pid
        # Keep malformed entries for separate cleanup
        _ -> true
      end)

    {:queue.from_list(kept), length(removed)}
  end

  defp tokenized_request_outstanding?(state, worker_pid) do
    Enum.any?(state.in_flight, fn {_slot_ref, entry} ->
      entry.worker == worker_pid and is_reference(Map.get(entry, :token))
    end) or
      Enum.any?(:queue.to_list(state.waitq), fn entry ->
        Map.get(entry, :worker) == worker_pid and is_reference(Map.get(entry, :token))
      end)
  end

  defp cancel_tokenized_request(state, worker_pid, token) do
    {in_flight, removed_in_flight} =
      Enum.reduce(state.in_flight, {%{}, []}, fn {slot_ref, entry}, {kept, removed} ->
        if entry.worker == worker_pid and Map.get(entry, :token) == token do
          {kept, [Map.put(entry, :slot_ref, slot_ref) | removed]}
        else
          {Map.put(kept, slot_ref, entry), removed}
        end
      end)

    {kept_waiters, removed_waiters} =
      state.waitq
      |> :queue.to_list()
      |> Enum.split_with(fn entry ->
        not (Map.get(entry, :worker) == worker_pid and Map.get(entry, :token) == token)
      end)

    removed_entries = removed_in_flight ++ removed_waiters

    state =
      Enum.reduce(removed_entries, %{state | in_flight: in_flight}, fn entry, acc ->
        maybe_demonitor_worker(acc, entry)
      end)

    state
    |> Map.put(:waitq, :queue.from_list(kept_waiters))
    |> Map.put(:slot_request_times, Map.delete(slot_request_times(state), worker_pid))
  end

  defp maybe_notify_slot_expired(%{worker: worker, token: token})
       when is_pid(worker) and is_reference(token) do
    send(worker, {:slot_request_expired, token})
  end

  defp maybe_notify_slot_expired(_entry), do: :ok

  defp wait_time_ms(%{queued_at_ms: queued_at_ms})
       when is_integer(queued_at_ms) do
    max(System.monotonic_time(:millisecond) - queued_at_ms, 0)
  end

  defp wait_time_ms(_), do: 0

  defp emit_scheduler_telemetry(event, measurements) do
    LemonCore.Telemetry.emit(
      [:lemon, :gateway, :scheduler, event],
      Map.put(measurements, :count, 1),
      %{}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp slot_request_times(state), do: Map.get(state, :slot_request_times, %{})
end
