defmodule LemonGateway.Scheduler do
  @moduledoc false
  use GenServer

  alias LemonGateway.{ChatState, Config, Store}
  alias LemonGateway.Types.{Job, ResumeToken}

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

  @spec cancel(pid(), term()) :: :ok
  def cancel(run_pid, reason \\ :user_requested) do
    if is_pid(run_pid) and Process.alive?(run_pid) do
      GenServer.cast(run_pid, {:cancel, reason})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    max = LemonGateway.Config.get(:max_concurrent_runs)

    {:ok,
     %{
       max: max,
       in_flight: %{},
       waitq: :queue.new(),
       monitors: %{},
       worker_counts: %{}
     }}
  end

  @impl true
  def handle_cast({:submit, job}, state) do
    job = maybe_apply_auto_resume(job)
    thread_key = thread_key(job)

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
          mon_ref: mon_ref
        })

      send(worker_pid, {:slot_granted, slot_ref})
      {:noreply, %{state | in_flight: in_flight}}
    else
      {state, mon_ref} = ensure_monitor(state, worker_pid)

      waitq =
        :queue.in(%{worker: worker_pid, thread_key: thread_key, mon_ref: mon_ref}, state.waitq)

      {:noreply, %{state | waitq: waitq}}
    end
  end

  def handle_cast({:release_slot, slot_ref}, state) do
    {state, removed} = pop_in_flight(state, slot_ref)
    state = maybe_demonitor_worker(state, removed)
    {:noreply, grant_until_full(state)}
  end

  @impl true
  def handle_info({:DOWN, mon_ref, :process, pid, _reason}, state) do
    state =
      case Map.get(state.monitors, pid) do
        ^mon_ref -> cleanup_worker(state, pid)
        _ -> state
      end

    {:noreply, grant_until_full(state)}
  end

  defp maybe_grant_next(state) do
    if map_size(state.in_flight) < state.max do
      case :queue.out(state.waitq) do
        {{:value, %{worker: worker_pid, thread_key: thread_key, mon_ref: mon_ref}}, waitq} ->
          slot_ref = make_ref()

          in_flight =
            Map.put(state.in_flight, slot_ref, %{
              worker: worker_pid,
              thread_key: thread_key,
              mon_ref: mon_ref
            })

          send(worker_pid, {:slot_granted, slot_ref})
          %{state | in_flight: in_flight, waitq: waitq}

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp grant_until_full(state) do
    if map_size(state.in_flight) < state.max and not :queue.is_empty(state.waitq) do
      state |> maybe_grant_next() |> grant_until_full()
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

    %{state | in_flight: in_flight, waitq: waitq, monitors: monitors, worker_counts: counts}
  end

  defp drop_waitq_worker(queue, pid) do
    list = :queue.to_list(queue)

    {kept, removed} =
      Enum.split_with(list, fn entry ->
        entry.worker != pid
      end)

    {:queue.from_list(kept), length(removed)}
  end

  defp thread_key(%Job{resume: %ResumeToken{engine: engine, value: value}}) do
    {engine, value}
  end

  defp thread_key(%Job{session_key: session_key}) when is_binary(session_key) do
    {:session, session_key}
  end

  defp thread_key(%Job{scope: scope}) when not is_nil(scope), do: {:scope, scope}
  defp thread_key(_), do: {:default, :global}

  defp maybe_apply_auto_resume(%Job{resume: %ResumeToken{}} = job), do: job

  defp maybe_apply_auto_resume(%Job{session_key: session_key} = job)
       when is_binary(session_key) do
    if Config.get(:auto_resume) do
      case Store.get_chat_state(session_key) do
        %ChatState{last_engine: engine, last_resume_token: token}
        when is_binary(engine) and is_binary(token) ->
          apply_resume_if_compatible(job, engine, token)

        %{} = map ->
          engine = map.last_engine || map[:last_engine] || map["last_engine"]
          token = map.last_resume_token || map[:last_resume_token] || map["last_resume_token"]

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
  rescue
    _ -> job
  end

  defp maybe_apply_auto_resume(job), do: job

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
      {:ok, name} ->
        case safe_enqueue(name, job) do
          :ok ->
            :ok

          {:error, :noproc} ->
            case ensure_worker(thread_key) do
              {:ok, name2} -> safe_enqueue(name2, job) |> normalize_enqueue()
              {:error, _} -> :ok
            end
        end

      {:error, _} ->
        :ok
    end
  end

  defp ensure_worker(thread_key) do
    name = {:via, Registry, {LemonGateway.ThreadRegistry, thread_key}}

    case LemonGateway.ThreadRegistry.whereis(thread_key) do
      nil ->
        case DynamicSupervisor.start_child(
               LemonGateway.ThreadWorkerSupervisor,
               {LemonGateway.ThreadWorker, thread_key: thread_key}
             ) do
          {:ok, _pid} ->
            {:ok, name}

          {:error, {:already_started, _pid}} ->
            {:ok, name}

          {:error, _reason} = err ->
            err
        end

      _pid ->
        {:ok, name}
    end
  end

  defp safe_enqueue(name, job) do
    try do
      GenServer.call(name, {:enqueue, job}, 5_000)
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, _ -> {:error, :noproc}
    end
  end

  defp normalize_enqueue(:ok), do: :ok
  defp normalize_enqueue(_), do: :ok
end
