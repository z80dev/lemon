defmodule CodingAgent.LaneQueue do
  @moduledoc """
  Lane-aware FIFO queue with concurrency caps per lane.

  Intended for scheduling subagent and background work with separate caps.
  Optimized with O(1) task_ref to job_id lookup.
  """

  use GenServer

  @type lane :: atom() | {:session, term()}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a 0-arity function to run under a lane cap.

  Returns {:ok, result} or {:error, reason}.
  """
  @spec run(GenServer.server(), lane(), (() -> term()), map()) ::
          {:ok, term()} | {:error, term()}
  def run(server \\ __MODULE__, lane, fun, meta \\ %{}) when is_function(fun, 0) do
    GenServer.call(server, {:enqueue, lane, fun, meta}, :infinity)
  end

  @impl true
  def init(opts) do
    caps = opts |> Keyword.fetch!(:caps) |> normalize_caps()
    task_sup = Keyword.fetch!(opts, :task_supervisor)

    {:ok,
     %{
       caps: caps,
       task_sup: task_sup,
       lanes: %{},
       jobs: %{},
       # O(1) lookup: task_ref -> job_id
       task_ref_index: %{}
     }}
  end

  @impl true
  def handle_call({:enqueue, lane, fun, meta}, from, st) do
    job_id = make_ref()
    st = put_in(st.jobs[job_id], %{from: from, lane: lane, fun: fun, meta: meta, task_ref: nil})

    st =
      st
      |> lane_enqueue(lane, job_id)
      |> drain_lane(lane)

    {:noreply, st}
  end

  @impl true
  def handle_info({ref, {:ok, result}}, st) do
    {:noreply, complete_job(ref, {:ok, result}, st)}
  end

  def handle_info({ref, {:error, reason}}, st) do
    {:noreply, complete_job(ref, {:error, reason}, st)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, st) do
    {:noreply, complete_job(ref, {:error, reason}, st)}
  end

  def handle_info(_msg, st), do: {:noreply, st}

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

      true ->
        {{:value, job_id}, q2} = :queue.out(ls.q)
        job = st.jobs[job_id]

        task =
          Task.Supervisor.async_nolink(st.task_sup, fn ->
            try do
              {:ok, job.fun.()}
            rescue
              e -> {:error, {e, __STACKTRACE__}}
            catch
              kind, err -> {:error, {kind, err}}
            end
          end)

        job = %{job | task_ref: task.ref}

        # Update both jobs map and task_ref index
        st =
          st
          |> put_in([:jobs, job_id], job)
          |> put_in([:task_ref_index, task.ref], job_id)

        ls = %{ls | running: ls.running + 1, q: q2}
        st = put_in(st.lanes[lane], ls)

        drain_lane(st, lane)
    end
  end

  defp complete_job(task_ref, reply, st) do
    # O(1) lookup using task_ref_index
    case Map.get(st.task_ref_index, task_ref) do
      nil ->
        st

      job_id ->
        job = st.jobs[job_id]

        if job do
          GenServer.reply(job.from, reply)

          lane = job.lane
          ls = lane_state(st, lane)
          ls = %{ls | running: max(ls.running - 1, 0)}

          st =
            st
            |> update_in([:lanes, lane], fn _ -> ls end)
            |> update_in([:jobs], &Map.delete(&1, job_id))
            |> update_in([:task_ref_index], &Map.delete(&1, task_ref))
            |> drain_lane(lane)

          st
        else
          st
        end
    end
  end
end
