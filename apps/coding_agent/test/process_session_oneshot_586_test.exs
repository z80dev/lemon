defmodule CodingAgent.ProcessSessionOneshot586Test do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessSession

  test "one-shot owner relays output and exits after the root exit event" do
    shell = System.find_executable("sh") || "/bin/sh"

    {port, _os_pid, owner} =
      ProcessSession.start_oneshot(
        shell,
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-c", "printf ready; read line; printf done"]}
        ]
      )

    monitor = Process.monitor(owner)
    on_exit(fn -> ProcessSession.stop_oneshot(owner) end)

    assert_receive {^port, {:data, "ready"}}, 5_000
    assert %{mode: :oneshot, owner: caller} = :sys.get_state(owner)
    assert caller == self()
    assert Port.command(port, "finish\n")
    assert_receive {^port, {:data, "done"}}, 5_000
    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
  end

  test "a killed caller cannot leave its one-shot workload running" do
    parent = self()

    caller =
      spawn(fn ->
        {port, os_pid, owner} =
          ProcessSession.start_oneshot(
            "/bin/sh",
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, ["-c", "printf ready; read line"]}
            ]
          )

        receive do
          {^port, {:data, "ready"}} -> send(parent, {:ready, owner, os_pid})
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:ready, owner, os_pid}, 5_000
    monitor = Process.monitor(owner)
    {:ok, identity} = LemonCore.ProcessGroup.capture_workload_group(os_pid)
    on_exit(fn -> ProcessSession.stop_oneshot(owner) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    assert :terminated = LemonCore.ProcessGroup.workload_group_status(identity, true)
  end

  test "workload reconciliation has no periodic scan timer" do
    source = File.read!(Path.expand("../lib/coding_agent/process_session.ex", __DIR__))
    refute source =~ ":reconcile_workload"
    refute source =~ ":kill_after_grace"
  end
end
