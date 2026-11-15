defmodule LemonAutomation.CronCommandRunnerTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronCommandRunner, CronJob, CronRun}
  alias LemonCore.ProcessGroup

  test "successful commands retain bounded output and nonzero exits retain their status" do
    assert {:ok, "cron-ok"} = submit("printf cron-ok")
    assert {:error, "Command exited 7: failed"} = submit("printf failed; exit 7")

    assert {:ok, output} = submit("printf '%13000s' x")
    assert byte_size(output) == 12_000 + byte_size("\n[output truncated]")
    assert String.ends_with?(output, "\n[output truncated]")
  end

  test "timeout kills a ready grandchild that ignores stdin EOF and SIGTERM" do
    # Both ancestors remain alive in wait. The grandchild installs its signal
    # disposition before announcing readiness, then runs without reading stdin.
    command = ~S"""
    /bin/sh -c '
      /bin/sh -c '\''
        trap "" TERM
        printf "READY %s\n" "$$"
        exec sleep 60 </dev/null
      '\'' &
      wait
    ' &
    wait
    """

    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run -> send(parent, {:result, self(), submit(command, 5_000)})
        end
      end)

    on_exit(fn ->
      # Also clean up if fixture readiness fails, before the runner returns a PID.
      for port <- Port.list(), Port.info(port, :connected) == {:connected, worker} do
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> ProcessGroup.terminate(pid, grace_ms: 0)
          nil -> :ok
        end
      end

      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    :erlang.trace(worker, true, [:receive])
    send(worker, :run)
    {port, grandchild} = await_ready(worker, "", System.monotonic_time(:millisecond) + 5_000)
    {:os_pid, root} = Port.info(port, :os_pid)
    assert {:ok, identity} = ProcessGroup.capture_workload_group(root)

    on_exit(fn ->
      case ProcessGroup.workload_group_status(identity) do
        {:alive, observed} -> ProcessGroup.terminate(observed.pgid, grace_ms: 0)
        _ -> :ok
      end
    end)

    assert map_size(identity.members) >= 3
    assert Map.has_key?(identity.members, grandchild)
    assert_receive {:result, ^worker, :timeout}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    assert ProcessGroup.workload_group_status(identity, true) == :terminated
  end

  defp submit(command, timeout_ms \\ 5_000) do
    job = %CronJob{
      id: "command-test",
      name: "Command test",
      schedule: "* * * * *",
      command: command,
      timeout_ms: timeout_ms
    }

    run = %CronRun{id: "command-run-test", job_id: job.id, status: :running}
    CronCommandRunner.submit(job, run)
  end

  defp await_ready(worker, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:trace, ^worker, :receive, {port, {:data, data}}} ->
        output = output <> data

        case Regex.run(~r/READY (\d+)\n/, output) do
          [_, pid] -> {port, String.to_integer(pid)}
          nil -> await_ready(worker, output, deadline)
        end
    after
      remaining -> flunk("cron grandchild did not announce readiness through its port")
    end
  end
end
