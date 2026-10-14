defmodule CodingAgent.LaneQueue do
  @moduledoc """
  Lane-aware FIFO queue with concurrency caps per lane.

  Intended for scheduling subagent and background work with separate caps.
  Optimized with O(1) task_ref to job_id lookup.
  """

  use GenServer
  require Logger

  @type lane :: atom() | {:session, term()}

  @doc """
  Start a LaneQueue process.

  Options:
  - `:name` - registered name (defaults to `__MODULE__`)
  - `:caps` - map or keyword list of `lane => max_concurrency` (required)
  - `:task_supervisor` - PID or name of a `Task.Supervisor` (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a 0-arity function to run under a lane cap.

  Returns {:ok, result} or {:error, reason}.
  """
  @spec run(GenServer.server(), lane(), (-> term()), map()) ::
          {:ok, term()} | {:error, term()}
  def run(server \\ __MODULE__, lane, fun, meta \\ %{}) when is_function(fun, 0) do
    GenServer.call(server, {:enqueue, lane, fun, meta}, :infinity)
  end

  @doc false
  def run_background(server, identity, fun, meta) when is_function(fun, 0) do
    wait =
      Map.get(meta, :admission_wait_ms) ||
        Application.get_env(:coding_agent, :background_admission_wait_ms, 1_000)

    if is_integer(wait) and wait > 0 and wait <= 86_400_000 do
      GenServer.call(server, {:background_enqueue, identity, fun, meta}, wait)
    else
      {:error, {:background_rejected, :rejected, :invalid_admission_deadline}}
    end
  end

  @impl true
  def init(opts) do
    case CodingAgent.ProcessManager.background_limits(opts) do
      {:ok, limits} -> init_queue(opts, limits)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_queue(opts, limits) do
    caps = opts |> Keyword.fetch!(:caps) |> normalize_caps()
    task_sup = Keyword.fetch!(opts, :task_supervisor)
    cap = Map.get(caps, :background_exec, 1)

    if is_integer(cap) and cap > 0 do
      init_queue_state(caps, task_sup, limits)
    else
      {:stop, :invalid_background_launch_cap}
    end
  end

  defp init_queue_state(caps, task_sup, limits) do
    Logger.info("LaneQueue initialized caps=#{inspect(caps)}")

    {:ok,
     %{
       caps: caps,
       task_sup: task_sup,
       lanes: %{},
       jobs: %{},
       # O(1) lookup: task_ref -> job_id
       task_ref_index: %{},
       # Queued callers are monitored so abandoned calls do not consume a lane.
       caller_ref_index: %{},
       owner_ref_index: %{},
       background_index: %{},
       background_limits: limits,
       store_ref: nil
     }}
  end

  def handle_call({:background_enqueue, identity, fun, meta}, from, st) do
    meta = Map.put(meta, :identity, identity)
    ls = lane_state(st, :background_exec)

    timeout =
      Map.get(meta, :admission_timeout_ms) || st.background_limits.background_admission_timeout_ms

    wait = Map.get(meta, :admission_wait_ms) || st.background_limits.background_admission_wait_ms

    cond do
      not (is_integer(timeout) and timeout > 0 and is_integer(wait) and wait > 0) ->
        {:reply, {:error, {:background_rejected, :rejected, :invalid_admission_deadline}}, st}

      not background_launch_cap_valid?(st) ->
        {:reply, {:error, {:background_rejected, :rejected, :invalid_launch_cap}}, st}

      not background_pending?(identity, Map.get(meta, :owner)) ->
        {:reply, background_reply(%{meta: meta}, :reconcile), st}

      :queue.len(ls.q) >= st.background_limits.background_pending_limit and
          (ls.running >= cap_for_lane(st, :background_exec) or not capacity_available?()) ->
        {:reply, {:error, {:background_rejected, :rejected, :overloaded}}, st}

      true ->
        case subscribe_capacity(st) do
          {:ok, st} ->
            meta =
              meta
              |> Map.put(:identity, identity)
              |> Map.put(:type, :background_exec)
              |> Map.put(:admission_timeout_ms, timeout)
              |> Map.put(:admission_wait_ms, wait)

            {:noreply, enqueue_job(:background_exec, fun, meta, from, st)}

          :error ->
            {:reply, {:error, {:background_rejected, :rejected, :admission_unavailable}}, st}
        end
    end
  end

  @impl true
  def handle_call({:enqueue, lane, fun, meta}, from, st) do
    {:noreply, enqueue_job(lane, fun, meta, from, st)}
  end

  @impl true
  def handle_call(:status, _from, st) do
    Logger.debug("LaneQueue status jobs=#{map_size(st.jobs)} lanes=#{map_size(st.lanes)}")
    {:reply, %{caps: st.caps, lanes: st.lanes, jobs_count: map_size(st.jobs)}, st}
  end

  def handle_info({:background_yield, identity}, st) do
    case background_job(st, identity) do
      {job_id, job} ->
        {job, st} = yield_ownership(st, job_id, job)
        reply_job(job, background_reply(job, :yield))
        {:noreply, put_in(st.jobs[job_id], %{job | from: nil, yield_ref: nil})}

      nil ->
        {:noreply, st}
    end
  end

  def handle_info({:background_expire, identity}, st) do
    case background_job(st, identity) do
      {job_id, %{task_ref: nil} = job} ->
        CodingAgent.ProcessStore.classify_launch(identity, :expired, :admission_deadline)
        reply_job(job, background_reply(job, :deadline))
        {:noreply, remove_queued_job(st, job_id, job) |> drain_lane(job.lane)}

      {job_id, job} ->
        # Starting/accepted work is not killed because its caller's wait ended.
        CodingAgent.ProcessStore.classify_launch(identity, :expired, :admission_deadline)
        reply_job(job, background_reply(job, :deadline))
        {:noreply, put_in(st.jobs[job_id], %{job | from: nil, deadline_ref: nil})}

      nil ->
        {:noreply, st}
    end
  end

  def handle_info({:background_launch_classified, identity, :expired}, st) do
    handle_info({:background_expire, identity}, st)
  end

  def handle_info({:background_launch_canceled, identity}, st) do
    case background_job(st, identity) do
      {job_id, %{task_ref: nil} = job} ->
        reply_job(job, {:error, {:background_rejected, :canceled, nil}})
        {:noreply, remove_queued_job(st, job_id, job) |> drain_lane(job.lane)}

      _ ->
        {:noreply, st}
    end
  end

  def handle_info(:background_capacity_changed, st) do
    {:noreply, drain_lane(st, :background_exec)}
  end

  def handle_info(:resubscribe_capacity, st) do
    case subscribe_capacity(st) do
      {:ok, st} ->
        {:noreply, drain_lane(st, :background_exec)}

      :error ->
        Process.send_after(self(), :resubscribe_capacity, 100)
        {:noreply, st}
    end
  end

  def handle_info({ref, {:ok, {:queued, identity}}}, st) do
    Process.demonitor(ref, [:flush])

    case background_job(st, identity) do
      {job_id, %{task_ref: ^ref} = job} ->
        ls = lane_state(st, job.lane)

        st =
          st
          |> put_in([:jobs, job_id], %{job | task_ref: nil})
          |> put_in([:lanes, job.lane], %{
            ls
            | running: ls.running - 1,
              q: :queue.in_r(job_id, ls.q)
          })
          |> update_in([:task_ref_index], &Map.delete(&1, ref))
          |> drain_lane(job.lane)

        {:noreply, st}

      _ ->
        {:noreply, complete_job(ref, {:ok, {:queued, identity}}, st)}
    end
  end

  @impl true
  def handle_info({ref, {:ok, result}}, st) do
    Logger.debug("LaneQueue job completed successfully ref=#{inspect(ref)}")
    Process.demonitor(ref, [:flush])
    {:noreply, complete_job(ref, {:ok, result}, st)}
  end

  def handle_info({ref, {:error, reason}}, st) do
    Logger.warning("LaneQueue job failed ref=#{inspect(ref)} reason=#{inspect(reason)}")
    Process.demonitor(ref, [:flush])
    {:noreply, complete_job(ref, {:error, reason}, st)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, st) do
    cond do
      ref == st.store_ref ->
        send(self(), :resubscribe_capacity)
        {:noreply, %{st | store_ref: nil}}

      Map.has_key?(st.owner_ref_index, ref) ->
        job_id = Map.fetch!(st.owner_ref_index, ref)
        {:noreply, cancel_pending_job(st, job_id)}

      Map.has_key?(st.task_ref_index, ref) ->
        Logger.warning("LaneQueue job process down ref=#{inspect(ref)} reason=#{inspect(reason)}")
        {:noreply, complete_job(ref, {:error, reason}, st)}

      Map.has_key?(st.caller_ref_index, ref) ->
        {:noreply, cancel_queued_caller(ref, st)}

      true ->
        {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  defp enqueue_job(lane, fun, meta, from, st) do
    job_id = make_ref()
    {caller_pid, _tag} = from
    caller_ref = Process.monitor(caller_pid)

    owner_ref =
      case {Map.get(meta, :type), Map.get(meta, :owner_pid)} do
        {:background_exec, pid} when is_pid(pid) and pid != caller_pid -> Process.monitor(pid)
        _ -> nil
      end

    background? = Map.get(meta, :type) == :background_exec
    identity = Map.get(meta, :identity)

    deadline =
      if background? do
        Map.get(meta, :admission_deadline_ms) ||
          System.system_time(:millisecond) + Map.get(meta, :admission_timeout_ms, 5_000)
      end

    deadline_ref =
      if background?,
        do:
          Process.send_after(
            self(),
            {:background_expire, identity},
            max(deadline - System.system_time(:millisecond), 0)
          )

    yield_ref =
      if background?,
        do:
          Process.send_after(
            self(),
            {:background_yield, identity},
            Map.fetch!(meta, :admission_wait_ms)
          )

    cap = cap_for_lane(st, lane)
    ls = lane_state(st, lane)
    queue_len = :queue.len(ls.q)

    Logger.debug(
      "LaneQueue enqueue lane=#{inspect(lane)} job_id=#{inspect(job_id)} cap=#{cap} queued=#{queue_len} running=#{ls.running}"
    )

    st =
      st
      |> put_in([:jobs, job_id], %{
        from: from,
        lane: lane,
        fun: fun,
        meta: meta,
        task_ref: nil,
        caller_ref: caller_ref,
        caller_pid: caller_pid,
        caller_detached: background? and yielded_launch?(identity),
        owner_ref: owner_ref,
        deadline: deadline,
        deadline_ref: deadline_ref,
        yield_ref: yield_ref
      })
      |> put_in([:caller_ref_index, caller_ref], job_id)

    st =
      if background? do
        st = put_in(st.background_index[identity], job_id)
        if owner_ref, do: put_in(st.owner_ref_index[owner_ref], job_id), else: st
      else
        st
      end

    st =
      st
      |> lane_enqueue(lane, job_id)
      |> drain_lane(lane)

    st
  end

  defp lane_state(st, lane) do
    Map.get(st.lanes, lane, %{running: 0, q: :queue.new()})
  end

  defp cap_for_lane(st, lane) do
    caps = st.caps

    cond do
      is_map(caps) -> Map.get(caps, lane, 1)
      is_list(caps) -> Keyword.get(caps, lane, 1)
      true -> 1
    end
  end

  defp normalize_caps(caps) when is_map(caps), do: caps
  defp normalize_caps(caps) when is_list(caps), do: Map.new(caps)
  defp normalize_caps(_), do: %{}

  defp lane_enqueue(st, lane, job_id) do
    ls = lane_state(st, lane)
    ls = %{ls | q: :queue.in(job_id, ls.q)}
    put_in(st.lanes[lane], ls)
  end

  defp drain_lane(st, lane) do
    ls = lane_state(st, lane)
    cap = cap_for_lane(st, lane)

    cond do
      ls.running >= cap ->
        st

      :queue.is_empty(ls.q) ->
        st

      background_head_abandoned?(st, ls) ->
        {:value, job_id} = :queue.peek(ls.q)
        cancel_pending_job(st, job_id)

      background_head_blocked?(st, ls) ->
        st

      true ->
        {{:value, job_id}, q2} = :queue.out(ls.q)
        job = st.jobs[job_id]

        Logger.debug(
          "LaneQueue starting job lane=#{inspect(lane)} job_id=#{inspect(job_id)} running=#{ls.running + 1}/#{cap}"
        )

        task_result =
          start_supervised_job(st.task_sup, fn ->
            try do
              result = job.fun.()
              Logger.debug("LaneQueue job function completed job_id=#{inspect(job_id)}")
              {:ok, result}
            rescue
              e ->
                reason =
                  if Map.get(job.meta, :type) == :background_exec,
                    do: :launch_failed,
                    else: {e, __STACKTRACE__}

                {:error, reason}
            catch
              kind, err ->
                reason =
                  if Map.get(job.meta, :type) == :background_exec,
                    do: :launch_failed,
                    else: {kind, err}

                {:error, reason}
            end
          end)

        case task_result do
          {:ok, task} ->
            job = %{job | task_ref: task.ref}

            st =
              st
              |> put_in([:jobs, job_id], job)
              |> put_in([:task_ref_index, task.ref], job_id)

            ls = %{ls | running: ls.running + 1, q: q2}
            st = put_in(st.lanes[lane], ls)

            drain_lane(st, lane)

          {:error, reason} ->
            Logger.warning(
              "LaneQueue could not admit job job_id=#{inspect(job_id)} reason=#{inspect(reason)}"
            )

            reply_job(job, {:error, {:task_start_failed, reason}})

            st =
              st
              |> put_in([:lanes, lane], %{ls | q: q2})
              |> forget_job(job_id, job)

            drain_lane(st, lane)
        end
    end
  end

  defp complete_job(task_ref, reply, st) do
    # O(1) lookup using task_ref_index
    case Map.get(st.task_ref_index, task_ref) do
      nil ->
        Logger.warning("LaneQueue complete_job unknown task_ref=#{inspect(task_ref)}")
        st

      job_id ->
        job = st.jobs[job_id]

        if job do
          Logger.debug(
            "LaneQueue completing job job_id=#{inspect(job_id)} lane=#{inspect(job.lane)} reply=#{elem(reply, 0)}"
          )

          reply_job(job, reply)

          lane = job.lane
          ls = lane_state(st, lane)
          ls = %{ls | running: max(ls.running - 1, 0)}

          st =
            st
            |> update_in([:lanes, lane], fn _ -> ls end)
            |> forget_job(job_id, job)
            |> update_in([:task_ref_index], &Map.delete(&1, task_ref))
            |> drain_lane(lane)

          st
        else
          st
        end
    end
  end

  defp start_supervised_job(task_supervisor, fun) do
    {:ok, Task.Supervisor.async_nolink(task_supervisor, fun)}
  rescue
    error -> {:error, {:exception, error}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp cancel_queued_caller(caller_ref, st) do
    job_id = Map.fetch!(st.caller_ref_index, caller_ref)

    case Map.get(st.jobs, job_id) do
      job when is_map(job) ->
        if Map.get(job.meta, :type) == :background_exec and yielded_launch?(job.meta.identity) do
          st
          |> put_in([:jobs, job_id], %{job | caller_detached: true})
          |> update_in([:caller_ref_index], &Map.delete(&1, caller_ref))
        else
          cancel_pending_job(st, job_id)
        end

      _ ->
        st
    end
  end

  defp background_job(st, identity) do
    with job_id when not is_nil(job_id) <- Map.get(st.background_index, identity),
         job when not is_nil(job) <- Map.get(st.jobs, job_id) do
      {job_id, job}
    else
      _ -> nil
    end
  end

  defp background_reply(job, _phase) do
    id = job.meta.identity

    case CodingAgent.ProcessStore.launch_receipt(id, Map.get(job.meta, :owner)) do
      {:ok, %{classification: :accepted}} ->
        {:ok, {:ok, id}}

      {:ok, %{classification: :queued}} ->
        {:queued, id}

      {:ok, %{classification: classification, reason: reason}}
      when classification in [:rejected, :expired, :canceled] ->
        {:error, {:background_rejected, classification, reason}}

      _ ->
        {:ok, {:error, {:outcome_unknown, id}}}
    end
  catch
    :exit, _ -> {:ok, {:error, {:outcome_unknown, job.meta.identity}}}
  end

  defp yield_ownership(st, job_id, job) do
    owner_pid = Map.get(job.meta, :owner_pid)

    if is_pid(owner_pid) and owner_pid != job.caller_pid and not job.caller_detached and
         background_pending?(job.meta.identity, Map.get(job.meta, :owner)) and
         CodingAgent.ProcessStore.yield_launch(job.meta.identity, Map.get(job.meta, :owner)) ==
           :ok do
      Process.demonitor(job.caller_ref, [:flush])
      job = %{job | caller_detached: true}

      st =
        st
        |> put_in([:jobs, job_id], job)
        |> update_in([:caller_ref_index], &Map.delete(&1, job.caller_ref))

      {job, st}
    else
      {job, st}
    end
  end

  defp reply_job(%{from: nil}, _reply), do: :ok
  defp reply_job(job, reply), do: GenServer.reply(job.from, reply)

  defp cleanup_job(job) do
    Process.demonitor(job.caller_ref, [:flush])
    if job.owner_ref, do: Process.demonitor(job.owner_ref, [:flush])
    if job.deadline_ref, do: Process.cancel_timer(job.deadline_ref)
    if job.yield_ref, do: Process.cancel_timer(job.yield_ref)
  end

  defp forget_job(st, job_id, job) do
    cleanup_job(job)

    st
    |> update_in([:jobs], &Map.delete(&1, job_id))
    |> update_in([:caller_ref_index], &Map.delete(&1, job.caller_ref))
    |> update_in([:owner_ref_index], &Map.delete(&1, job.owner_ref))
    |> update_in([:background_index], &Map.delete(&1, Map.get(job.meta, :identity)))
  end

  defp remove_queued_job(st, job_id, job) do
    ls = lane_state(st, job.lane)

    st
    |> put_in([:lanes, job.lane], %{ls | q: :queue.filter(&(&1 != job_id), ls.q)})
    |> forget_job(job_id, job)
  end

  defp cancel_pending_job(st, job_id) do
    case Map.get(st.jobs, job_id) do
      %{task_ref: nil} = job ->
        if Map.get(job.meta, :type) == :background_exec do
          CodingAgent.ProcessStore.cancel_launch(job.meta.identity, Map.get(job.meta, :owner))
          reply_job(job, {:error, {:background_rejected, :canceled, nil}})
        end

        remove_queued_job(st, job_id, job) |> drain_lane(job.lane)

      job when is_map(job) ->
        if Map.get(job.meta, :type) == :background_exec do
          # A task may exist without having crossed the serialized start claim.
          # Cancel the claim if still pending; never infer OS termination.
          CodingAgent.ProcessStore.cancel_launch(job.meta.identity, Map.get(job.meta, :owner))
        end

        st

      _ ->
        st
    end
  end

  defp capacity_available? do
    CodingAgent.ProcessStore.capacity_available?()
  catch
    :exit, _ -> false
  end

  defp background_launch_cap_valid?(st) do
    cap = cap_for_lane(st, :background_exec)
    is_integer(cap) and cap > 0
  end

  defp background_head_blocked?(st, ls) do
    case :queue.peek(ls.q) do
      {:value, job_id} ->
        job = st.jobs[job_id]
        Map.get(job.meta, :type) == :background_exec and not capacity_available?()

      :empty ->
        false
    end
  end

  defp background_head_abandoned?(st, ls) do
    {:value, job_id} = :queue.peek(ls.q)
    job = st.jobs[job_id]
    owner = Map.get(job.meta, :owner_pid)

    Map.get(job.meta, :type) == :background_exec and
      ((not job.caller_detached and not Process.alive?(job.caller_pid) and
          not yielded_launch?(job.meta.identity)) or
         (is_pid(owner) and not Process.alive?(owner)))
  end

  defp background_pending?(identity, owner) do
    match?(
      {:ok, %{classification: :queued}},
      CodingAgent.ProcessStore.launch_receipt(identity, owner)
    )
  catch
    :exit, _ -> false
  end

  defp yielded_launch?(identity) do
    CodingAgent.ProcessStore.yielded_launch?(identity)
  catch
    :exit, _ -> false
  end

  defp subscribe_capacity(st) do
    case Process.whereis(CodingAgent.ProcessStoreServer) do
      nil ->
        :error

      pid ->
        :ok = CodingAgent.ProcessStore.subscribe_capacity(self())
        ref = st.store_ref || Process.monitor(pid)
        {:ok, %{st | store_ref: ref}}
    end
  catch
    :exit, _ -> :error
  end
end
