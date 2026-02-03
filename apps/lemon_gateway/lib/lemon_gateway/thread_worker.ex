defmodule LemonGateway.ThreadWorker do
  @moduledoc false
  use GenServer

  alias LemonGateway.Types.Job

  # Default window for merging consecutive followup jobs (milliseconds)
  @followup_debounce_ms 500

  def start_link(opts) do
    thread_key = Keyword.fetch!(opts, :thread_key)
    name = {:via, Registry, {LemonGateway.ThreadRegistry, thread_key}}
    GenServer.start_link(__MODULE__, %{thread_key: thread_key}, name: name)
  end

  @impl true
  def init(state) do
    {:ok,
     Map.merge(state, %{
       jobs: :queue.new(),
       current_run: nil,
       current_slot_ref: nil,
       run_mon_ref: nil,
       slot_pending: false,
       last_followup_at: nil
     })}
  end

  @impl true
  def handle_cast({:enqueue, %Job{} = job}, state) do
    state = enqueue_by_mode(job, state)
    {:noreply, maybe_request_slot(state)}
  end

  @impl true
  def handle_call({:enqueue, %Job{} = job}, _from, state) do
    state = enqueue_by_mode(job, state)
    {:reply, :ok, maybe_request_slot(state)}
  end

  # Insert job into queue based on queue_mode
  defp enqueue_by_mode(%Job{queue_mode: :collect} = job, state) do
    %{state | jobs: :queue.in(job, state.jobs)}
  end

  defp enqueue_by_mode(%Job{queue_mode: :followup} = job, state) do
    now = System.monotonic_time(:millisecond)
    debounce_ms = followup_debounce_ms()

    case state.last_followup_at do
      nil ->
        # No previous followup, just append
        %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}

      last_time when now - last_time < debounce_ms ->
        # Within debounce window, merge with last followup if possible
        case merge_with_last_followup(state.jobs, job) do
          {:merged, new_jobs} ->
            %{state | jobs: new_jobs, last_followup_at: now}

          :no_merge ->
            %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}
        end

      _last_time ->
        # Outside debounce window, just append
        %{state | jobs: :queue.in(job, state.jobs), last_followup_at: now}
    end
  end

  defp enqueue_by_mode(%Job{queue_mode: :steer} = job, state) do
    # If there's an active run, attempt to steer it directly
    case state.current_run do
      pid when is_pid(pid) ->
        # Check if the run process is still alive before casting
        # This prevents losing steers if the run dies before we receive :DOWN
        if Process.alive?(pid) do
          # Ask the run to handle the steer; it will check engine support
          GenServer.cast(pid, {:steer, job, self()})
          # Return state unchanged - the run will notify us if steering fails
          state
        else
          # Run died but we haven't received :DOWN yet - convert to followup
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
        if Process.alive?(pid) do
          # Ask the run to handle the steer; it will check engine support
          # On rejection, we'll handle it as :collect in :steer_backlog_rejected
          GenServer.cast(pid, {:steer_backlog, job, self()})
          state
        else
          # Run died but we haven't received :DOWN yet - enqueue at back like :collect
          collect_job = %{job | queue_mode: :collect}
          %{state | jobs: :queue.in(collect_job, state.jobs)}
        end

      nil ->
        # No active run - enqueue at back like :collect
        collect_job = %{job | queue_mode: :collect}
        %{state | jobs: :queue.in(collect_job, state.jobs)}
    end
  end

  defp enqueue_by_mode(%Job{queue_mode: :interrupt} = job, state) do
    # Cancel current run if active, then insert at front
    state = maybe_cancel_current_run(state)
    %{state | jobs: :queue.in_r(job, state.jobs)}
  end

  # Try to merge a followup job with the last followup job in the queue
  defp merge_with_last_followup(queue, new_job) do
    case :queue.out_r(queue) do
      {{:value, %Job{queue_mode: :followup} = last_job}, rest_queue} ->
        # Merge by concatenating text with newline separator
        merged_job = %{last_job | text: last_job.text <> "\n" <> new_job.text}
        {:merged, :queue.in(merged_job, rest_queue)}

      _ ->
        :no_merge
    end
  end

  # Cancel the currently running job if there is one
  defp maybe_cancel_current_run(%{current_run: nil} = state), do: state

  defp maybe_cancel_current_run(%{current_run: run_pid} = state) when is_pid(run_pid) do
    LemonGateway.Scheduler.cancel(run_pid, :interrupted)
    state
  end

  defp followup_debounce_ms do
    Application.get_env(:lemon_gateway, :followup_debounce_ms, @followup_debounce_ms)
  end

  @impl true
  def handle_info({:slot_granted, slot_ref}, state) do
    cond do
      state.current_run != nil ->
        LemonGateway.Scheduler.release_slot(slot_ref)
        {:noreply, state}

      :queue.is_empty(state.jobs) ->
        LemonGateway.Scheduler.release_slot(slot_ref)
        {:stop, :normal, %{state | slot_pending: false}}

      true ->
        {{:value, job}, jobs} = :queue.out(state.jobs)

        {:ok, run_pid} =
          LemonGateway.RunSupervisor.start_run(%{
            job: job,
            slot_ref: slot_ref,
            thread_key: state.thread_key,
            worker_pid: self()
          })

        mon_ref = Process.monitor(run_pid)

        {:noreply,
         %{
           state
           | jobs: jobs,
             current_run: run_pid,
             current_slot_ref: slot_ref,
             run_mon_ref: mon_ref,
             slot_pending: false
         }}
    end
  end

  @impl true
  def handle_info({:run_complete, run_pid, _completed_event}, state) do
    state =
      if run_pid == state.current_run do
        if state.run_mon_ref do
          Process.demonitor(state.run_mon_ref, [:flush])
        end

        # Coalesce consecutive :collect jobs at the front of the queue
        coalesced_jobs = coalesce_collect_jobs(state.jobs)
        %{state | current_run: nil, current_slot_ref: nil, run_mon_ref: nil, jobs: coalesced_jobs}
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

  def handle_info({:DOWN, mon_ref, :process, pid, _reason}, state) do
    if state.current_run == pid and state.run_mon_ref == mon_ref do
      if state.current_slot_ref do
        LemonGateway.Scheduler.release_slot(state.current_slot_ref)
      end

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

  # Handle steer rejection from Run - re-enqueue as followup
  def handle_info({:steer_rejected, %Job{} = job}, state) do
    followup_job = %{job | queue_mode: :followup}
    state = enqueue_by_mode(followup_job, state)
    {:noreply, maybe_request_slot(state)}
  end

  # Handle steer_backlog rejection from Run - enqueue at back like :collect
  def handle_info({:steer_backlog_rejected, %Job{} = job}, state) do
    collect_job = %{job | queue_mode: :collect}
    state = %{state | jobs: :queue.in(collect_job, state.jobs)}
    {:noreply, maybe_request_slot(state)}
  end

  defp maybe_request_slot(state) do
    if state.current_run == nil and not state.slot_pending and not :queue.is_empty(state.jobs) do
      LemonGateway.Scheduler.request_slot(self(), state.thread_key)
      %{state | slot_pending: true}
    else
      state
    end
  end

  @doc """
  Coalesces consecutive :collect jobs at the front of the queue into a single job.

  Merges text with newline separator, keeps the scope from the first job,
  and uses the user_msg_id from the last job.
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
        extract_collect_jobs(rest, acc ++ [job])

      _ ->
        # No more :collect jobs or queue is empty
        {acc, queue}
    end
  end

  # Merge multiple :collect jobs into one
  # Keeps scope from first, user_msg_id from last, concatenates text
  defp merge_collect_jobs([first | _] = jobs) do
    last = List.last(jobs)
    merged_text = jobs |> Enum.map(& &1.text) |> Enum.join("\n")

    %{first | text: merged_text, user_msg_id: last.user_msg_id}
  end
end
