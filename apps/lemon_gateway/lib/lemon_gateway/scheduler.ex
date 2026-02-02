defmodule LemonGateway.Scheduler do
  @moduledoc false
  use GenServer

  alias LemonGateway.Types.Job

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job) do
    GenServer.cast(__MODULE__, {:submit, job})
  end

  @spec request_slot(pid(), term()) :: :ok
  def request_slot(worker_pid, thread_key) do
    GenServer.cast(__MODULE__, {:request_slot, worker_pid, thread_key})
  end

  @spec release_slot(reference()) :: :ok
  def release_slot(slot_ref) do
    GenServer.cast(__MODULE__, {:release_slot, slot_ref})
  end

  @impl true
  def init(_opts) do
    max = LemonGateway.Config.get(:max_concurrent_runs)

    {:ok,
     %{
       max: max,
       in_flight: %{},
       waitq: :queue.new()
     }}
  end

  @impl true
  def handle_cast({:submit, job}, state) do
    thread_key = thread_key(job)

    worker_pid =
      case LemonGateway.ThreadRegistry.whereis(thread_key) do
        nil ->
          {:ok, pid} =
            DynamicSupervisor.start_child(
              LemonGateway.ThreadWorkerSupervisor,
              {LemonGateway.ThreadWorker, thread_key: thread_key}
            )

          pid

        pid ->
          pid
      end

    GenServer.cast(worker_pid, {:enqueue, job})

    {:noreply, state}
  end

  def handle_cast({:request_slot, worker_pid, thread_key}, state) do
    if map_size(state.in_flight) < state.max do
      slot_ref = make_ref()
      in_flight = Map.put(state.in_flight, slot_ref, %{worker: worker_pid, thread_key: thread_key})
      send(worker_pid, {:slot_granted, slot_ref})
      {:noreply, %{state | in_flight: in_flight}}
    else
      waitq = :queue.in({worker_pid, thread_key}, state.waitq)
      {:noreply, %{state | waitq: waitq}}
    end
  end

  def handle_cast({:release_slot, slot_ref}, state) do
    in_flight = Map.delete(state.in_flight, slot_ref)
    state = %{state | in_flight: in_flight}
    {:noreply, maybe_grant_next(state)}
  end

  defp maybe_grant_next(state) do
    if map_size(state.in_flight) < state.max do
      case :queue.out(state.waitq) do
        {{:value, {worker_pid, thread_key}}, waitq} ->
          slot_ref = make_ref()
          in_flight = Map.put(state.in_flight, slot_ref, %{worker: worker_pid, thread_key: thread_key})
          send(worker_pid, {:slot_granted, slot_ref})
          %{state | in_flight: in_flight, waitq: waitq}

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp thread_key(%Job{resume: %LemonGateway.Types.ResumeToken{engine: engine, value: value}}) do
    {engine, value}
  end

  defp thread_key(%Job{scope: scope}), do: {:scope, scope}
end
