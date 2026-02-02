defmodule LemonGateway.ThreadWorker do
  @moduledoc false
  use GenServer

  alias LemonGateway.Types.Job

  def start_link(opts) do
    thread_key = Keyword.fetch!(opts, :thread_key)
    GenServer.start_link(__MODULE__, %{thread_key: thread_key})
  end

  @impl true
  def init(state) do
    :ok = LemonGateway.ThreadRegistry.register(state.thread_key)

    {:ok,
     Map.merge(state, %{
       jobs: :queue.new(),
       current_run: nil,
       slot_pending: false
     })}
  end

  @impl true
  def handle_cast({:enqueue, %Job{} = job}, state) do
    jobs = :queue.in(job, state.jobs)
    state = %{state | jobs: jobs}
    {:noreply, maybe_request_slot(state)}
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
        {:ok, run_pid} = LemonGateway.RunSupervisor.start_run(%{
          job: job,
          slot_ref: slot_ref,
          thread_key: state.thread_key,
          worker_pid: self()
        })

        {:noreply, %{state | jobs: jobs, current_run: run_pid, slot_pending: false}}
    end
  end

  @impl true
  def handle_info({:run_complete, run_pid, _completed_event}, state) do
    state =
      if run_pid == state.current_run do
        %{state | current_run: nil}
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

  defp maybe_request_slot(state) do
    if state.current_run == nil and not state.slot_pending and not :queue.is_empty(state.jobs) do
      LemonGateway.Scheduler.request_slot(self(), state.thread_key)
      %{state | slot_pending: true}
    else
      state
    end
  end
end
