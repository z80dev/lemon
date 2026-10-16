defmodule CodingAgent.Tools.BashCaptureTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias CodingAgent.{LaneQueue, ProcessManager, ProcessStore}
  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.Capture

  @moduletag :tmp_dir

  test "capture uses private random directories and precreated owner-only regular files", %{
    tmp_dir: ws
  } do
    first = Capture.start()
    second = Capture.start()

    on_exit(fn ->
      File.rm_rf(first.path)
      File.rm_rf(second.path)
    end)

    refute first.path == second.path
    assert Regex.match?(~r/\Alemon-shell-[A-Za-z0-9_-]{32}\z/, Path.basename(first.path))
    assert band(File.stat!(first.path).mode, 0o777) == 0o700

    for path <- [first.cwd, first.env, second.cwd, second.env] do
      assert File.lstat!(path).type == :regular
      assert band(File.stat!(path).mode, 0o777) == 0o600
    end

    # A preexisting legacy capture symlink cannot redirect the new channel.
    target = Path.join(ws, "target")
    File.write!(target, "unchanged")
    legacy = Path.join(System.tmp_dir!(), "lemon-shell-#{System.unique_integer([:positive])}.env")
    File.ln_s!(target, legacy)
    on_exit(fn -> File.rm(legacy) end)
    refute first.env == legacy
    File.write!(first.env, "private")
    assert File.read!(target) == "unchanged"

    Capture.finish(first)
    Capture.finish(second)
    eventually(fn -> not File.exists?(first.path) and not File.exists?(second.path) end)
  end

  test "detached command retains cleanup until its actual exit", %{tmp_dir: ws} do
    trap_file = Path.join(ws, "trap")
    marker = Path.join(ws, "exited")

    tool =
      Bash.tool(ws,
        session_id: "capture-#{System.unique_integer([:positive])}",
        session_pid: self()
      )

    release = Path.join(ws, "release")

    result =
      tool.execute.(
        "detach",
        %{
          "command" =>
            "trap -p EXIT > '#{trap_file}'; while [ ! -f '#{release}' ]; do sleep 0.02; done; export LEMON_CAPTURE_SECRET=secret; touch '#{marker}'",
          "timeout" => 100
        },
        nil,
        nil
      )

    assert result.details.timed_out
    on_exit(fn -> CodingAgent.ProcessManager.kill(result.details.process_id) end)
    pattern = ~r/(lemon-shell-[A-Za-z0-9_-]{32})\/cwd/

    eventually(fn ->
      case File.read(trap_file) do
        {:ok, text} -> Regex.match?(pattern, text)
        _ -> false
      end
    end)

    [_, directory] = Regex.run(pattern, File.read!(trap_file))
    path = Path.join(System.tmp_dir!(), directory)

    assert File.dir?(path)
    assert band(File.stat!(Path.join(path, "env")).mode, 0o777) == 0o600
    File.touch!(release)
    eventually(fn -> File.exists?(marker) and not File.exists?(path) end)
  end

  for status <- [:expired, :canceled, :rejected] do
    @terminal_status status
    test "detached queued foreground capture is removed when admission is #{@terminal_status}",
         %{tmp_dir: ws} do
      status = @terminal_status
      task_sup = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

      queue =
        start_supervised!(
          {LaneQueue,
           name: __MODULE__.Queue,
           caps: %{background_exec: 1},
           background_pending_limit: 1,
           task_supervisor: task_sup}
        )

      parent = self()

      blocker =
        Task.Supervisor.async_nolink(task_sup, fn ->
          LaneQueue.run(queue, :background_exec, fn ->
            send(parent, {:lane_blocked, self()})
            receive do: (:release -> :released)
          end)
        end)

      assert_receive {:lane_blocked, blocking_task}, 1_000
      on_exit(fn -> send(blocking_task, :release) end)

      id = "capture-queued-#{System.unique_integer([:positive])}"
      marker = Path.join(ws, "unexpected-start")
      capture = Capture.start()
      guard_ref = Process.monitor(capture.guard)

      on_exit(fn ->
        ProcessManager.cancel(id, "capture-test")
        ProcessManager.clear(id)
        Capture.finish(capture)
        File.rm_rf(capture.path)
      end)

      assert {:queued, ^id} =
               ProcessManager.exec_sync(
                 command: "touch '#{marker}'",
                 cwd: ws,
                 launch_id: id,
                 owner: "capture-test",
                 owner_pid: self(),
                 lane_queue: queue,
                 admission_wait_ms: 1,
                 admission_timeout_ms: 60_000
               )

      assert {:ok, %{status: :queued}} = ProcessManager.poll(id, lines: 0)
      Capture.detach(capture, id)
      assert File.dir?(capture.path)
      assert Process.alive?(capture.guard)

      terminate_admission(status, id)

      assert_receive {:DOWN, ^guard_ref, :process, _, :normal}, 1_000
      refute File.exists?(capture.path)
      refute File.exists?(marker)
      # Cleanup must not depend on eviction of the terminal launch record.
      assert {:ok, %{status: ^status}, _logs} = ProcessStore.get(id)
      assert {:ok, %{status: ^status}} = ProcessManager.poll(id, lines: 0)
      send(blocking_task, :release)
      assert {:ok, :released} = Task.await(blocker)
    end
  end

  test "caller death removes capture and prevents late redirection", %{tmp_dir: ws} do
    parent = self()

    owner =
      spawn(fn ->
        capture = Capture.start()
        send(parent, {:capture, capture})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive {:capture, capture}
    Process.exit(owner, :kill)
    eventually(fn -> not File.exists?(capture.path) end)
    assert {:error, :enoent} = File.write(capture.env, "late secret")
    refute File.exists?(capture.path)
    assert File.dir?(ws)
  end

  defp terminate_admission(status, id) do
    case status do
      :expired ->
        # Drive the real deadline handler after the queued admission barrier.
        send(CodingAgent.ProcessStoreServer, {:pending_launch_deadline, id})

      :canceled ->
        assert :ok = ProcessManager.cancel(id, "capture-test")

      :rejected ->
        ProcessStore.classify_launch(id, :rejected, :admission_failed)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
