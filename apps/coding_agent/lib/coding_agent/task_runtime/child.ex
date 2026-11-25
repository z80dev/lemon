defmodule CodingAgent.TaskRuntime.Child do
  @moduledoc """
  Supervised owner of one native task child.

  The owner starts and monitors the child's worker, monitors its session,
  parent session and optional scheduler, holds messages admitted before the
  session attaches (64 messages / 256 KiB including envelopes, counting broadcast
  reservations) and applies cancellation. It does its own blocking work, such as
  session shutdown and store writes; no other child waits on it.

  The worker persists its outcome and sends any completion followup before it
  exits. Exactly one of the worker and this owner finalizes a turn: both go
  through the turn's claim, so a slow or restarted owner can neither lose nor
  repeat a completion. The owner reads the stored record to decide what a
  finished turn means.

  Live deliveries are emitted in order by this owner; acknowledgements are
  awaited by callers outside it. A missing acknowledgement is
  `:outcome_unknown` and never redelivered automatically.

  ## Phases

  | Phase | Event | Next phase |
  | --- | --- | --- |
  | running | worker exit, completed and resumable with a live session | idle (park TTL; zero disables) |
  | running | worker exit, completed and resumable without a live session | parked |
  | running | worker exit, completed but not resumable | completed |
  | running | worker exit otherwise | aborted |
  | idle | park timeout | parked |
  | idle or parked | message accepted | running |
  | live | cancel, parent abort or scheduler DOWN | cancelling (force-cancel grace) |
  | cancelling | worker exit or force timeout (at once without a worker) | killed |
  | killed, aborted, completed | retention timeout | stopped |
  | any | parent session DOWN | stopped |

  Every cancellation and parent DOWN runs the turn's finalizer (a no-op once
  the worker claimed the turn), so a child cancelled before its worker started
  still terminalizes its graph run, budget and progress binding.

  State timeouts belong to a phase, so traffic never resets a park or
  force-cancel deadline and leaving the phase cancels it.

  ## Crash recovery

  The owner journals its state on every change. A restarted owner adopts its
  live worker and session; a worker that exited while the owner was down is
  handled as a normal worker exit. The second restart terminalizes the child
  instead of adopting it.
  """
  @behaviour :gen_statem

  require Logger

  alias CodingAgent.{Session, TaskProgressBindingStore, TaskRuntime, TaskStore}
  alias CodingAgent.TaskRuntime.Journal
  alias CodingAgent.Tools.Task.{Async, Control}
  alias LemonAgent.AbortSignal
  alias LemonCore.{Bus, Event}
  alias LemonCore.TaskSurface.Projection

  @max_count 64
  @max_bytes 256 * 1024
  @force_cancel_ms 2_000
  @adopting_attempts 2
  @terminalizing_attempt 3
  @terminal_phases [:killed, :aborted, :completed]
  @bridge_terminal_events [
    :run_completed,
    :task_completed,
    :task_error,
    :task_timeout,
    :task_aborted
  ]
  @empty_projection %{
    phase: :running,
    signal: nil,
    parent_signal: nil,
    parent: nil,
    owner_pid: nil,
    worker: nil,
    session: nil,
    session_id: nil,
    metadata: %{},
    model: nil
  }

  def child_spec({id, _spec} = arg) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link({id, spec}) do
    :gen_statem.start_link(TaskRuntime.via(id, @empty_projection), __MODULE__, {id, spec}, [])
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def format_status(status),
    do: LemonCore.StatusRedaction.gen_statem(status, [:id, :phase, :attempt])

  @impl true
  def init({id, spec}) do
    Process.flag(:trap_exit, true)

    case {Journal.fetch(id), spec} do
      {{:ok, row}, nil} ->
        recover(row)

      {{:ok, %{incarnation: same} = row}, %{incarnation: same}} ->
        recover(row)

      {_row, %{} = spec} ->
        # Monitors and the abort subscription exist before registration returns.
        data = id |> fresh(spec) |> load_metadata() |> watch()
        TaskRuntime.publish(id, projection(data))
        {:ok, :running, data, [{:next_event, :internal, :boot}]}

      {:error, nil} ->
        :ignore
    end
  end

  defp fresh(id, spec) do
    %{
      id: id,
      incarnation: spec.incarnation,
      attempt: 1,
      signal: spec.signal,
      parent_signal: spec[:parent_signal],
      parent: spec[:parent],
      owner_pid: spec[:owner_pid],
      claim: spec.claim,
      finalize: spec.finalize,
      continuation: spec[:continuation],
      phase: :running,
      worker: nil,
      session: nil,
      session_id: nil,
      resume: nil,
      metadata: %{},
      pending: :queue.new(),
      pending_count: 0,
      pending_bytes: 0,
      reservations: %{},
      bridge: nil,
      parent_ref: nil,
      owner_ref: nil,
      worker_ref: nil,
      session_ref: nil
    }
  end

  defp recover(%{attempt: attempt} = data) when attempt >= @terminalizing_attempt do
    Journal.delete(data.id)
    :ignore
  end

  defp recover(data) do
    data = %{data | attempt: data.attempt + 1}
    # Count the attempt before any work that could crash it again.
    Journal.put(data.id, data)

    data =
      data
      |> watch()
      |> Map.put(:worker_ref, monitor(data.worker))
      |> Map.put(:session_ref, monitor(data.session))

    TaskRuntime.publish(data.id, projection(data))
    {:ok, data.phase, data, [{:next_event, :internal, :recover}]}
  end

  defp load_metadata(data) do
    metadata =
      case TaskStore.get_record(data.id) do
        {:ok, record} ->
          Map.take(record, [
            :owner,
            :name,
            :run_id,
            :parent_run_id,
            :parent_session_id,
            :orchestration_worker
          ])

        _ ->
          %{}
      end

    %{data | metadata: metadata}
  end

  # -- lifecycle ------------------------------------------------------------------

  @impl true
  def handle_event(:enter, _previous, phase, data),
    do: {:keep_state_and_data, phase_timeouts(phase, data)}

  def handle_event(:internal, :boot, phase, data) do
    data = open_bridge(data)

    if AbortSignal.aborted?(data.parent_signal),
      do: cancel(phase, data),
      else: next(phase, data)
  end

  def handle_event(:internal, :recover, phase, data) do
    data = reopen_bridge(data)

    cond do
      data.attempt > @adopting_attempts ->
        terminalize(phase, data)

      # The launching caller lost its owner mid-launch; nothing will start a worker.
      phase == :running and is_nil(data.worker) and not finalized?(data) ->
        terminalize(phase, data)

      AbortSignal.aborted?(data.parent_signal) ->
        cancel(phase, data)

      true ->
        next(phase, data)
    end
  end

  # -- worker and session ---------------------------------------------------------

  def handle_event({:call, from}, {:launch, supervisor, fun}, phase, data) do
    if phase != :running or is_pid(data.worker) or finalized?(data) do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    else
      case LemonCore.TaskSupervisor.start_child(supervisor, fun) do
        {:ok, worker} ->
          next(phase, attach_worker(data, worker), [{:reply, from, :ok}])

        {:error, reason} ->
          # The caller claims and terminalizes an unadmitted launch.
          {:stop_and_reply, :normal, [{:reply, from, {:error, reason}}], data}
      end
    end
  end

  def handle_event({:call, from}, {:session, session, session_id, reply_to}, phase, data) do
    if unavailable(data) do
      Session.abort(session)
      {:keep_state_and_data, [{:reply, from, {:error, "Task aborted"}}]}
    else
      deliveries =
        data.pending
        |> :queue.to_list()
        |> Enum.map(&Session.request_steering(session, &1, reply_to))

      demonitor(data.session_ref)

      data = %{
        drop_pending(data)
        | session: session,
          session_ref: Process.monitor(session),
          session_id: session_id
      }

      next(phase, data, [{:reply, from, {:deliver_pending, deliveries}}])
    end
  end

  def handle_event({:call, from}, {:configure, context}, phase, data),
    do: next(phase, %{data | continuation: context}, [{:reply, from, :ok}])

  def handle_event({:call, from}, {:retain_session, session, resume}, phase, data) do
    if phase == :running and data.session == session do
      TaskStore.set_agent_state(data.id, :running, %{
        session_id: data.session_id,
        session_file: resume.start_opts[:session_file],
        cwd: resume.start_opts[:cwd]
      })

      next(phase, %{data | resume: resume}, [{:reply, from, :ok}])
    else
      {:keep_state_and_data, [{:reply, from, {:error, "Task aborted"}}]}
    end
  end

  # -- cancellation ---------------------------------------------------------------

  def handle_event({:call, from}, :cancel, phase, data),
    do: cancel(phase, data, [{:reply, from, :ok}])

  def handle_event(:cast, :cancel, phase, data), do: cancel(phase, data)

  # A redirect interrupts only the parent's in-flight model request; it never
  # cancels children. Redirect wakeups fall through to the catch-all below.
  def handle_event(:info, {:lemon_abort, signal, :abort}, phase, %{parent_signal: signal} = data),
    do: cancel(phase, data)

  # -- messages -------------------------------------------------------------------

  def handle_event({:call, from}, {:enqueue, text, reply_to}, phase, data) do
    reply =
      cond do
        phase in [:cancelling, :killed] -> {:error, "Task is being cancelled"}
        status = unavailable(data) -> {:error, "Task is #{status}"}
        true -> capacity(data, text)
      end

    case reply do
      :ok ->
        case deliver(phase, data, text, reply_to) do
          {:queued, data} -> next(phase, data, [{:reply, from, :ok}])
          {:pending, pending} -> {:keep_state_and_data, [{:reply, from, {:delivery, pending}}]}
          {:error, reason} -> {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
        end

      error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def handle_event({:call, from}, {:deliver, text, reply_to}, phase, data) do
    case prepare(data, text) do
      :ok ->
        {delivery, phase, data} = deliver_recipient(phase, data, text, reply_to)
        next(phase, data, [{:reply, from, {:ok, delivery}}])

      {:error, {:unavailable, reason}} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}

      error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def handle_event({:call, from}, {:reserve, text, caller}, phase, data) do
    case prepare(data, text) do
      :ok ->
        ref = Process.monitor(caller)
        reservations = Map.put(data.reservations, ref, byte_size(text))
        next(phase, %{data | reservations: reservations}, [{:reply, from, {:ok, ref}}])

      error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def handle_event({:call, from}, {:commit, ref, text, reply_to}, phase, data) do
    case Map.pop(data.reservations, ref) do
      {nil, _reservations} ->
        {:keep_state_and_data, [{:reply, from, {:ok, :failed}}]}

      {_bytes, reservations} ->
        Process.demonitor(ref, [:flush])
        data = %{data | reservations: reservations}
        {delivery, phase, data} = deliver_recipient(phase, data, text, reply_to)
        next(phase, data, [{:reply, from, {:ok, delivery}}])
    end
  end

  def handle_event(:cast, {:release, ref}, phase, data) do
    Process.demonitor(ref, [:flush])
    next(phase, %{data | reservations: Map.delete(data.reservations, ref)})
  end

  # -- monitors and timeouts --------------------------------------------------------

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, phase, data) do
    cond do
      ref == data.worker_ref -> worker_down(phase, data, reason)
      ref == data.session_ref -> session_down(phase, data)
      ref == data.parent_ref -> parent_down(phase, data)
      ref == data.owner_ref -> cancel(phase, data)
      Map.has_key?(data.reservations, ref) -> release(phase, data, ref)
      true -> :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :park, :idle, data) do
    stop_child(data)
    TaskStore.set_agent_state(data.id, :parked)
    next(:parked, detach_session(data))
  end

  def handle_event(:state_timeout, :force_cancel, :cancelling, data) do
    stop_child(data)

    if is_pid(data.worker), do: Process.exit(data.worker, :kill)
    # Claim-protected: a no-op when the worker (or an earlier turn) finalized.
    finalize(data, "Task aborted")

    TaskStore.set_agent_state(data.id, :killed)
    data = data |> detach_worker() |> detach_session() |> drop_pending()
    next(:killed, %{data | resume: nil})
  end

  def handle_event(:state_timeout, :prune, _phase, data), do: {:stop, :normal, data}

  # -- progress bridge ----------------------------------------------------------------

  def handle_event(:info, %Event{type: :engine_action, payload: payload}, _phase, data)
      when is_map(payload) and is_map(data.bridge) do
    binding = data.bridge
    projected = Projection.project_child_payload(payload, binding)

    event =
      Event.new(:task_projected_child_action, projected, %{
        run_id: binding.parent_run_id,
        parent_run_id: binding.parent_run_id,
        session_key: binding.parent_session_key,
        child_run_id: binding.child_run_id,
        task_id: binding.task_id,
        projected_from: :child_run
      })

    Bus.broadcast(Bus.run_topic(binding.parent_run_id), event)
    :keep_state_and_data
  end

  def handle_event(:info, %Event{type: type}, phase, data)
      when type in @bridge_terminal_events and is_map(data.bridge) do
    close_bridge(data.bridge)
    next(phase, %{data | bridge: nil})
  end

  def handle_event(:info, _message, _phase, _data), do: :keep_state_and_data

  @impl true
  def terminate(:normal, _phase, data), do: Journal.delete(data.id)
  # A crash or a dependency-group restart keeps the journal for recovery.
  def terminate(_reason, _phase, _data), do: :ok

  # -- transitions --------------------------------------------------------------------

  defp next(phase, data, actions \\ []) do
    data = %{data | phase: phase}
    TaskRuntime.publish(data.id, projection(data))
    Journal.put(data.id, journal_row(data))
    {:next_state, phase, data, actions}
  end

  defp phase_timeouts(:idle, %{resume: %{opts: opts}}) do
    case Keyword.get(opts, :idle_ttl_ms, 300_000) do
      ttl when is_integer(ttl) and ttl > 0 -> [{:state_timeout, ttl, :park}]
      _ -> []
    end
  end

  # Without a worker there is nothing to wait for: finalize at once.
  defp phase_timeouts(:cancelling, %{worker: nil}), do: [{:state_timeout, 0, :force_cancel}]
  defp phase_timeouts(:cancelling, _data), do: [{:state_timeout, @force_cancel_ms, :force_cancel}]

  defp phase_timeouts(phase, _data) when phase in @terminal_phases,
    do: [{:state_timeout, retention_ms(), :prune}]

  defp phase_timeouts(_phase, _data), do: []

  # Terminal children stay addressable (roster, history pointers) for a while,
  # then their owner exits; the stored record remains the durable answer.
  defp retention_ms,
    do: Application.get_env(:coding_agent, :task_terminal_retention_ms, 300_000)

  defp cancel(phase, data, actions \\ [])

  defp cancel(phase, data, actions) when phase in [:cancelling, :killed],
    do: next(phase, data, actions)

  defp cancel(_phase, data, actions) do
    TaskStore.cancel(data.id, "Task aborted")
    TaskStore.set_agent_state(data.id, :killed)
    AbortSignal.abort(data.signal)
    if is_pid(data.session), do: Session.abort(data.session)
    next(:cancelling, drop_pending(data), actions)
  end

  defp worker_down(phase, data, reason) do
    data = detach_worker(data)
    unless finalized?(data), do: finalize(data, worker_failure(phase, reason))
    complete(phase, data)
  end

  defp complete(phase, data) do
    if TaskRuntime.status(projection(data), data.id) == :completed and data.resume != nil and
         phase not in [:cancelling, :killed] do
      phase = if is_pid(data.session), do: :idle, else: :parked
      TaskStore.set_agent_state(data.id, phase)
      next(phase, data)
    else
      stop_child(data)

      phase =
        cond do
          phase in [:cancelling, :killed] -> :killed
          # A completed turn that cannot be resumed is still a completed task.
          TaskRuntime.status(projection(data), data.id) == :completed -> :completed
          true -> :aborted
        end

      if phase != :completed, do: TaskStore.set_agent_state(data.id, phase)
      data = data |> detach_session() |> drop_pending()
      next(phase, %{data | resume: nil})
    end
  end

  defp session_down(phase, data) do
    phase =
      case phase do
        :running ->
          :dead

        idle when idle in [:idle, :parked] ->
          TaskStore.set_agent_state(data.id, :parked)
          :parked

        other ->
          other
      end

    next(phase, detach_session(data))
  end

  defp parent_down(phase, data) do
    {:next_state, _phase, data, _actions} = cancel(phase, data)
    stop_child(data)

    if is_pid(data.worker), do: Process.exit(data.worker, :kill)
    # Finalize even before launch so graph, budget and progress terminalize.
    finalize(data, "Task aborted")

    {:stop, :normal, data}
  end

  defp terminalize(_phase, data) do
    AbortSignal.abort(data.signal)
    if is_pid(data.worker), do: Process.exit(data.worker, :kill)
    stop_child(data)
    finalize(data, "Task owner restarted")
    TaskStore.set_agent_state(data.id, :aborted)
    data = data |> detach_worker() |> detach_session() |> drop_pending()
    next(:aborted, %{data | resume: nil})
  end

  defp release(phase, data, ref),
    do: next(phase, %{data | reservations: Map.delete(data.reservations, ref)})

  defp worker_failure(phase, _reason) when phase in [:cancelling, :killed], do: "Task aborted"
  defp worker_failure(_phase, :killed), do: "Task worker exited: killed"

  defp worker_failure(_phase, reason) when reason in [:normal, :noproc],
    do: "Task worker exited before reporting a result"

  # Exit reasons can carry exception terms; only a fixed classification is kept.
  defp worker_failure(_phase, _reason), do: "Task worker exited: crashed"

  # -- delivery -----------------------------------------------------------------------

  defp prepare(data, text) do
    id = data.id

    case TaskRuntime.status(projection(data), id) do
      status when status in [:idle, :parked] ->
        resumable(data)

      status when status in [:queued, :running] ->
        capacity(data, text)

      status ->
        {:error, {:unavailable, "Agent agent://#{id} is #{status}; read history://#{id}"}}
    end
  end

  defp resumable(%{id: id, resume: resume, continuation: continuation}) do
    cond do
      is_nil(resume) or is_nil(continuation) ->
        {:error, "Agent cannot resume; read history://#{id}"}

      not File.dir?(resume.start_opts[:cwd]) ->
        {:error, "Agent workspace/worktree was removed; read history://#{id}"}

      not File.regular?(resume.start_opts[:session_file]) ->
        {:error, "Agent transcript is unavailable; read history://#{id}"}

      true ->
        :ok
    end
  end

  defp capacity(%{metadata: %{orchestration_worker: true}}, _text),
    do: {:error, "Swarm coordinator has no model session; message a launched child instead"}

  defp capacity(%{session: session}, _text) when is_pid(session), do: :ok

  defp capacity(data, text) do
    reserved = Map.values(data.reservations)
    count = data.pending_count + length(reserved)
    bytes = data.pending_bytes + Enum.sum(reserved) + byte_size(text)

    if count >= @max_count or bytes > @max_bytes,
      do: {:error, "Task message queue is full (64 messages / 256 KiB)"},
      else: :ok
  end

  defp deliver_recipient(phase, data, text, reply_to) do
    case TaskRuntime.status(projection(data), data.id) do
      status when status in [:idle, :parked] ->
        wake(phase, data, text, status)

      _ ->
        case deliver(phase, data, text, reply_to) do
          {:queued, data} -> {:injected, phase, data}
          {:pending, pending} -> {pending, phase, data}
          {:error, _reason} -> {:failed, phase, data}
        end
    end
  end

  defp deliver(phase, _data, _text, _reply_to)
       when phase in [:cancelling, :killed, :aborted],
       do: {:error, "Task is no longer running"}

  defp deliver(_phase, %{session: session}, text, reply_to) when is_pid(session),
    do: {:pending, Session.request_steering(session, text, reply_to)}

  defp deliver(_phase, data, text, _reply_to) do
    {:queued,
     %{
       data
       | pending: :queue.in(text, data.pending),
         pending_count: data.pending_count + 1,
         pending_bytes: data.pending_bytes + byte_size(text)
     }}
  end

  defp wake(phase, data, text, status) do
    case TaskStore.begin_agent_turn(data.id) do
      :ok ->
        turn = Async.continuation(data.id, data, text)

        case LemonCore.TaskSupervisor.start_child(turn.supervisor, turn.run) do
          {:ok, worker} ->
            data = %{attach_worker(data, worker) | claim: turn.claim, finalize: turn.finalize}
            {if(status == :parked, do: :revived, else: :woken), :running, data}

          {:error, _reason} ->
            TaskStore.fail(data.id, "Failed to start child message turn")
            TaskStore.set_agent_state(data.id, :aborted)
            stop_child(data)
            data = data |> detach_session() |> drop_pending()
            {:failed, :aborted, %{data | resume: nil}}
        end

      {:error, _reason} ->
        {:failed, phase, data}
    end
  end

  # -- helpers ------------------------------------------------------------------------

  defp unavailable(data) do
    case TaskRuntime.status(projection(data), data.id) do
      status when status in [:queued, :running] -> nil
      status -> status
    end
  end

  defp finalized?(%{claim: claim}), do: :atomics.get(claim, 1) == 1

  # The turn's finalizer claims the turn itself; it is a no-op once the worker
  # (or an earlier owner path) has finalized. A failing store or followup call
  # must not take down the owner of the child it is finalizing.
  defp finalize(data, reason) do
    data.finalize.({:error, reason})
  catch
    kind, _reason ->
      Logger.warning("Task owner could not finalize task_id=#{data.id} (#{kind})")
      :ok
  end

  defp attach_worker(data, worker) do
    data = %{detach_worker(data) | worker: worker, worker_ref: Process.monitor(worker)}

    if is_binary(data.metadata[:run_id]) do
      run_id = data.metadata.run_id
      Bus.broadcast("run_graph:#{run_id}", {:run_graph, :state_changed, run_id})
    end

    data
  end

  defp detach_worker(data) do
    demonitor(data.worker_ref)
    %{data | worker: nil, worker_ref: nil}
  end

  defp detach_session(data) do
    demonitor(data.session_ref)
    %{data | session: nil, session_ref: nil}
  end

  defp drop_pending(data), do: %{data | pending: :queue.new(), pending_count: 0, pending_bytes: 0}

  defp stop_child(%{session: session}) when is_pid(session) do
    Session.abort(session)
    # Also cancel any descendants before stopping their parent session.
    Control.cancel_parent(session)
    CodingAgent.SessionSupervisor.stop_session(session)
  catch
    :exit, _ -> :ok
  end

  defp stop_child(_data), do: :ok

  defp watch(data) do
    AbortSignal.subscribe(data.parent_signal)

    parent_ref =
      if is_pid(data.parent) do
        TaskRuntime.watch_parent(data.parent)
        Process.monitor(data.parent)
      end

    %{data | parent_ref: parent_ref, owner_ref: monitor(data.owner_pid)}
  end

  defp monitor(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor(_pid), do: nil

  defp demonitor(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor(_ref), do: :ok

  defp open_bridge(%{metadata: %{run_id: run_id}} = data) when is_binary(run_id) do
    case TaskProgressBindingStore.get_by_child_run_id(run_id) do
      {:ok, binding} ->
        Bus.subscribe(Bus.run_topic(run_id))
        %{data | bridge: binding}

      _ ->
        data
    end
  catch
    :exit, _ -> data
  end

  defp open_bridge(data), do: data

  defp reopen_bridge(%{bridge: %{child_run_id: run_id}} = data) do
    Bus.subscribe(Bus.run_topic(run_id))
    data
  end

  defp reopen_bridge(data), do: data

  defp close_bridge(binding) do
    Bus.unsubscribe(Bus.run_topic(binding.child_run_id))
    TaskProgressBindingStore.delete_by_child_run_id(binding.child_run_id)
  catch
    :exit, _ -> :ok
  end

  defp projection(data) do
    data
    |> Map.take([
      :phase,
      :signal,
      :parent_signal,
      :parent,
      :owner_pid,
      :worker,
      :session,
      :session_id,
      :metadata
    ])
    |> Map.put(:model, data.resume && data.resume.start_opts[:model])
  end

  defp journal_row(data) do
    %{
      data
      | parent_ref: nil,
        owner_ref: nil,
        worker_ref: nil,
        session_ref: nil,
        reservations: %{}
    }
  end
end
