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
    # Insert at front of queue (will be processed after current run completes)
    %{state | jobs: :queue.in_r(job, state.jobs)}
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

        %{state | current_run: nil, current_slot_ref: nil, run_mon_ref: nil}
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

  defp maybe_request_slot(state) do
    if state.current_run == nil and not state.slot_pending and not :queue.is_empty(state.jobs) do
      LemonGateway.Scheduler.request_slot(self(), state.thread_key)
      %{state | slot_pending: true}
    else
      state
    end
  end
end
