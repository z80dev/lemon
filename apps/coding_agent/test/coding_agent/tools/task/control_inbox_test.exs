defmodule CodingAgent.Tools.Task.ControlInboxTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.Control
  alias LemonAgent.AbortSignal

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

  setup do
    parent = session()
    opts = [session_pid: parent, session_id: unique_id(), agent_id: "inbox-test"]
    %{parent: parent, opts: opts}
  end

  test "Control retains identities but each child owns bounded pending content", context do
    first = child(context)
    second = child(context)
    assert :ok = Control.command(first, "message", "first", context.opts)
    assert :ok = Control.command(first, "message", "second", context.opts)

    {:ready, entries} = :sys.get_state(Control)
    inbox = entries[first].inbox
    assert is_pid(inbox)
    assert inbox != entries[second].inbox
    refute Map.has_key?(entries[first], :messages)
    refute Map.has_key?(entries[first], :message_count)
    refute Map.has_key?(entries[first], :message_bytes)

    assert {:messages, [{:task_message, "first"}, {:task_message, "second"}]} =
             Process.info(inbox, :messages)

    recipient = session()
    assert :ok = Control.attach_session(first, recipient, unique_id())
    assert_receive {:delivered, ^recipient, "first"}
    assert_receive {:delivered, ^recipient, "second"}
    assert :ok = Control.command(first, "message", "third", context.opts)
    assert_receive {:delivered, ^recipient, "third"}
    assert {:messages, []} = Process.info(inbox, :messages)
  end

  test "failed broadcast preflight does not consume another child's capacity", context do
    full = child(context)
    other = child(context)
    body = String.duplicate("x", 32 * 1024)
    for _ <- 1..8, do: assert(:ok = Control.command(full, "message", body, context.opts))

    assert {:error, "Task message queue is full (64 messages / 256 KiB)"} =
             Control.send_message("all", "not partially accepted", context.opts)

    other_inbox = entry(other).inbox
    assert {:messages, []} = Process.info(other_inbox, :messages)
    for _ <- 1..64, do: assert(:ok = Control.command(other, "message", "small", context.opts))
    assert {:error, _} = Control.command(other, "message", "overflow", context.opts)
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
        resume = %{opts: [idle_ttl_ms: 0], start_opts: [cwd: "/tmp", session_file: "/unused"]}
        assert :ok = Control.retain_session(id, recipient, resume)
        TaskStore.finish(id, "done")
        assert :ok = Control.complete(id)
      end

      entry = entry(id)
      assert is_reference(entry.session_ref)
      trace_down(recipient, entry.session_ref, fn -> GenServer.stop(recipient) end)
      projection = Control.hub_state([id])[id]
      assert projection.session == nil
      assert projection.status == if(idle?, do: :parked, else: :dead)
      assert entry(id).session_ref == nil
    end
  end

  test "worker attachment publishes a wakeup with only a scalar PID projection", context do
    id = child(context)
    {:ok, record} = TaskStore.get_record(id)
    run_id = record.run_id
    :ok = LemonCore.Bus.subscribe("run_graph:#{run_id}")
    test = self()

    worker =
      spawn(fn ->
        :ok = Control.attach_worker(id)
        send(test, {:attached, self()})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:run_graph, :state_changed, ^run_id}
    assert_receive {:attached, ^worker}
    assert Control.worker_pids([id, "missing", id]) == [worker]
    entry = entry(id)
    trace_down(worker, entry.worker_ref, fn -> send(worker, :finish) end)
    assert Control.worker_pids([id]) == []
    assert_receive {:failure, ^id, "Task worker exited: :normal"}
  end

  test "cancellation closes admission and force-cancels the registered worker", context do
    id = child(context)
    assert :ok = Control.command(id, "message", "discard", context.opts)
    inbox = entry(id).inbox
    inbox_monitor = Process.monitor(inbox)
    test = self()

    worker =
      spawn(fn ->
        :ok = Control.attach_worker(id)
        send(test, {:attached, self()})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    worker_monitor = Process.monitor(worker)
    assert_receive {:attached, ^worker}
    assert :ok = Control.command(id, "cancel", nil, context.opts)
    assert_receive {:DOWN, ^inbox_monitor, :process, ^inbox, :normal}
    assert {:error, _} = Control.command(id, "message", "refused", context.opts)

    recipient = session()
    assert {:error, "Task aborted"} = Control.attach_session(id, recipient)
    assert_receive {:aborted, ^recipient}
    refute_received {:delivered, ^recipient, _}

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 5_000
    assert_receive {:failure, ^id, "Task aborted"}
    assert Control.worker_pids([id]) == []
    assert {:error, "Task aborted"} = Control.attach_worker(id)
    assert {:ok, %{status: :cancelled, agent_state: :killed}} = TaskStore.get_record(id)
  end

  test "inbox death cancels its task without replay or a coordinator restart", context do
    id = child(context)
    assert :ok = Control.command(id, "message", "must not replay", context.opts)
    entry = entry(id)
    control = Process.whereis(Control)
    trace_down(entry.inbox, entry.inbox_ref, fn -> Process.exit(entry.inbox, :kill) end)
    assert_receive {:failure, ^id, "Task inbox exited"}
    assert Process.whereis(Control) == control
    assert entry(id).inbox == nil
    assert {:error, _} = Control.send_message(id, "do not restart", context.opts)
    assert {:ok, %{status: :cancelled}} = TaskStore.get_record(id)
  end

  test "a replaced session's stale monitor cannot mark its replacement dead", context do
    id = child(context)
    first = session()
    second = session()
    assert :ok = Control.attach_session(id, first, unique_id())
    old_ref = entry(id).session_ref
    assert :ok = Control.attach_session(id, second, unique_id())
    send(Control, {:DOWN, old_ref, :process, first, :normal})
    assert %{status: :running, session: ^second} = Control.hub_state([id])[id]
    assert :ok = Control.command(id, "message", "current recipient", context.opts)
    assert_receive {:delivered, ^second, "current recipient"}
    refute_received {:delivered, ^first, _}
  end

  test "an already-dead parent is still monitored and removes its child", context do
    {parent, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^parent, :normal}
    control = Process.whereis(Control)
    :erlang.trace(control, true, [:receive])

    try do
      id = child(%{context | parent: parent})
      assert_receive {:trace, ^control, :receive, {:DOWN, _, :process, ^parent, :noproc}}
      assert Control.hub_state([id]) == %{}
      assert {:error, "Task aborted"} = Control.configure(id, %{})
      assert {:ok, %{status: :cancelled}} = TaskStore.get_record(id)
    after
      :erlang.trace(control, false, [:receive])
    end
  end

  test "park expiry detaches the session without timer tokens", context do
    id = child(context)
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    resume = %{opts: [idle_ttl_ms: 1], start_opts: [cwd: "/tmp", session_file: "/unused"]}
    :ok = Control.retain_session(id, recipient, resume)
    TaskStore.finish(id, "done")
    :ok = Control.complete(id)

    # stop_child/1 delivers abort before detaching the session.
    assert_receive {:aborted, ^recipient}
    assert %{phase: :parked, session: nil} = entry(id)
    refute Map.has_key?(entry(id), :idle_token)
    refute Map.has_key?(entry(id), :cancelled)
    refute {{:timeout, {:park, id}}, :park} in active_timeouts()
  end

  test "park and force-cancel deadlines are independent and not reset by traffic", context do
    first = idle_child(context, 60_000)
    second = idle_child(context, 60_000)
    trace_timeouts()

    assert {{:timeout, {:park, first}}, :park} in active_timeouts()
    assert {{:timeout, {:park, second}}, :park} in active_timeouts()
    :ok = Control.configure(second, %{configured: true})
    assert %{status: :idle} = Control.hub_state([second])[second]
    :ok = Control.command(first, "cancel", nil, context.opts)

    assert_receive {:control_timeout_started,
                    {{:timeout, {:force_cancel, ^first}}, 2_000, :force_cancel, []}}

    refute {{:timeout, {:park, first}}, :park} in active_timeouts()
    assert {{:timeout, {:park, second}}, :park} in active_timeouts()
    assert {{:timeout, {:force_cancel, first}}, :force_cancel} in active_timeouts()

    :ok = Control.command(first, "cancel", nil, context.opts)
    send(Control, :unrelated)
    Control.worker_pids([])
    refute_received {:control_timeout_started, _}

    :ok = Control.complete(first)
    assert %{phase: :killed} = entry(first)
    refute {{:timeout, {:force_cancel, first}}, :force_cancel} in active_timeouts()
    assert {{:timeout, {:park, second}}, :park} in active_timeouts()
  end

  test "zero TTL schedules no park timeout", context do
    id = idle_child(context, 0)
    assert %{phase: :idle} = entry(id)
    refute {{:timeout, {:park, id}}, :park} in active_timeouts()
  end

  test "session DOWN during cancellation retains the worker force deadline", context do
    id = child(context)
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    :ok = Control.command(id, "cancel", nil, context.opts)
    monitor = entry(id).session_ref
    trace_down(recipient, monitor, fn -> GenServer.stop(recipient) end)
    assert %{phase: :cancelling, session: nil} = entry(id)
    assert {{:timeout, {:force_cancel, id}}, :force_cancel} in active_timeouts()
    :ok = Control.complete(id)
    refute {{:timeout, {:force_cancel, id}}, :force_cancel} in active_timeouts()
  end

  defp idle_child(context, ttl) do
    id = child(context)
    recipient = session()
    :ok = Control.attach_session(id, recipient, unique_id())
    resume = %{opts: [idle_ttl_ms: ttl], start_opts: [cwd: "/tmp", session_file: "/unused"]}
    :ok = Control.retain_session(id, recipient, resume)
    TaskStore.finish(id, "done")
    :ok = Control.complete(id)
    id
  end

  defp trace_timeouts do
    debug = fn owner, event, _extra ->
      case event do
        {:start_timer, action, :ready} -> send(owner, {:control_timeout_started, action})
        _ -> :ok
      end

      owner
    end

    :ok = :sys.install(Control, {debug, self()})
    on_exit(fn -> :sys.remove(Control, debug) end)
  end

  defp active_timeouts do
    {:status, _, _, [_, _, _, _, status]} = :sys.get_status(Control)

    [{_count, timeouts}] =
      for {:data, fields} <- status, {~c"Time-outs", value} <- fields, do: value

    timeouts
  end

  defp entry(id) do
    {:ready, entries} = :sys.get_state(Control)
    entries[id]
  end

  defp trace_down(pid, monitor, stop) do
    control = Process.whereis(Control)
    :erlang.trace(control, true, [:receive])

    try do
      stop.()
      assert_receive {:trace, ^control, :receive, {:DOWN, ^monitor, :process, ^pid, _}}
      # A call from this process is now behind the observed DOWN handler.
      Control.worker_pids([])
    after
      :erlang.trace(control, false, [:receive])
    end
  end

  defp child(context) do
    id = TaskStore.new_task(%{owner: Control.owner(context.opts), run_id: unique_id()})
    test = self()
    failure = fn reason -> send(test, {:failure, id, reason}) end
    :ok = Control.register(id, AbortSignal.new(), nil, context.parent, failure)

    on_exit(fn ->
      Control.complete(id)
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

  defp unique_id, do: "inbox-#{System.unique_integer([:positive, :monotonic])}"
end
