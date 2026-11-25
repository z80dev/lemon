defmodule CodingAgent.TaskRuntime.ChildTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.{TaskRuntime, TaskRuntimeHelpers, TaskStore}
  alias CodingAgent.TaskRuntime.Control

  defmodule Session do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_cast({:steer, text, false, reply_to, token}, owner) do
      send(owner, {:delivered, self(), text})
      send(reply_to, {:session_steering_reply, token, :ok})
      {:noreply, owner}
    end

    def handle_cast(:abort, owner) do
      send(owner, {:aborted, self()})
      {:noreply, owner}
    end
  end

  # A session whose shutdown blocks until the test releases it.
  defmodule BlockingSession do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    def init(owner) do
      Process.flag(:trap_exit, true)
      {:ok, owner}
    end

    def handle_cast(_request, owner), do: {:noreply, owner}

    def terminate(_reason, owner) do
      send(owner, {:shutdown_blocked, self()})

      receive do
        :release_shutdown -> :ok
      end
    end
  end

  setup do
    parent = session()
    opts = [session_pid: parent, session_id: unique_id(), agent_id: "runtime-test"]
    %{parent: parent, opts: opts}
  end

  test "each owner keeps its own bounded pending content until its session attaches", context do
    first = child(context)
    second = child(context)
    assert :ok = Control.command(first, "message", "first", context.opts)
    assert :ok = Control.command(first, "message", "second", context.opts)

    assert TaskRuntime.whereis(first) != TaskRuntime.whereis(second)
    assert :queue.to_list(entry(first).pending) == ["first", "second"]
    assert entry(second).pending_count == 0

    recipient = session()
    assert :ok = Control.attach_session(first, recipient, unique_id())
    assert_receive {:delivered, ^recipient, "first"}
    assert_receive {:delivered, ^recipient, "second"}
    assert :ok = Control.command(first, "message", "third", context.opts)
    assert_receive {:delivered, ^recipient, "third"}
    assert entry(first).pending_count == 0
  end

  test "the byte cap includes envelopes and is enforced at admission", context do
    id = child(context)
    body = String.duplicate("x", 32 * 1024)
    for _ <- 1..8, do: assert(:ok = Control.command(id, "message", body, context.opts))

    assert {:error, "Task message queue is full (64 messages / 256 KiB)"} =
             Control.command(id, "message", "x", context.opts)

    small = child(context)
    for _ <- 1..64, do: assert(:ok = Control.command(small, "message", "small", context.opts))
    assert {:error, _} = Control.command(small, "message", "overflow", context.opts)
  end

  test "failed broadcast preflight does not consume another child's capacity", context do
    full = child(context)
    other = child(context)
    body = String.duplicate("x", 32 * 1024)
    for _ <- 1..8, do: assert(:ok = Control.command(full, "message", body, context.opts))

    assert {:error, "Task message queue is full (64 messages / 256 KiB)"} =
             Control.send_message("all", "not partially accepted", context.opts)

    assert_eventually(fn -> entry(other).reservations == %{} end)
    assert entry(other).pending_count == 0
    for _ <- 1..64, do: assert(:ok = Control.command(other, "message", "small", context.opts))
    assert {:error, _} = Control.command(other, "message", "overflow", context.opts)
  end

  test "a reservation dies with the process that made it", context do
    id = child(context)
    owner = TaskRuntime.whereis(id)

    {reserver, monitor} =
      spawn_monitor(fn ->
        {:ok, _ref} = :gen_statem.call(owner, {:reserve, "held", self()})
      end)

    assert_receive {:DOWN, ^monitor, :process, ^reserver, :normal}
    assert_eventually(fn -> entry(id).reservations == %{} end)
  end

  test "foreign task IDs stay indistinguishable from missing IDs", context do
    id = child(context)
    foreign = Keyword.put(context.opts, :session_id, unique_id())
    assert {:error, "Unknown task_id: " <> ^id} = Control.authorize(id, foreign)
    assert {:error, "Unknown task_id: " <> ^id} = Control.command(id, "cancel", nil, foreign)
    assert {:error, _} = Control.send_message(id, "foreign", foreign)
    assert :ok = Control.command(id, "message", "owned", context.opts)
  end

  test "session DOWN updates liveness and idle sessions become parked", context do
    for idle? <- [false, true] do
      id = child(context)
      recipient = session()
      assert :ok = Control.attach_session(id, recipient, unique_id())

      if idle? do
        retain(id, recipient, 0)
        complete(id)
        assert_eventually(fn -> phase(id) == :idle end)
      end

      monitor = Process.monitor(recipient)
      GenServer.stop(recipient)
      assert_receive {:DOWN, ^monitor, :process, ^recipient, :normal}
      expected = if idle?, do: :parked, else: :dead
      assert_eventually(fn -> Control.hub_state([id])[id].status == expected end)
      assert Control.hub_state([id])[id].session == nil
      assert entry(id).session_ref == nil
    end
  end

  test "launching publishes a wakeup and only a scalar worker projection", context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))
    {:ok, record} = TaskStore.get_record(id)
    run_id = record.run_id
    :ok = LemonCore.Bus.subscribe("run_graph:#{run_id}")

    assert :ok = TaskRuntimeHelpers.launch(id)
    assert_receive {:run_graph, :state_changed, ^run_id}
    [worker] = Control.worker_pids([id, "missing", id])
    assert TaskRuntime.pids([id]) == [TaskRuntime.whereis(id), worker]

    send(worker, :finish)

    assert_receive {:finalized, {:error, "Task worker exited before reporting a result"}}
    assert_eventually(fn -> Control.worker_pids([id]) == [] end)
    assert phase(id) == :aborted
  end

  test "a worker that finalized its own turn is not finalized again by its owner", context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))
    finalize = entry(id).finalize

    assert :ok =
             TaskRuntimeHelpers.launch(id, fn ->
               TaskStore.finish(id, "done")
               finalize.({:ok, "done"})
             end)

    assert_receive {:finalized, {:ok, "done"}}
    assert_eventually(fn -> phase(id) == :completed end)
    refute_received {:finalized, _}
  end

  test "cancellation closes admission and force-cancels the worker", context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))
    assert :ok = Control.command(id, "message", "discard", context.opts)
    assert :ok = TaskRuntimeHelpers.launch(id)
    [worker] = Control.worker_pids([id])
    worker_monitor = Process.monitor(worker)

    assert :ok = Control.command(id, "cancel", nil, context.opts)
    assert entry(id).pending_count == 0
    assert {:error, _} = Control.command(id, "message", "refused", context.opts)

    recipient = session()
    assert {:error, "Task aborted"} = Control.attach_session(id, recipient)
    assert_receive {:aborted, ^recipient}
    refute_received {:delivered, ^recipient, _}

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 5_000
    assert_receive {:finalized, {:error, "Task aborted"}}
    assert_eventually(fn -> phase(id) == :killed end)
    assert Control.worker_pids([id]) == []
    assert :ok = TaskRuntimeHelpers.launch(id)
    assert Control.worker_pids([id]) == []
    assert {:ok, %{status: :cancelled, agent_state: :killed}} = TaskStore.get_record(id)
  end

  test "a cancel before launch finalizes the turn at once and never starts a worker",
       context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))

    assert :ok = Control.command(id, "cancel", nil, context.opts)
    assert_receive {:finalized, {:error, "Task aborted"}}
    assert_eventually(fn -> phase(id) == :killed end)
    assert :ok = TaskRuntimeHelpers.launch(id, fn -> send(test, :worker_ran) end)
    assert Control.worker_pids([id]) == []
    refute_receive :worker_ran, 100
    refute_received {:finalized, _}
    assert {:ok, %{status: :cancelled, agent_state: :killed}} = TaskStore.get_record(id)
  end

  test "a parent aborted before registration finalizes the turn", context do
    test = self()
    signal = LemonAgent.AbortSignal.new()
    LemonAgent.AbortSignal.abort(signal)
    id = child(context, parent_signal: signal, finalize: &send(test, {:finalized, &1}))

    assert_receive {:finalized, {:error, "Task aborted"}}
    assert_eventually(fn -> phase(id) == :killed end)
    assert {:ok, %{status: :cancelled}} = TaskStore.get_record(id)
  end

  test "a replaced session's stale monitor cannot mark its replacement dead", context do
    id = child(context)
    first = session()
    second = session()
    assert :ok = Control.attach_session(id, first, unique_id())
    old_ref = entry(id).session_ref
    assert :ok = Control.attach_session(id, second, unique_id())
    send(TaskRuntime.whereis(id), {:DOWN, old_ref, :process, first, :normal})
    assert %{status: :running, session: ^second} = Control.hub_state([id])[id]
    assert :ok = Control.command(id, "message", "current recipient", context.opts)
    assert_receive {:delivered, ^second, "current recipient"}
    refute_received {:delivered, ^first, _}
  end

  test "an already-dead parent is still monitored and removes its child", context do
    {parent, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^parent, :normal}

    test = self()
    id = child(%{context | parent: parent}, finalize: &send(test, {:finalized, &1}))
    assert_receive {:finalized, {:error, "Task aborted"}}
    assert_eventually(fn -> TaskRuntime.whereis(id) == nil end)
    assert Control.hub_state([id]) == %{}
    assert {:error, "Task aborted"} = Control.configure(id, %{})
    assert {:ok, %{status: :cancelled}} = TaskStore.get_record(id)
  end

  test "park expiry stops the session and leaves the child parked", context do
    id = child(context)
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    retain(id, recipient, 1)
    complete(id)

    # Parking aborts the session before detaching it.
    assert_receive {:aborted, ^recipient}
    assert_eventually(fn -> phase(id) == :parked end)
    assert entry(id).session == nil
    assert timeouts(id) == []
  end

  test "park and force-cancel deadlines belong to each child's phase", context do
    first = idle_child(context, 60_000)
    second = idle_child(context, 60_000)

    assert [{:state_timeout, :park}] = timeouts(first)
    assert [{:state_timeout, :park}] = timeouts(second)
    :ok = Control.configure(second, %{configured: true})
    assert %{status: :idle} = Control.hub_state([second])[second]

    # With no worker to wait for, cancelling an idle child finalizes at once.
    :ok = Control.command(first, "cancel", nil, context.opts)
    assert_eventually(fn -> phase(first) == :killed end)
    assert [{:state_timeout, :prune}] = timeouts(first)
    assert [{:state_timeout, :park}] = timeouts(second)

    :ok = Control.command(first, "cancel", nil, context.opts)
    assert phase(first) == :killed
  end

  test "zero TTL schedules no park timeout", context do
    id = idle_child(context, 0)
    assert phase(id) == :idle
    assert timeouts(id) == []
  end

  test "the stored record, not the owner phase, decides a child's status", context do
    id = child(context)
    projection = %{phase: :running, signal: nil, parent_signal: nil, session: nil}

    # A completed result outranks a phase that gave up on the child afterwards.
    TaskStore.finish(id, "done")
    TaskStore.set_agent_state(id, :aborted)
    assert TaskRuntime.status(%{projection | phase: :aborted}, id) == :completed

    # A resumable result is live until a cancellation, recorded or in flight.
    TaskStore.set_agent_state(id, :idle)
    assert TaskRuntime.status(%{projection | phase: :idle}, id) == :idle
    assert TaskRuntime.status(%{projection | phase: :cancelling}, id) == :cancelled
    TaskStore.set_agent_state(id, :killed)
    assert TaskRuntime.status(%{projection | phase: :idle}, id) == :cancelled

    # A failed result wins over any live phase.
    failed = child(context)
    TaskStore.fail(failed, "boom")
    session = session()
    assert TaskRuntime.status(%{projection | session: session}, failed) == :error
  end

  test "session DOWN during cancellation retains the worker force deadline", context do
    id = child(context)
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    :ok = TaskRuntimeHelpers.launch(id)
    :ok = Control.command(id, "cancel", nil, context.opts)
    monitor = Process.monitor(recipient)
    GenServer.stop(recipient)
    assert_receive {:DOWN, ^monitor, :process, ^recipient, :normal}
    assert_eventually(fn -> entry(id).session == nil end)
    assert phase(id) == :cancelling
    assert [{:state_timeout, :force_cancel}] = timeouts(id)
  end

  test "a blocked session shutdown does not delay another child's cancel or completion",
       context do
    blocked = child(context)
    session = blocking_session()
    :ok = Control.attach_session(blocked, session, unique_id())
    # The worker exits without retaining its session, so the owner stops it.
    :ok = TaskRuntimeHelpers.launch(blocked, fn -> :ok end)
    assert_receive {:shutdown_blocked, ^session}, 2_000

    test = self()
    cancelled = child(context, finalize: &send(test, {:finalized, :cancelled, &1}))
    :ok = TaskRuntimeHelpers.launch(cancelled)

    {elapsed_us, :ok} =
      :timer.tc(fn -> Control.command(cancelled, "cancel", nil, context.opts) end)

    assert elapsed_us < 1_000_000
    assert {:ok, %{status: :cancelled}} = TaskStore.get_record(cancelled)

    completed = child(context, finalize: &send(test, {:finalized, :completed, &1}))
    :ok = TaskRuntimeHelpers.launch(completed, fn -> :ok end)
    assert_receive {:finalized, :completed, _outcome}, 1_000
    assert_eventually(fn -> phase(completed) == :aborted end, timeout: 1_000)

    # The blocked owner is still stopping its own session.
    refute phase_now?(blocked)
    send(session, :release_shutdown)
    assert_eventually(fn -> phase(blocked) == :aborted end)
  end

  test "a restarted owner adopts its live worker and session", context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    :ok = Control.command(id, "message", "before crash", context.opts)
    assert_receive {:delivered, ^recipient, "before crash"}
    :ok = TaskRuntimeHelpers.launch(id)
    [worker] = Control.worker_pids([id])

    first = TaskRuntime.whereis(id)
    Process.exit(first, :kill)
    assert_eventually(fn -> TaskRuntime.whereis(id) not in [nil, first] end)

    assert %{worker: ^worker, session: ^recipient, attempt: 2} = entry(id)
    assert phase(id) == :running
    assert :ok = Control.command(id, "message", "after crash", context.opts)
    assert_receive {:delivered, ^recipient, "after crash"}

    send(worker, :finish)
    assert_receive {:finalized, {:error, "Task worker exited before reporting a result"}}
    assert_eventually(fn -> phase(id) == :aborted end)
    refute_received {:finalized, _}
  end

  test "a worker that exits while its owner is down is reconciled on restart", context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))
    :ok = TaskRuntimeHelpers.launch(id)
    [worker] = Control.worker_pids([id])
    owner = TaskRuntime.whereis(id)
    :ok = :sys.suspend(owner)
    worker_monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}
    Process.exit(owner, :kill)

    assert_receive {:finalized, {:error, "Task worker exited before reporting a result"}}, 2_000
    assert_eventually(fn -> phase(id) == :aborted end)
  end

  test "a repeatedly crashing owner terminalizes its child instead of adopting it", context do
    test = self()
    id = child(context, finalize: &send(test, {:finalized, &1}))
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    :ok = TaskRuntimeHelpers.launch(id)
    [worker] = Control.worker_pids([id])
    worker_monitor = Process.monitor(worker)

    for _ <- 1..2 do
      owner = TaskRuntime.whereis(id)
      Process.exit(owner, :kill)
      assert_eventually(fn -> TaskRuntime.whereis(id) not in [nil, owner] end)
    end

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
    assert_receive {:aborted, ^recipient}
    assert_receive {:finalized, {:error, "Task owner restarted"}}
    assert_eventually(fn -> phase(id) == :aborted end)
    assert entry(id).worker == nil
  end

  test "terminal owners exit after their retention period", context do
    previous = Application.get_env(:coding_agent, :task_terminal_retention_ms)
    Application.put_env(:coding_agent, :task_terminal_retention_ms, 50)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:coding_agent, :task_terminal_retention_ms, previous),
        else: Application.delete_env(:coding_agent, :task_terminal_retention_ms)
    end)

    id = child(context)
    :ok = TaskRuntimeHelpers.launch(id, fn -> :ok end)
    assert_eventually(fn -> TaskRuntime.whereis(id) == nil end)
    assert {:ok, _record} = TaskStore.get_record(id)
  end

  test "owner status hides task content and crash diagnostics", context do
    secret = "runtime-private-prompt"
    id = child(context)
    :ok = Control.command(id, "message", secret, context.opts)
    status = id |> TaskRuntime.whereis() |> :sys.get_status() |> inspect(limit: :infinity)
    refute status =~ secret
    assert status =~ id
  end

  defp idle_child(context, ttl) do
    id = child(context)
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    retain(id, recipient, ttl)
    complete(id)
    assert_eventually(fn -> phase(id) == :idle end)
    id
  end

  defp retain(id, recipient, ttl) do
    resume = %{opts: [idle_ttl_ms: ttl], start_opts: [cwd: "/tmp", session_file: "/unused"]}
    :ok = Control.retain_session(id, recipient, resume)
  end

  # A turn that completed and persisted its own result.
  defp complete(id) do
    finalize = entry(id).finalize

    :ok =
      TaskRuntimeHelpers.launch(id, fn ->
        TaskStore.finish(id, "done")
        finalize.({:ok, "done"})
      end)
  end

  defp phase(id) do
    case TaskRuntimeHelpers.state(id) do
      {phase, _data} -> phase
      nil -> nil
    end
  end

  defp phase_now?(id) do
    match?({_, _}, :sys.get_state(TaskRuntime.whereis(id), 100))
  catch
    :exit, _ -> false
  end

  defp entry(id), do: TaskRuntimeHelpers.entry(id)

  defp timeouts(id) do
    {:status, _, _, [_, _, _, _, status]} = :sys.get_status(TaskRuntime.whereis(id))

    [{_count, timeouts}] =
      for {:data, fields} <- status, {~c"Time-outs", value} <- fields, do: value

    for {type, content} <- timeouts, do: {type, content}
  end

  defp child(context, opts \\ []) do
    id = TaskStore.new_task(%{owner: Control.owner(context.opts), run_id: unique_id()})
    :ok = TaskRuntimeHelpers.register(id, context.parent, opts)

    on_exit(fn ->
      TaskRuntimeHelpers.stop(id)
      TaskStore.delete_task(id)
    end)

    id
  end

  defp session do
    start_supervised!(%{
      id: make_ref(),
      start: {Session, :start_link, [self()]},
      restart: :temporary
    })
  end

  defp blocking_session do
    {:ok, pid} =
      DynamicSupervisor.start_child(CodingAgent.SessionSupervisor, %{
        id: make_ref(),
        start: {BlockingSession, :start_link, [self()]},
        restart: :temporary,
        shutdown: 30_000
      })

    on_exit(fn -> send(pid, :release_shutdown) end)
    pid
  end

  defp unique_id, do: "runtime-#{System.unique_integer([:positive, :monotonic])}"
end
