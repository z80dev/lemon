defmodule CodingAgent.ProcessAdmissionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{LaneQueue, ProcessManager, ProcessSession, ProcessStore}

  setup do
    ProcessStore.clear()
    store = CodingAgent.ProcessStoreServer
    original_limit = :sys.get_state(store).background_limit
    original_config = Application.fetch_env(:coding_agent, :background_process_limit)
    Application.put_env(:coding_agent, :background_process_limit, 2)
    :sys.replace_state(store, &%{&1 | background_limit: 2})

    on_exit(fn ->
      :sys.replace_state(store, &%{&1 | background_limit: original_limit})

      case original_config do
        {:ok, value} -> Application.put_env(:coding_agent, :background_process_limit, value)
        :error -> Application.delete_env(:coding_agent, :background_process_limit)
      end
    end)

    task_sup = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

    queue =
      start_supervised!(
        {LaneQueue,
         name: __MODULE__.Queue,
         caps: %{background_exec: 2, main: 1},
         background_pending_limit: 1,
         task_supervisor: task_sup}
      )

    directory =
      Path.join(System.tmp_dir!(), "lemon-admission-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    {:ok, sessions} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for {id, pid} <- Agent.get(sessions, & &1) do
        send(pid, :release_start)

        if Process.alive?(pid) do
          try do
            ProcessSession.kill(id, :sigkill)
          catch
            :exit, _ -> :ok
          end
        end

        case ProcessStore.get(id) do
          {:ok, %{os_pid: os_pid, status: status}, _}
          when is_integer(os_pid) and status in [:running, :starting, :killing, :lost] ->
            {command, _} = System.cmd("ps", ["-p", Integer.to_string(os_pid), "-o", "command="])

            if String.contains?(command, directory),
              do: CodingAgent.BashExecutor.kill_process_tree(os_pid)

          _ ->
            :ok
        end
      end

      File.rm_rf!(directory)
      Agent.stop(sessions)
    end)

    %{queue: queue, task_sup: task_sup, directory: directory, sessions: sessions}
  end

  defp launch(context, suffix) do
    id = "admission-#{System.unique_integer([:positive])}-#{suffix}"
    counter = Path.join(context.directory, "#{suffix}.counter")
    fifo = Path.join(context.directory, "#{suffix}.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    test = self()

    reader =
      spawn(fn ->
        # A BEAM file-server FIFO open would block creation of the capture file,
        # which must precede the shell writer. Keep this observer outside it.
        case System.cmd("cat", [fifo]) do
          {"started\n", 0} -> send(test, {:external_started, id})
          {"", 0} -> :ok
        end
      end)

    on_exit(fn ->
      ref = Process.monitor(reader)

      if Process.alive?(reader) do
        # O_RDWR unblocks a never-started FIFO fixture without inventing a start.
        {:ok, unblock} = File.open(fifo, [:read, :write])
        File.close(unblock)
      end

      assert_receive {:DOWN, ^ref, :process, ^reader, _}, 5_000
    end)

    opts = [
      command:
        "trap '' TERM; printf x >> '#{counter}'; printf 'started\\n' > '#{fifo}'; read -r release",
      launch_id: id,
      owner: "admission-test",
      lane_queue: context.queue,
      admission_timeout_ms: 60_000,
      admission_wait_ms: 60_000,
      on_start: fn identity ->
        session = self()
        Agent.update(context.sessions, &[{identity, session} | &1])
        send(test, {:start_boundary, identity, session})
        receive do: (:release_start -> :ok)
      end,
      on_exit: fn result -> send(test, {:external_terminated, result.process_id}) end
    ]

    {id, counter, opts}
  end

  defp boundary(id) do
    assert_receive {:start_boundary, ^id, session}, 5_000
    assert_receive {:external_started, ^id}, 5_000
    session
  end

  defp terminate(id) do
    assert :ok = ProcessManager.kill(id, :sigkill)
    assert_receive {:external_terminated, ^id}, 5_000
  end

  defp start_blocking(context, suffix, extra \\ []) do
    {id, counter, opts} = launch(context, suffix)
    opts = Keyword.merge(opts, extra)
    caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    session = boundary(id)
    send(session, :release_start)
    assert {:ok, ^id} = Task.await(caller)
    {id, counter, opts, session}
  end

  defp enqueue(context, suffix, extra \\ []) do
    {id, counter, opts} = launch(context, suffix)
    opts = opts |> Keyword.put(:admission_wait_ms, 1) |> Keyword.merge(extra)
    assert {:queued, ^id} = ProcessManager.exec(opts)
    assert {:ok, %{classification: :queued}} = ProcessManager.receipt(id, "admission-test")
    {id, counter, opts}
  end

  defp accept_queued(id) do
    session = boundary(id)
    send(session, :release_start)
    assert {:ok, _} = ProcessSession.get_state(id)
    assert {:ok, %{classification: :accepted}} = ProcessManager.receipt(id, "admission-test")
    session
  end

  defp unknown_launch(context, suffix) do
    {id, counter, opts} = launch(context, suffix)
    fifo = Path.join(context.directory, "#{suffix}.exit.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    parent = self()

    observer =
      spawn(fn ->
        # The OS reader avoids file_server_2. The fixture never closes fd 3
        # explicitly, so EOF confirms external termination independently.
        assert {"", 0} = System.cmd("cat", [fifo])
        send(parent, {:external_exited, id})

        receive do
          {:confirm_exit, cleanup} -> send(cleanup, {:exit_confirmed, id})
        end
      end)

    on_exit(fn ->
      case Registry.lookup(CodingAgent.ProcessRegistry, id) do
        [{pid, _}] ->
          send(pid, :release_start)

          try do
            ProcessSession.kill(id, :sigkill)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      # Finish the OS observer even if the test failed before the shell opened
      # fd 3. An existing shell writer must still close before cat observes EOF.
      {:ok, unblock} = File.open(fifo, [:read, :write])
      File.close(unblock)

      ref = Process.monitor(observer)
      send(observer, {:confirm_exit, self()})
      assert_receive {:exit_confirmed, ^id}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^observer, :normal}, 5_000

      case ProcessManager.receipt(id, "admission-test") do
        {:ok, %{classification: :outcome_unknown}} ->
          assert :ok = ProcessManager.confirm_external_termination(id, "admission-test")

        _ ->
          :ok
      end

      assert :ok = ProcessManager.clear(id)
    end)

    {id, counter, Keyword.put(opts, :command, "exec 3> '#{fifo}'; " <> opts[:command])}
  end

  test "lost queue reply reconciles the fixed identity without another external start", context do
    {id, counter, opts} = launch(context, "lost-reply")
    caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    session = boundary(id)

    assert :ok = stop_supervised(LaneQueue)
    assert {:ok, ^id} = Task.await(caller)

    assert {:ok, %{identity: ^id, classification: :accepted}} =
             ProcessManager.receipt(id, "admission-test")

    assert {:ok, ^id} = ProcessManager.exec(opts)
    assert File.read!(counter) == "x"
    send(session, :release_start)
    assert {:ok, _} = ProcessSession.get_state(id)
    terminate(id)
  end

  test "concurrent same-identity requests start once and conflicts stay owner-scoped", context do
    {id, counter, opts} = launch(context, "dedupe")
    first = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    session = boundary(id)

    retries =
      for _ <- 1..8 do
        Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
      end

    for retry <- retries, do: assert({:ok, ^id} = Task.await(retry))

    for changed <- [Keyword.put(opts, :command, "true"), Keyword.put(opts, :owner, "foreign")] do
      assert {:error, {:rejected, ^id, :identity_conflict}} = ProcessManager.exec(changed)
    end

    assert {:error, :not_found} = ProcessManager.receipt(id, "foreign")
    assert File.read!(counter) == "x"
    send(session, :release_start)
    assert {:ok, ^id} = Task.await(first)
    terminate(id)

    # Reissuing the identical command intentionally allocates a fresh identity.
    parent = self()
    fifo = Path.join(context.directory, "dedupe.fifo")

    reader =
      spawn(fn ->
        assert {"started\n", 0} = System.cmd("cat", [fifo])
        send(parent, :second_external_started)
      end)

    on_exit(fn ->
      ref = Process.monitor(reader)

      if Process.alive?(reader) do
        {:ok, unblock} = File.open(fifo, [:read, :write])
        File.close(unblock)
      end

      # Cleanup only requires closure; an already-finished reader is :noproc.
      assert_receive {:DOWN, ^ref, :process, ^reader, _}, 5_000
    end)

    second =
      Task.Supervisor.async_nolink(context.task_sup, fn ->
        ProcessManager.exec(Keyword.delete(opts, :launch_id))
      end)

    assert_receive {:start_boundary, second_id, second_session}, 5_000
    assert_receive :second_external_started, 5_000
    refute second_id == id
    send(second_session, :release_start)
    assert {:ok, ^second_id} = Task.await(second)
    assert File.read!(counter) == "xx"
    terminate(second_id)
  end

  test "accepted caller death does not relaunch and terminal receipts survive clear", context do
    {id, counter, opts} = launch(context, "caller-death")
    caller = spawn(fn -> ProcessManager.exec(opts) end)
    ref = Process.monitor(caller)
    session = boundary(id)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    assert {:ok, ^id} = ProcessManager.exec(opts)
    send(session, :release_start)
    assert {:ok, _} = ProcessSession.get_state(id)
    terminate(id)
    assert :ok = ProcessManager.clear(id)
    assert {:error, :not_found} = ProcessStore.get(id)
    assert {:ok, ^id} = ProcessManager.exec(opts)

    assert {:ok, %{classification: :accepted, status: :killed}} =
             ProcessManager.receipt(id, "admission-test")

    assert File.read!(counter) == "x"
  end

  test "start-owner loss remains unknown through queue recovery and cannot rerun effects",
       context do
    {id, counter, opts} = unknown_launch(context, "unknown")
    caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    session = boundary(id)
    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    assert_receive {:external_exited, ^id}, 5_000

    assert {:error, {:outcome_unknown, ^id}} = Task.await(caller)

    assert {:ok, %{classification: :outcome_unknown}} =
             ProcessManager.receipt(id, "admission-test")

    assert :ok = stop_supervised(LaneQueue)

    queue =
      start_supervised!(
        {LaneQueue,
         name: __MODULE__.Queue, caps: %{background_exec: 2}, task_supervisor: context.task_sup}
      )

    assert {:error, {:outcome_unknown, ^id}} =
             ProcessManager.exec(Keyword.put(opts, :lane_queue, queue))

    assert :ok = ProcessStore.cleanup(0)

    assert {:ok, %{classification: :outcome_unknown}} =
             ProcessManager.receipt(id, "admission-test")

    assert File.read!(counter) == "x"
  end

  test "live process cap is held after handles return and while cancellation is unconfirmed",
       context do
    {a, _, _, _} = start_blocking(context, "cap-a")
    {b, _, _, _} = start_blocking(context, "cap-b")
    {c, counter, _} = enqueue(context, "cap-c")

    assert ProcessManager.admission_counts().occupied == 2
    refute File.exists?(counter)
    assert :ok = ProcessManager.kill(a, :sigterm)
    assert {:ok, %{status: :killing}} = ProcessManager.poll(a, lines: 0)
    assert ProcessManager.admission_counts().occupied == 2
    assert {:ok, %{classification: :queued}} = ProcessManager.receipt(c, "admission-test")
    refute File.exists?(counter)

    terminate(a)
    accept_queued(c)
    assert File.read!(counter) == "x"
    assert ProcessManager.admission_counts().occupied == 2
    terminate(b)
    terminate(c)
  end

  test "a root exit cannot free capacity while its TERM-ignoring child still owns the group",
       context do
    for mode <- [:sigterm, :natural] do
      suffix = "surviving-child-#{mode}"
      {id, counter, opts} = launch(context, suffix)
      ready_fifo = Path.join(context.directory, "#{suffix}.fifo")
      release_fifo = Path.join(context.directory, "#{suffix}.release.fifo")
      {_, 0} = System.cmd("mkfifo", [release_fifo])
      parent = self()

      release_child = fn ->
        # O_RDWR also makes failure cleanup finite if no child was started.
        {:ok, unblock} = File.open(release_fifo, [:read, :write])

        {_, 0} =
          System.cmd("/bin/sh", [
            "-c",
            "printf 'release\\n' > \"$1\"",
            "lemon-fixture",
            release_fifo
          ])

        File.close(unblock)
      end

      on_exit(release_child)

      command =
        "trap 'exit 0' TERM; " <>
          "(trap '' TERM; printf x >> '#{counter}'; " <>
          "printf 'started\\n' > '#{ready_fifo}'; read -r release < '#{release_fifo}') " <>
          "</dev/null >/dev/null 2>&1 & read -r release"

      opts =
        opts
        |> Keyword.put(:command, command)
        |> Keyword.put(:on_root_exit, fn identity -> send(parent, {:root_exited, identity}) end)

      caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
      session = boundary(id)
      send(session, :release_start)
      assert {:ok, ^id} = Task.await(caller)
      {b, _, _, _} = start_blocking(context, "#{suffix}-other")
      {c, queued_counter, _} = enqueue(context, "#{suffix}-queued")

      case mode do
        :sigterm -> assert :ok = ProcessManager.kill(id, :sigterm)
        :natural -> assert :ok = ProcessManager.write(id, "release\n")
      end

      # This barrier is after the real Port exit and store reconciliation, not
      # a timing guess or a fabricated child-termination event.
      assert_receive {:root_exited, ^id}, 5_000

      assert {:ok, %{status: :lost, root_exited: true, capacity_held: true}, _} =
               ProcessStore.get(id)

      assert {:ok, %{classification: :outcome_unknown}} =
               ProcessManager.receipt(id, "admission-test")

      assert ProcessManager.admission_counts().occupied == 2
      refute File.exists?(queued_counter)
      assert File.read!(counter) == "x"

      {d, rejected_counter, rejected_opts} = launch(context, "#{suffix}-overflow")
      assert {:error, {:rejected, ^d, :overloaded}} = ProcessManager.exec(rejected_opts)
      refute File.exists?(rejected_counter)

      # Both natural and signaled root exits must retain a publicly cancellable
      # owned group. The fixture FIFO is failure cleanup only, not the repair.
      terminate(id)

      accept_queued(c)
      assert File.read!(queued_counter) == "x"
      assert ProcessManager.admission_counts().occupied == 2
      assert :ok = ProcessStore.confirm_termination(id)
      send(session, :reconcile_workload)
      assert ProcessManager.admission_counts().occupied == 2
      terminate(b)
      terminate(c)
      assert ProcessManager.admission_counts().occupied == 0
    end
  end

  test "lost group ownership cannot signal a recycled identity or release its charge", context do
    parent = self()

    {id, counter, _, session} =
      start_blocking(context, "lost-group-identity",
        on_root_exit: fn identity -> send(parent, {:root_exited, identity}) end
      )

    assert {:ok, state} = ProcessSession.get_state(id)
    original_identity = state.workload_identity
    # Fault-inject the stale ownership evidence, not an actual reused system PID.
    stale_identity = %{original_identity | root_birth: "another workload"}
    :sys.replace_state(session, &%{&1 | workload_identity: stale_identity})
    assert {:error, {:outcome_unknown, ^id}} = ProcessManager.kill(id, :sigkill)
    assert {:alive, _} = CodingAgent.BashExecutor.workload_group_status(original_identity)
    assert File.read!(counter) == "x"
    assert ProcessManager.admission_counts().occupied == 1
    assert {:ok, %{workload_identity: %{ownership_lost: true}}, _} = ProcessStore.get(id)

    # Only independently retained, matching ownership evidence can clean up.
    assert {:ok, _} = CodingAgent.BashExecutor.signal_workload_group(original_identity, :sigkill)
    assert_receive {:root_exited, ^id}, 5_000
    assert :terminated = CodingAgent.BashExecutor.workload_group_status(original_identity, true)
    assert ProcessManager.admission_counts().occupied == 1
    assert :ok = ProcessManager.confirm_external_termination(id, "admission-test")
    assert ProcessManager.admission_counts().occupied == 0

    assert {:ok, %{classification: :outcome_unknown}} =
             ProcessManager.receipt(id, "admission-test")
  end

  test "pending overflow is rejected promptly without an external start or queue growth",
       context do
    {a, _, _, _} = start_blocking(context, "overflow-a")
    {b, _, _, _} = start_blocking(context, "overflow-b")
    {c, _, _} = enqueue(context, "overflow-c")
    {d, counter, opts} = launch(context, "overflow-d")

    assert {:error, {:rejected, ^d, :overloaded}} = ProcessManager.exec(opts)
    assert :queue.len(GenServer.call(context.queue, :status).lanes.background_exec.q) == 1
    assert %{active: 2, queued: 1, rejected: 1, occupied: 2} = ProcessManager.admission_counts()
    refute File.exists?(counter)
    assert :ok = ProcessManager.cancel(c, "admission-test")
    terminate(a)
    terminate(b)
    refute File.exists?(counter)
  end

  test "queued cancellation, expiry and abandoned callers can never start after capacity frees",
       context do
    {a, _, _, _} = start_blocking(context, "waiting-a")
    {b, _, _, _} = start_blocking(context, "waiting-b")
    assert :ok = ProcessStore.subscribe_capacity(self())

    {c, canceled_counter, _} = enqueue(context, "waiting-canceled")
    assert :ok = ProcessManager.kill(c, :sigkill)
    send(context.queue, {:background_launch_canceled, c})
    assert GenServer.call(context.queue, :status).jobs_count == 0
    assert {:ok, %{classification: :canceled}} = ProcessManager.receipt(c, "admission-test")

    {d, expired_counter, _} = enqueue(context, "waiting-expired")
    # Inject the deadline event after the queued barrier; no elapsed-time guess.
    send(CodingAgent.ProcessStoreServer, {:pending_launch_deadline, d})
    assert_receive {:background_launch_classified, ^d, :expired}, 5_000
    assert GenServer.call(context.queue, :status).jobs_count == 0

    {e, abandoned_counter, opts} = launch(context, "waiting-abandoned")
    parent = self()

    caller =
      spawn(fn ->
        result = ProcessManager.exec(Keyword.put(opts, :admission_wait_ms, 1))
        send(parent, {:waiting_receipt, result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:waiting_receipt, {:queued, ^e}}, 5_000
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert_receive {:background_launch_canceled, ^e}, 5_000
    send(context.queue, {:background_launch_canceled, e})
    assert GenServer.call(context.queue, :status).jobs_count == 0

    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {f, owner_counter, _} = enqueue(context, "waiting-owner", owner_pid: owner)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert_receive {:background_launch_canceled, ^f}, 5_000
    send(context.queue, {:background_launch_canceled, f})
    assert GenServer.call(context.queue, :status).jobs_count == 0

    terminate(a)
    terminate(b)

    for counter <- [canceled_counter, expired_counter, abandoned_counter, owner_counter],
        do: refute(File.exists?(counter))

    assert %{queued: 0, canceled: 3, expired: 1, occupied: 0} = ProcessManager.admission_counts()
  end

  test "confirmed completion, startup failure and owner death release once despite late events",
       context do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    {a, _, _, session} = start_blocking(context, "release-a")
    {b, _, _, _} = start_blocking(context, "release-b", owner_pid: owner)
    {c, _, _} = enqueue(context, "release-c")
    assert {:ok, state} = ProcessSession.get_state(a)
    assert :ok = ProcessManager.write(a, "release\n")
    assert_receive {:external_terminated, ^a}, 5_000
    accept_queued(c)

    for _ <- 1..3, do: send(session, {state.port, {:exit_status, 0}})
    assert {:ok, %{status: :completed}} = ProcessSession.get_state(a)
    assert :ok = ProcessStore.confirm_termination(a)
    assert ProcessManager.admission_counts().occupied == 2

    {d, counter, _} = enqueue(context, "release-d")
    refute File.exists?(counter)
    assert :ok = ProcessManager.cancel(d, "admission-test")
    send(context.queue, {:background_launch_canceled, d})
    GenServer.call(context.queue, :status)
    terminate(c)

    failed = "startup-failed-#{System.unique_integer([:positive])}"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:rejected, ^failed, :startup_failed}} =
                 ProcessManager.exec(
                   command: "true",
                   launch_id: failed,
                   lane_queue: context.queue,
                   before_start: fn -> raise "private startup fixture" end
                 )
      end)

    refute log =~ "private startup fixture"
    assert ProcessManager.admission_counts().occupied == 1
    assert :ok = ProcessStore.confirm_termination(failed, :startup_failed)
    assert ProcessManager.admission_counts().occupied == 1

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert_receive {:external_terminated, ^b}, 5_000
    assert ProcessManager.admission_counts().occupied == 0
  end

  test "queue and store restart reconcile surviving and unknown processes before admitting",
       context do
    {a, counter, opts} = unknown_launch(context, "restart-a")
    caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    session = boundary(a)
    send(session, :release_start)
    assert {:ok, ^a} = Task.await(caller)
    {b, _, _, _} = start_blocking(context, "restart-b")
    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    assert_receive {:external_exited, ^a}, 5_000

    assert {:ok, %{classification: :outcome_unknown}} =
             ProcessManager.receipt(a, "admission-test")

    assert {:error, :process_not_terminal} = ProcessStore.delete(a)

    assert :ok = stop_supervised(LaneQueue)

    assert :ok =
             Supervisor.terminate_child(CodingAgent.Supervisor, CodingAgent.ProcessStoreServer)

    assert {:ok, _} =
             Supervisor.restart_child(CodingAgent.Supervisor, CodingAgent.ProcessStoreServer)

    queue =
      start_supervised!(
        {LaneQueue,
         name: __MODULE__.Queue,
         caps: %{background_exec: 2},
         background_pending_limit: 1,
         task_supervisor: context.task_sup}
      )

    recovered = %{context | queue: queue}
    {c, waiting_counter, _} = enqueue(recovered, "restart-c")
    assert %{occupied: 2, unknown: 1, queued: 1} = ProcessManager.admission_counts()

    assert {:error, {:outcome_unknown, ^a}} =
             ProcessManager.exec(Keyword.put(opts, :lane_queue, queue))

    refute File.exists?(waiting_counter)
    assert File.read!(counter) == "x"
    assert :ok = ProcessManager.cancel(c, "admission-test")
    terminate(b)
  end

  test "long-running owned process remains inspectable and cancellable after caller yield",
       context do
    {a, _, _, _} = start_blocking(context, "yield-a")
    {b, _, _, _} = start_blocking(context, "yield-b")
    {id, counter, opts} = launch(context, "yield")
    opts = Keyword.merge(opts, owner_pid: self(), admission_wait_ms: 1)
    caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    assert {:queued, ^id} = Task.await(caller)
    assert {:ok, %{classification: :queued}} = ProcessManager.receipt(id, "admission-test")
    refute File.exists?(counter)

    terminate(a)
    accept_queued(id)
    assert {:ok, %{status: :running}} = ProcessManager.poll(id, lines: 0)
    assert ProcessManager.admission_counts().occupied == 2
    assert File.read!(counter) == "x"
    assert {:ok, ^id} = ProcessManager.exec(opts)
    terminate(id)
    terminate(b)
    assert ProcessManager.admission_counts().occupied == 0
  end

  test "invalid background limits fail explicitly while unrelated lanes keep callback semantics",
       context do
    for {key, value} <- [
          background_process_limit: 0,
          background_pending_limit: -1,
          background_admission_timeout_ms: :infinity,
          background_admission_wait_ms: "secret-invalid-value"
        ] do
      opts = [
        {key, value},
        name: __MODULE__.Invalid,
        caps: %{main: 1},
        task_supervisor: context.task_sup
      ]

      for starter <- [&LaneQueue.start_link/1, &CodingAgent.ProcessStoreServer.start_link/1] do
        result =
          Task.Supervisor.async_nolink(context.task_sup, fn ->
            # A rejected start may also send EXIT to its linked caller. Isolate
            # that startup protocol without changing the lane consumer's flags.
            Process.flag(:trap_exit, true)
            starter.(opts)
          end)

        assert {:error, {:invalid_background_limit, ^key}} = Task.await(result)
      end
    end

    assert {:ok, :callback_finished} =
             LaneQueue.run(context.queue, :main, fn -> :callback_finished end)

    assert {:ok, :next_callback} = LaneQueue.run(context.queue, :main, fn -> :next_callback end)
  end
end
