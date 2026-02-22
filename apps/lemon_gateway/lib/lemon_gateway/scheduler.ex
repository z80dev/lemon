defmodule LemonGateway.Scheduler do
  @moduledoc """
  Concurrency-limited job scheduler.

  Manages a pool of execution slots (`max_concurrent_runs`) and routes incoming
  jobs to `ThreadWorker` processes keyed by session. Handles auto-resume by
  restoring conversation tokens from stored chat state.
  """
  use GenServer
  require Logger

  alias LemonGateway.{ChatState, Config, Store}
  alias LemonGateway.Types.{Job, ResumeToken}

  # Timeout for slot requests - workers should not wait forever
  @slot_request_timeout_ms 30_000

  # Timeout for worker startup operations
  @worker_startup_timeout_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Submits a job for scheduling. Applies auto-resume and routes to the appropriate thread worker."
  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job) do
    GenServer.cast(__MODULE__, {:submit, job})
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
        n when is_integer(n) and n > 0 -> n
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
  def handle_cast({:submit, job}, state) do
    job = maybe_apply_auto_resume(job)
    thread_key = thread_key(job)

    Logger.debug(
      "Scheduler submit run_id=#{inspect(job.run_id)} session_key=#{inspect(job.session_key)} " <>
        "queue_mode=#{inspect(job.queue_mode)} thread_key=#{inspect(thread_key)}"
    )

    :ok = enqueue_job(thread_key, job)

    {:noreply, state}
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

      {:noreply, state |> Map.put(:waitq, waitq) |> Map.put(:slot_request_times, slot_request_times)}
    end
  end

  def handle_cast({:release_slot, slot_ref}, state) do
    {state, removed} = pop_in_flight(state, slot_ref)
    state = maybe_demonitor_worker(state, removed)

    Logger.debug(
      "Scheduler released slot slot_ref=#{inspect(slot_ref)} in_flight=#{map_size(state.in_flight)}/#{state.max}"
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

  defp schedule_slot_timeout_check do
    Process.send_after(self(), :slot_timeout_check, @slot_request_timeout_ms)
  end

  # Remove slot requests that have been waiting too long
  defp cleanup_stale_slot_requests(state) do
    now = System.monotonic_time(:millisecond)

    {fresh_waitq, stale_count, fresh_request_times} =
      :queue.to_list(state.waitq)
      |> Enum.reduce({:queue.new(), 0, %{}}, fn
        %{queued_at_ms: queued_at, worker: worker} = entry, {q, stale_acc, times_acc}
        when is_integer(queued_at) and is_pid(worker) ->
          if now - queued_at > @slot_request_timeout_ms do
            # Stale request - worker has been waiting too long
            Logger.warning(
              "Scheduler: dropping stale slot request for worker #{inspect(worker)}, " <>
                "queued #{div(now - queued_at, 1000)}s ago"
            )

            # Clean up monitor for this stale request
            maybe_demonitor_worker(state, entry)
            {q, stale_acc + 1, times_acc}
          else
            {:queue.in(entry, q), stale_acc, Map.put(times_acc, worker, queued_at)}
          end

        malformed, {q, stale_acc, times_acc} ->
          Logger.warning("Scheduler: dropping malformed waitq entry: #{inspect(malformed)}")
          {q, stale_acc + 1, times_acc}
      end)

    if stale_count > 0 do
      Logger.warning("Scheduler: cleaned up #{stale_count} stale slot requests")
    end

    state
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
        _ -> true  # Keep malformed entries for separate cleanup
      end)

    {:queue.from_list(kept), length(removed)}
  end

  defp wait_time_ms(%{queued_at_ms: queued_at_ms}) when is_integer(queued_at_ms) and queued_at_ms > 0 do
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

  #
  # IMPORTANT: session_key must win over resume tokens.
  #
  # We want strict single-flight per user session (Telegram DM, Slack thread, etc).
  # If we derive the worker key from a resume token first, commands like /new
  # (which intentionally run without a resume token) can end up on a different
  # ThreadWorker and run concurrently with an in-flight session run.
  #
  # The router has a session-level single-flight guard (LemonRouter.SessionRegistry)
  # to track the best-effort "active run" for a session_key. The gateway is responsible
  # for serializing runs per session_key; the router should not cancel queued runs just
  # because the previous RunProcess is still finalizing output.
  defp thread_key(%Job{session_key: session_key})
       when is_binary(session_key) and session_key != "" do
    {:session, session_key}
  end

  defp thread_key(%Job{resume: %ResumeToken{engine: engine, value: value}}) do
    {engine, value}
  end

  defp thread_key(_), do: {:default, :global}

  defp maybe_apply_auto_resume(%Job{} = job) do
    meta = job.meta || %{}

    if is_map(meta) and
         (meta[:disable_auto_resume] == true or meta["disable_auto_resume"] == true) do
      job
    else
      maybe_apply_auto_resume_inner(job)
    end
  rescue
    _ -> job
  catch
    _, _ -> job
  end

  defp maybe_apply_auto_resume_inner(%Job{resume: %ResumeToken{}} = job), do: job

  defp maybe_apply_auto_resume_inner(%Job{session_key: session_key} = job)
       when is_binary(session_key) do
    if auto_resume_enabled?() do
      case Store.get_chat_state(session_key) do
        %ChatState{last_engine: engine, last_resume_token: token}
        when is_binary(engine) and is_binary(token) ->
          apply_resume_if_compatible(job, engine, token)

        %{} = map ->
          engine = map_get(map, :last_engine)
          token = map_get(map, :last_resume_token)

          if is_binary(engine) and is_binary(token) do
            apply_resume_if_compatible(job, engine, token)
          else
            job
          end

        _ ->
          job
      end
    else
      job
    end
  catch
    :exit, _ -> job
    :error, _ -> job
  end

  defp maybe_apply_auto_resume_inner(job), do: job

  defp auto_resume_enabled? do
    if is_pid(Process.whereis(Config)) do
      Config.get(:auto_resume) == true
    else
      false
    end
  catch
    :exit, _ -> false
    :error, _ -> false
  end

  defp apply_resume_if_compatible(%Job{} = job, engine, token) do
    # Only apply auto-resume if engine matches (or no engine selected yet).
    if is_nil(job.engine_id) or job.engine_id == engine do
      resume = %ResumeToken{engine: engine, value: token}
      %{job | resume: resume, engine_id: job.engine_id || engine}
    else
      job
    end
  end

  defp enqueue_job(thread_key, job) do
    case ensure_worker(thread_key) do
      {:ok, worker_pid} ->
        case safe_enqueue_async(worker_pid, job) do
          :ok ->
            :ok

          {:error, :noproc} ->
            # First attempt failed, try to create a new worker
            Logger.warning(
              "Scheduler: worker #{inspect(worker_pid)} died during first enqueue attempt, retrying"
            )

            case ensure_worker(thread_key) do
              {:ok, worker_pid2} ->
                case safe_enqueue_async(worker_pid2, job) do
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
        Logger.error(
          "Scheduler: timeout starting worker for thread_key=#{inspect(thread_key)}"
        )

        {:error, :worker_startup_timeout}

      {:exit, reason} ->
        Logger.error(
          "Scheduler: worker startup task exited for thread_key=#{inspect(thread_key)}, reason=#{inspect(reason)}"
        )

        {:error, {:worker_startup_exit, reason}}
    end
  end

  defp safe_enqueue_async(pid, job) when is_pid(pid) do
    try do
      if Process.alive?(pid) do
        GenServer.cast(pid, {:enqueue, job})
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

  # Helper for consistent atom/string key access
  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
