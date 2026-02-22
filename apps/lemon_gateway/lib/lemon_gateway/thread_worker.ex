defmodule LemonGateway.ThreadWorker do
  @moduledoc """
  Per-session job queue worker.

  Each `ThreadWorker` manages a queue of jobs for a single session key.
  It supports multiple queue modes:

  - `:collect` - appends to queue, coalesces consecutive collect jobs
  - `:followup` - appends with debounce merging of rapid-fire messages
  - `:steer` - attempts to inject text into an active run via engine steering
  - `:steer_backlog` - like steer, but falls back to collect on rejection
  - `:interrupt` - cancels the current run and inserts at front of queue

  Workers are started on-demand by the `Scheduler` and terminate when their
  queue is empty and no run is active.
  """
  use GenServer

  require Logger

  alias LemonGateway.Types.Job

  # Default window for merging consecutive followup jobs (milliseconds)
  @followup_debounce_ms 500

  # Timeout for slot requests - if scheduler doesn't respond, we retry
  @slot_request_timeout_ms 30_000

  # Maximum attempts to start a run
  @max_run_start_attempts 3

  def start_link(opts) do
    thread_key = Keyword.fetch!(opts, :thread_key)
    name = {:via, Registry, {LemonGateway.ThreadRegistry, thread_key}}
    GenServer.start_link(__MODULE__, %{thread_key: thread_key}, name: name)
  end

  @impl true
  def init(state) do
    # Schedule slot request timeout check
    schedule_slot_timeout_check()

    {:ok,
     Map.merge(state, %{
       jobs: :queue.new(),
       current_run: nil,
       current_slot_ref: nil,
       run_mon_ref: nil,
       slot_pending: false,
       slot_requested_at: nil,
       last_followup_at: nil,
       # Track pending steer jobs sent to the run but not yet confirmed/rejected
       # Maps run_pid -> list of {job, fallback_mode} tuples
       pending_steers: %{}
     })}
  end

  @impl true
  def handle_cast({:enqueue, %Job{} = job}, state) do
    Logger.debug(
      "ThreadWorker enqueue(cast) thread_key=#{inspect(state.thread_key)} run_id=#{inspect(job.run_id)} " <>
        "mode=#{inspect(job.queue_mode)} queue_len_before=#{queue_len_safe(state.jobs)}"
    )

    job = maybe_promote_auto_followup(job, state)
    state = enqueue_by_mode(job, state)
    {:noreply, maybe_request_slot(state)}
  end

  @impl true
  def handle_call({:enqueue, %Job{} = job}, _from, state) do
    Logger.debug(
      "ThreadWorker enqueue(call) thread_key=#{inspect(state.thread_key)} run_id=#{inspect(job.run_id)} " <>
        "mode=#{inspect(job.queue_mode)} queue_len_before=#{queue_len_safe(state.jobs)}"
    )

    job = maybe_promote_auto_followup(job, state)
    state = enqueue_by_mode(job, state)
    {:reply, :ok, maybe_request_slot(state)}
  end

  @impl true
  def handle_info({:slot_granted, slot_ref}, state) do
    cond do
      state.current_run != nil ->
        # Already have a run, release the slot
        safe_release_slot(slot_ref)
        {:noreply, %{state | slot_pending: false, slot_requested_at: nil}}

      :queue.is_empty(state.jobs) ->
        # No jobs to run, release slot and stop
        safe_release_slot(slot_ref)
        {:stop, :normal, %{state | slot_pending: false, slot_requested_at: nil}}

      true ->
        case :queue.out(state.jobs) do
          {{:value, job}, jobs} ->
            Logger.debug(
              "ThreadWorker slot granted thread_key=#{inspect(state.thread_key)} " <>
                "run_id=#{inspect(job.run_id)} remaining_queue=#{queue_len_safe(jobs)}"
            )

            # Start the run with error handling
            case start_run_safe(job, slot_ref, state.thread_key) do
              {:ok, run_pid} ->
                mon_ref = Process.monitor(run_pid)

                {:noreply,
                 %{
                   state
                   | jobs: jobs,
                     current_run: run_pid,
                     current_slot_ref: slot_ref,
                     run_mon_ref: mon_ref,
                     slot_pending: false,
                     slot_requested_at: nil
                 }}

              {:error, reason} ->
                Logger.error(
                  "ThreadWorker: failed to start run for job #{inspect(job.run_id)}, " <>
                    "reason=#{inspect(reason)}"
                )

                # Release the slot since we couldn't start the run
                safe_release_slot(slot_ref)

                # Re-enqueue the job for retry (at front of queue)
                state = %{state | jobs: :queue.in_r(job, state.jobs)}

                # Clear slot pending and try again
                state = %{state | slot_pending: false, slot_requested_at: nil}
                {:noreply, maybe_request_slot(state)}
            end

          {:empty, _} ->
            # Queue became empty between check and pop
            safe_release_slot(slot_ref)
            {:stop, :normal, %{state | slot_pending: false, slot_requested_at: nil}}
        end
    end
  end

  def handle_info({:run_complete, run_pid, _completed_event}, state) do
    state =
      if run_pid == state.current_run do
        if is_reference(state.run_mon_ref) do
          Process.demonitor(state.run_mon_ref, [:flush])
        end

        Logger.debug(
          "ThreadWorker run complete thread_key=#{inspect(state.thread_key)} run_pid=#{inspect(run_pid)} " <>
            "queue_len=#{queue_len_safe(state.jobs)}"
        )

        %{state | current_run: nil, current_slot_ref: nil, run_mon_ref: nil, jobs: state.jobs}
      else
        state
      end

    state = maybe_request_slot(state)

    if state.current_run == nil and :queue.is_empty(state.jobs) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, pid, reason}, state) do
    if state.current_run == pid and state.run_mon_ref == mon_ref do
      if state.current_slot_ref do
        safe_release_slot(state.current_slot_ref)
      end

      Logger.warning(
        "ThreadWorker observed run down thread_key=#{inspect(state.thread_key)} run_pid=#{inspect(pid)} " <>
          "reason=#{inspect(reason)} pending_steers=#{length(Map.get(state.pending_steers, pid, []))}"
      )

      # Flush any pending steers for this run - they were cast but never processed
      state = flush_pending_steers(state, pid)

      state =
        %{state | current_run: nil, current_slot_ref: nil, run_mon_ref: nil}
        |> maybe_request_slot()

      if state.current_run == nil and :queue.is_empty(state.jobs) do
        {:stop, :normal, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Handle slot request timeout check
  def handle_info(:slot_timeout_check, state) do
    state =
      if state.slot_pending and state.slot_requested_at != nil do
        elapsed = System.monotonic_time(:millisecond) - state.slot_requested_at

        if elapsed > @slot_request_timeout_ms do
          Logger.warning(
            "ThreadWorker: slot request timed out after #{div(elapsed, 1000)}s, retrying"
          )

          # Reset slot_pending and try again
          state = %{state | slot_pending: false, slot_requested_at: nil}
          maybe_request_slot(state)
        else
          state
        end
      else
        state
      end

    schedule_slot_timeout_check()
    {:noreply, state}
  end

  # Handle steer acceptance from Run - remove from pending steers
  def handle_info({:steer_accepted, %Job{} = job}, state) do
    state = remove_pending_steer(state, job)
    {:noreply, state}
  end

  # Handle steer_backlog acceptance from Run - remove from pending steers
  def handle_info({:steer_backlog_accepted, %Job{} = job}, state) do
    state = remove_pending_steer(state, job)
    {:noreply, state}
  end

  # Handle steer rejection from Run - re-enqueue as followup
  def handle_info({:steer_rejected, %Job{} = job}, state) do
    # Remove from pending steers since the run explicitly rejected it
    state = remove_pending_steer(state, job)
    followup_job = %{job | queue_mode: :followup}
    state = enqueue_by_mode(followup_job, state)
    {:noreply, maybe_request_slot(state)}
  end

  # Handle steer_backlog rejection from Run - enqueue at back like :collect
  def handle_info({:steer_backlog_rejected, %Job{} = job}, state) do
    # Remove from pending steers since the run explicitly rejected it
    state = remove_pending_steer(state, job)
    collect_job = %{job | queue_mode: :collect}
    state = apply_queue_cap(%{state | jobs: :queue.in(collect_job, state.jobs)}, collect_job)
    {:noreply, maybe_request_slot(state)}
  end

  # Catch-all for unknown messages to prevent crashes
  def handle_info(msg, state) do
    Logger.warning("ThreadWorker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # When an async task/agent auto-followup arrives with queue_mode: :followup,
  # promote it to :steer_backlog if there's an active run. This allows the result
  # to be injected into the current LLM run (e.g., if the user's follow-up message
  # is being processed) instead of queuing as a separate run that would block
  # subsequent user messages.
  defp maybe_promote_auto_followup(
         %Job{queue_mode: :followup, meta: meta} = job,
         %{current_run: pid}
       )
       when is_pid(pid) and is_map(meta) do
    is_auto = Map.get(meta, :task_auto_followup, false) or
              Map.get(meta, :delegated_auto_followup, false)

    if is_auto do
      Logger.info(
        "ThreadWorker: promoting auto-followup to steer_backlog (active run exists) " <>
          "thread_key=#{inspect(job.session_key)}"
      )

      %{job | queue_mode: :steer_backlog}
    else
      job
    end
  end

  defp maybe_promote_auto_followup(job, _state), do: job

  # Insert job into queue based on queue_mode
  defp enqueue_by_mode(%Job{queue_mode: :collect} = job, state) do
    apply_queue_cap(%{state | jobs: :queue.in(job, state.jobs)}, job)
  end

  defp enqueue_by_mode(%Job{queue_mode: :followup} = job, state) do
    now = System.monotonic_time(:millisecond)
    debounce_ms = followup_debounce_ms()

    new_state =
      case state.last_followup_at do
        nil ->
          # No previous followup, just append
          %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}

        last_time when now - last_time < debounce_ms ->
          # Within debounce window, merge with last followup if possible
          case merge_with_last_followup(state.jobs, job) do
            {:merged, new_jobs} ->
              # Merging doesn't increase queue size, no cap check needed
              %{state | jobs: new_jobs, last_followup_at: now}

            :no_merge ->
              %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}
          end

        _last_time ->
          # Outside debounce window, just append
          %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}
      end

    # Apply cap after adding (unless it was a merge which doesn't increase size)
    apply_queue_cap(new_state, job)
  end

  defp enqueue_by_mode(%Job{queue_mode: :steer} = job, state) do
    # If there's an active run, attempt to steer it directly
    case state.current_run do
      pid when is_pid(pid) ->
        # Safely cast to the run - handle case where run dies
        case safe_cast_steer(pid, :steer, job) do
          :ok ->
            # Track this pending steer so we can recover it if the run dies
            add_pending_steer(state, pid, job, :followup)

          {:error, reason} ->
            Logger.warning(
              "ThreadWorker: steer cast failed for run #{inspect(pid)}, reason=#{inspect(reason)}, " <>
                "converting to followup"
            )

            # Run is dead or dying - convert to followup
            followup_job = %{job | queue_mode: :followup}
            enqueue_by_mode(followup_job, state)
        end

      nil ->
        # No active run - convert to followup and enqueue
        followup_job = %{job | queue_mode: :followup}
        enqueue_by_mode(followup_job, state)
    end
  end

  defp enqueue_by_mode(%Job{queue_mode: :steer_backlog} = job, state) do
    # Like :steer, but falls back to enqueuing at back (like :collect) instead of converting to followup
    case state.current_run do
      pid when is_pid(pid) ->
        # Safely cast to the run - handle case where run dies
        case safe_cast_steer(pid, :steer_backlog, job) do
          :ok ->
            # Track this pending steer so we can recover it if the run dies
            add_pending_steer(state, pid, job, :collect)

          {:error, reason} ->
            Logger.warning(
              "ThreadWorker: steer_backlog cast failed for run #{inspect(pid)}, reason=#{inspect(reason)}, " <>
                "converting to collect"
            )

            # Run is dead or dying - convert to collect
            collect_job = %{job | queue_mode: :collect}
            apply_queue_cap(%{state | jobs: :queue.in(collect_job, state.jobs)}, collect_job)
        end

      nil ->
        # No active run - enqueue at back like :collect
        collect_job = %{job | queue_mode: :collect}
        apply_queue_cap(%{state | jobs: :queue.in(collect_job, state.jobs)}, collect_job)
    end
  end

  defp enqueue_by_mode(%Job{queue_mode: :interrupt} = job, state) do
    # Cancel current run if active, then insert at front
    state = maybe_cancel_current_run(state)
    new_state = %{state | jobs: :queue.in_r(job, state.jobs)}
    # Apply cap after insertion (will drop from back if needed)
    apply_queue_cap(new_state, job)
  end

  # Safely cast a steer message to a run process
  defp safe_cast_steer(pid, steer_type, job) when is_pid(pid) do
    try do
      if Process.alive?(pid) do
        case steer_type do
          :steer -> GenServer.cast(pid, {:steer, job, self()})
          :steer_backlog -> GenServer.cast(pid, {:steer_backlog, job, self()})
        end

        :ok
      else
        {:error, :dead_run}
      end
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # Apply queue cap and drop policy
  # Returns the state with jobs trimmed to cap if configured
  defp apply_queue_cap(state, job_added) do
    queue_config = LemonGateway.Config.get_queue_config()
    cap = queue_config[:cap]
    drop = queue_config[:drop]
    queue_len = queue_len_safe(state.jobs)

    cond do
      # No cap configured or cap is 0 - no enforcement
      is_nil(cap) or cap <= 0 ->
        state

      # Queue is within cap - no action needed
      queue_len <= cap ->
        state

      # Drop policy is :newest - remove the job we just added
      drop == :newest ->
        Logger.debug("Queue cap reached (#{cap}), dropping newest job")
        # The job was just added, so we need to remove it
        # For :collect/:followup it's at the back, for :interrupt it's at the front
        case job_added.queue_mode do
          :interrupt ->
            # Job was added at front, remove from front
            case :queue.out(state.jobs) do
              {{:value, _dropped}, trimmed_jobs} ->
                %{state | jobs: trimmed_jobs}

              {:empty, _} ->
                # Queue became empty between check and removal
                state
            end

          _ ->
            # Job was added at back, remove from back
            case :queue.out_r(state.jobs) do
              {{:value, _dropped}, trimmed_jobs} ->
                %{state | jobs: trimmed_jobs}

              {:empty, _} ->
                # Queue became empty between check and removal
                state
            end
        end

      # Drop policy is :oldest (default) - remove oldest jobs until at cap
      true ->
        drop_oldest_until_cap(state, cap)
    end
  end

  # Drop oldest jobs until queue is at or below cap
  defp drop_oldest_until_cap(state, cap) do
    queue_len = queue_len_safe(state.jobs)

    if queue_len <= cap do
      state
    else
      to_drop = queue_len - cap
      Logger.debug("Queue cap reached (#{cap}), dropping #{to_drop} oldest job(s)")
      trimmed_jobs = drop_n_oldest(state.jobs, to_drop)
      %{state | jobs: trimmed_jobs}
    end
  end

  # Drop n oldest jobs from the queue
  defp drop_n_oldest(queue, 0), do: queue

  defp drop_n_oldest(queue, n) when n > 0 do
    case :queue.out(queue) do
      {{:value, _dropped}, rest} ->
        drop_n_oldest(rest, n - 1)

      {:empty, _} ->
        queue
    end
  end

  # Try to merge a followup job with the last followup job in the queue
  defp merge_with_last_followup(queue, new_job) do
    case :queue.out_r(queue) do
      {{:value, %Job{queue_mode: :followup} = last_job}, rest_queue} ->
        merged_job = %{
          last_job
          | prompt: merge_prompt(last_job.prompt, new_job.prompt),
            meta: merge_user_message_meta(last_job.meta, new_job.meta)
        }

        {:merged, :queue.in(merged_job, rest_queue)}

      _ ->
        :no_merge
    end
  end

  # Cancel the currently running job if there is one
  defp maybe_cancel_current_run(%{current_run: nil} = state), do: state

  defp maybe_cancel_current_run(%{current_run: run_pid} = state) when is_pid(run_pid) do
    try do
      LemonGateway.Scheduler.cancel(run_pid, :interrupted)
    catch
      :exit, {:noproc, _} ->
        Logger.debug("ThreadWorker: scheduler cancel failed - scheduler not available")
        :ok

      :exit, reason ->
        Logger.warning("ThreadWorker: scheduler cancel exited with reason #{inspect(reason)}")
        :ok

      :error, reason ->
        Logger.error("ThreadWorker: scheduler cancel raised error: #{inspect(reason)}")
        :ok
    end

    state
  end

  defp followup_debounce_ms do
    Application.get_env(:lemon_gateway, :followup_debounce_ms, @followup_debounce_ms)
  end

  # Add a job to the pending steers for a given run pid
  defp add_pending_steer(state, run_pid, job, fallback_mode) do
    pending = Map.get(state.pending_steers, run_pid, [])

    %{
      state
      | pending_steers: Map.put(state.pending_steers, run_pid, [{job, fallback_mode} | pending])
    }
  end

  # Remove a specific job from pending steers (called when steer is rejected normally)
  defp remove_pending_steer(state, job) do
    # Use run_id for matching instead of full struct comparison for reliability
    new_pending =
      Map.new(state.pending_steers, fn {pid, jobs} ->
        {pid, Enum.reject(jobs, fn {j, _mode} -> j.run_id == job.run_id end)}
      end)
      |> Map.filter(fn {_pid, jobs} -> jobs != [] end)  # Remove empty lists

    %{state | pending_steers: new_pending}
  end

  # Convert all pending steers for a given run to their fallback modes and enqueue them
  defp flush_pending_steers(state, run_pid) do
    pending = Map.get(state.pending_steers, run_pid, [])
    new_pending_steers = Map.delete(state.pending_steers, run_pid)

    # Convert each pending steer to its fallback mode and enqueue
    Enum.reduce(pending, %{state | pending_steers: new_pending_steers}, fn {job, fallback_mode},
                                                                           acc_state ->
      fallback_job = %{job | queue_mode: fallback_mode}
      enqueue_by_mode(fallback_job, acc_state)
    end)
  end

  # Safely release a slot with error handling
  defp safe_release_slot(slot_ref) do
    try do
      LemonGateway.Scheduler.release_slot(slot_ref)
    catch
      :exit, {:noproc, _} ->
        Logger.debug("ThreadWorker: scheduler not available for slot release")
        :ok

      :exit, reason ->
        Logger.warning("ThreadWorker: scheduler release_slot exited: #{inspect(reason)}")
        :ok
    end
  end

  # Safely start a run with error handling and retries
  defp start_run_safe(job, slot_ref, thread_key, attempt \\ 1) do
    try do
      case LemonGateway.RunSupervisor.start_run(%{
             job: job,
             slot_ref: slot_ref,
             thread_key: thread_key,
             worker_pid: self()
           }) do
        {:ok, run_pid} ->
          {:ok, run_pid}

        {:error, reason} = err ->
          if attempt < @max_run_start_attempts do
            Logger.warning(
              "ThreadWorker: run start attempt #{attempt} failed, retrying: #{inspect(reason)}"
            )

            Process.sleep(100 * attempt)
            start_run_safe(job, slot_ref, thread_key, attempt + 1)
          else
            err
          end
      end
    catch
      :exit, {:noproc, _} ->
        if attempt < @max_run_start_attempts do
          Logger.warning("ThreadWorker: RunSupervisor not available, retrying (#{attempt})")
          Process.sleep(100 * attempt)
          start_run_safe(job, slot_ref, thread_key, attempt + 1)
        else
          {:error, :run_supervisor_unavailable}
        end

      :exit, reason ->
        {:error, {:run_start_exit, reason}}

      error ->
        {:error, {:run_start_exception, error}}
    end
  end

  defp schedule_slot_timeout_check do
    Process.send_after(self(), :slot_timeout_check, 5_000)
  end

  defp maybe_request_slot(state) do
    if state.current_run == nil and not state.slot_pending and not :queue.is_empty(state.jobs) do
      Logger.debug(
        "ThreadWorker requesting slot thread_key=#{inspect(state.thread_key)} queue_len=#{queue_len_safe(state.jobs)}"
      )

      try do
        LemonGateway.Scheduler.request_slot(self(), state.thread_key)
        %{state | slot_pending: true, slot_requested_at: System.monotonic_time(:millisecond)}
      catch
        :exit, {:noproc, _} ->
          Logger.error("ThreadWorker: scheduler not available for slot request")
          # Will retry on next slot timeout check
          %{state | slot_pending: false, slot_requested_at: nil}

        :exit, reason ->
          Logger.error("ThreadWorker: scheduler request_slot exited: #{inspect(reason)}")
          %{state | slot_pending: false, slot_requested_at: nil}
      end
    else
      state
    end
  end

  # Safe queue length check that handles edge cases
  defp queue_len_safe(queue) do
    try do
      :queue.len(queue)
    rescue
      _ -> 0
    end
  end

  @doc """
  Coalesces consecutive :collect jobs at the front of the queue into a single job.

  Merges prompts with newline separators and keeps the latest user message metadata.
  """
  def coalesce_collect_jobs(queue) do
    case :queue.out(queue) do
      {:empty, _} ->
        queue

      {{:value, %Job{queue_mode: :collect} = first_job}, rest} ->
        # Extract all consecutive :collect jobs from the front
        {collect_jobs, remaining} = extract_collect_jobs(rest, [first_job])

        case collect_jobs do
          [single_job] ->
            # Only one :collect job, no merging needed
            :queue.in_r(single_job, remaining)

          [_ | _] ->
            # Multiple :collect jobs to merge
            merged_job = merge_collect_jobs(collect_jobs)
            :queue.in_r(merged_job, remaining)
        end

      {{:value, _non_collect_job}, _rest} ->
        # First job is not :collect, return queue unchanged
        queue
    end
  end

  # Extract consecutive :collect jobs from the front of the queue
  defp extract_collect_jobs(queue, acc) do
    case :queue.out(queue) do
      {{:value, %Job{queue_mode: :collect} = job}, rest} ->
        extract_collect_jobs(rest, [job | acc])

      _ ->
        # No more :collect jobs or queue is empty
        {Enum.reverse(acc), queue}
    end
  end

  # Merge multiple :collect jobs into one
  # Keeps base job identity, concatenates prompt text, and carries latest user message metadata.
  defp merge_collect_jobs([first | _] = jobs) do
    last = List.last(jobs)
    merged_prompt = jobs |> Enum.map(&(&1.prompt || "")) |> Enum.join("\n")

    %{
      first
      | prompt: merged_prompt,
        meta: merge_user_message_meta(first.meta, last.meta)
    }
  end

  defp merge_prompt(nil, right), do: right || ""
  defp merge_prompt(left, nil), do: left
  defp merge_prompt(left, right), do: left <> "\n" <> right

  defp merge_user_message_meta(left, right) when is_map(left) and is_map(right) do
    right_user_msg_id = Map.get(right, :user_msg_id) || Map.get(right, "user_msg_id")

    if is_nil(right_user_msg_id) do
      Map.merge(left, right)
    else
      left
      |> Map.merge(right)
      |> Map.put(:user_msg_id, right_user_msg_id)
      |> Map.delete("user_msg_id")
    end
  end

  defp merge_user_message_meta(left, _right) when is_map(left), do: left
  defp merge_user_message_meta(_left, right) when is_map(right), do: right
  defp merge_user_message_meta(_left, _right), do: %{}
end
