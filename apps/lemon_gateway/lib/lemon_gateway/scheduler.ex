defmodule LemonGateway.Scheduler do
  @moduledoc """
  Concurrency-limited execution scheduler.

  Manages a pool of execution slots (`max_concurrent_runs`) and routes incoming
  execution requests to `ThreadWorker` processes keyed by conversation.
  """
  use GenServer
  require Logger

  alias LemonCore.Introspection
  alias LemonGateway.ExecutionRequest

  # Timeout for slot requests - workers should not wait forever
  @slot_request_timeout_ms 30_000

  # Timeout for worker startup operations
  @worker_startup_timeout_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Submits an execution request for scheduling."
  @spec submit_execution(ExecutionRequest.t()) :: :ok
  def submit_execution(%ExecutionRequest{} = request) do
    request = ExecutionRequest.ensure_conversation_key(request)
    GenServer.cast(__MODULE__, {:submit_execution, request})
  end

  @doc "Requests an execution slot for the given worker. Grants immediately or queues the request."
  @spec request_slot(pid(), term()) :: :ok
  def request_slot(worker_pid, thread_key) do
    GenServer.cast(__MODULE__, {:request_slot, worker_pid, thread_key})
  end

  @doc "Releases an execution slot, allowing the next queued worker to proceed."
  @spec release_slot(reference()) :: :ok
  def release_slot(slot_ref) do
    GenServer.cast(__MODULE__, {:release_slot, slot_ref})
  end

  @doc "Cancels a running job by sending a cancel cast to the run process."
  @spec cancel(pid(), term()) :: :ok
  def cancel(run_pid, reason \\ :user_requested) do
    if is_pid(run_pid) do
      try do
        if Process.alive?(run_pid) do
          GenServer.cast(run_pid, {:cancel, reason})
        end
      catch
        :exit, {:noproc, _} ->
          Logger.debug("Scheduler.cancel: run_pid #{inspect(run_pid)} already dead")
          :ok
      end
    end

    :ok
  end

  @impl true
  def init(_opts) do
    max =
      case LemonGateway.Config.get(:max_concurrent_runs) do
        n when is_integer(n) and n > 0 ->
          n

        _ ->
          Logger.warning("Invalid max_concurrent_runs config, using default 10")
          10
      end

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

  @impl true
  def handle_cast({:submit_execution, %ExecutionRequest{} = request}, state) do
    {:noreply, schedule_submission(request, state)}
  end

  def handle_cast({:request_slot, worker_pid, thread_key}, state) do
    if map_size(state.in_flight) < state.max do
      slot_ref = make_ref()
      {state, mon_ref} = ensure_monitor(state, worker_pid)

      in_flight =
        Map.put(state.in_flight, slot_ref, %{
          worker: worker_pid,
          thread_key: thread_key,
          mon_ref: mon_ref,
          granted_at_ms: System.monotonic_time(:millisecond)
        })

      # Safely send slot grant with error handling
      case safe_send_slot_granted(worker_pid, slot_ref) do
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
          # Worker died before we could send - clean up and try next
          Logger.warning(
            "Scheduler: worker #{inspect(worker_pid)} died before slot could be granted, skipping"
          )

          state = maybe_demonitor_worker(state, %{worker: worker_pid, mon_ref: mon_ref})
          {:noreply, grant_until_full(state)}
      end
    else
      {state, mon_ref} = ensure_monitor(state, worker_pid)
      queued_at_ms = System.monotonic_time(:millisecond)

      waitq =
        :queue.in(
          %{
            worker: worker_pid,
            thread_key: thread_key,
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

  def handle_cast({:release_slot, slot_ref}, state) do
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

  @impl true
  def handle_info({:DOWN, mon_ref, :process, pid, reason}, state) do
    Logger.debug("Scheduler: worker #{inspect(pid)} down with reason #{inspect(reason)}")

    state =
      case Map.get(state.monitors, pid) do
        ^mon_ref -> cleanup_worker(state, pid)
        _ -> state
      end

    {:noreply, grant_until_full(state)}
  end

  # Handle slot request timeout check
  def handle_info(:slot_timeout_check, state) do
    state = cleanup_stale_slot_requests(state)
    schedule_slot_timeout_check()
    {:noreply, state}
  end

  # Catch-all for unknown messages to prevent crashes
  def handle_info(msg, state) do
    Logger.warning("Scheduler received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp schedule_submission(%ExecutionRequest{} = request, state) do
    thread_key = thread_key(request)

    Logger.debug(
      "Scheduler submit run_id=#{inspect(request.run_id)} session_key=#{inspect(request.session_key)} " <>
        "thread_key=#{inspect(thread_key)}"
    )

    Introspection.record(
      :scheduled_job_triggered,
      %{
        engine_id: request.engine_id,
        thread_key: inspect(thread_key)
      },
      run_id: request.run_id,
      session_key: request.session_key,
      engine: "lemon",
      provenance: :direct
    )

    :ok = enqueue_request(thread_key, request)
    state
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
  defp safe_send_slot_granted(worker_pid, slot_ref) do
    try do
      if Process.alive?(worker_pid) do
        send(worker_pid, {:slot_granted, slot_ref})
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
          case safe_send_slot_granted(worker_pid, slot_ref) do
            :ok ->
              in_flight =
                Map.put(state.in_flight, slot_ref, %{
                  worker: worker_pid,
                  thread_key: thread_key,
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

  defp wait_time_ms(%{queued_at_ms: queued_at_ms})
       when is_integer(queued_at_ms) and queued_at_ms > 0 do
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

  defp thread_key(%ExecutionRequest{conversation_key: conversation_key})
       when not is_nil(conversation_key),
       do: conversation_key

  defp thread_key(%ExecutionRequest{run_id: run_id}) do
    raise ArgumentError,
          "execution request #{inspect(run_id)} is missing router-owned conversation_key"
  end

  defp enqueue_request(thread_key, request) do
    case ensure_worker(thread_key) do
      {:ok, worker_pid} ->
        case safe_enqueue_async(worker_pid, request) do
          :ok ->
            :ok

          {:error, :noproc} ->
            # First attempt failed, try to create a new worker
            Logger.warning(
              "Scheduler: worker #{inspect(worker_pid)} died during first enqueue attempt, retrying"
            )

            case ensure_worker(thread_key) do
              {:ok, worker_pid2} ->
                case safe_enqueue_async(worker_pid2, request) do
                  :ok ->
                    :ok

                  {:error, reason} = err ->
                    Logger.error(
                      "Scheduler: second enqueue attempt failed for thread_key=#{inspect(thread_key)}, reason=#{inspect(reason)}"
                    )

                    normalize_enqueue(err)
                end

              {:error, reason} = err ->
                Logger.error(
                  "Scheduler: failed to recreate worker for thread_key=#{inspect(thread_key)}, reason=#{inspect(reason)}"
                )

                normalize_enqueue(err)
            end

          {:error, reason} = err ->
            Logger.error(
              "Scheduler: enqueue failed for thread_key=#{inspect(thread_key)}, reason=#{inspect(reason)}"
            )

            normalize_enqueue(err)
        end

      {:error, reason} = err ->
        Logger.error(
          "Scheduler: failed to ensure worker for thread_key=#{inspect(thread_key)}, reason=#{inspect(reason)}"
        )

        normalize_enqueue(err)
    end
  end

  defp ensure_worker(thread_key) do
    case LemonGateway.ThreadRegistry.whereis(thread_key) do
      nil ->
        start_worker_with_timeout(thread_key)

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # Stale registry entry, start fresh
          Logger.warning(
            "Scheduler: found dead worker in registry for thread_key=#{inspect(thread_key)}, starting fresh"
          )

          start_worker_with_timeout(thread_key)
        end
    end
  end

  defp start_worker_with_timeout(thread_key) do
    # Use a task with timeout to avoid hanging on DynamicSupervisor
    task =
      Task.async(fn ->
        DynamicSupervisor.start_child(
          LemonGateway.ThreadWorkerSupervisor,
          {LemonGateway.ThreadWorker, thread_key: thread_key}
        )
      end)

    case Task.yield(task, @worker_startup_timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, pid}} ->
        {:ok, pid}

      {:ok, {:error, {:already_started, pid}}} ->
        {:ok, pid}

      {:ok, {:error, _} = err} ->
        err

      nil ->
        Logger.error("Scheduler: timeout starting worker for thread_key=#{inspect(thread_key)}")

        {:error, :worker_startup_timeout}

      {:exit, reason} ->
        Logger.error(
          "Scheduler: worker startup task exited for thread_key=#{inspect(thread_key)}, reason=#{inspect(reason)}"
        )

        {:error, {:worker_startup_exit, reason}}
    end
  end

  defp safe_enqueue_async(pid, request) when is_pid(pid) do
    try do
      if Process.alive?(pid) do
        GenServer.cast(pid, {:enqueue, request})
        :ok
      else
        {:error, :noproc}
      end
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp normalize_enqueue(_result), do: :ok

  defp slot_request_times(state), do: Map.get(state, :slot_request_times, %{})
end
