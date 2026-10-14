defmodule CodingAgent.ProcessAdmissionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{LaneQueue, ProcessManager, ProcessSession, ProcessStore}

  setup do
    task_sup = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

    queue =
      start_supervised!(
        {LaneQueue,
         name: __MODULE__.Queue,
         caps: %{background_exec: 2, main: 1},
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
          {:ok, %{os_pid: os_pid}, _} when is_integer(os_pid) ->
            CodingAgent.BashExecutor.kill_process_tree(os_pid)

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

    reader = spawn(fn ->
      {:ok, file} = File.open(fifo, [:read])
      assert IO.read(file, :line) == "started\n"
      File.close(file)
      send(test, {:external_started, id})
    end)

    on_exit(fn -> if Process.alive?(reader), do: Process.exit(reader, :kill) end)

    opts = [
      command: "printf x >> '#{counter}'; printf 'started\\n' > '#{fifo}'; cat",
      launch_id: id,
      owner: "admission-test",
      lane_queue: context.queue,
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

  test "start-owner loss remains unknown through queue recovery and cannot rerun effects", context do
    {id, counter, opts} = launch(context, "unknown")
    caller = Task.Supervisor.async_nolink(context.task_sup, fn -> ProcessManager.exec(opts) end)
    session = boundary(id)
    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :killed}

    assert {:error, {:outcome_unknown, ^id}} = Task.await(caller)
    assert {:ok, %{classification: :outcome_unknown}} =
             ProcessManager.receipt(id, "admission-test")

    assert :ok = stop_supervised(LaneQueue)
    queue = start_supervised!({LaneQueue,
      name: __MODULE__.Queue, caps: %{background_exec: 2}, task_supervisor: context.task_sup})
    assert {:error, {:outcome_unknown, ^id}} = ProcessManager.exec(Keyword.put(opts, :lane_queue, queue))
    assert :ok = ProcessStore.cleanup(0)
    assert {:ok, %{classification: :outcome_unknown}} =
             ProcessManager.receipt(id, "admission-test")
    assert File.read!(counter) == "x"
  end
end
