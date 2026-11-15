defmodule CodingAgent.Tools.BashManagedNotificationsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ProcessManager, ProcessSession, ProcessStore}
  alias CodingAgent.Tools.Bash.Managed

  @tag :tmp_dir
  test "foreground output changes wake the attachment before the command exits", %{tmp_dir: cwd} do
    parent = self()
    owner = "managed-notifications-#{System.unique_integer([:positive])}"

    worker =
      Task.async(fn ->
        receive do
          :start ->
            Managed.execute(
              "printf 'ready\\n'; read first; printf 'changed\\n'; read second; printf 'done\\n'",
              cwd,
              timeout: 60_000,
              env: %{},
              session_id: owner,
              session_pid: parent,
              on_chunk: fn chunk -> send(parent, {:output, chunk}) end
            )
        end
      end)

    :erlang.trace(worker.pid, true, [:running])
    send(worker.pid, :start)
    assert_receive {:output, "ready\n"}, 5_000

    [{id, _record}] =
      Enum.filter(ProcessStore.list(), fn {_id, record} -> record.owner == owner end)

    on_exit(fn ->
      ProcessManager.kill(id)
      ProcessSession.stop(id)
      ProcessStore.delete(id)
    end)

    # Stdin gates each output wave. Neither shell sleeps nor refresh timers can
    # manufacture the second callback while the process is blocked on its input.
    assert_receive {:trace, pid, :out, {Managed, :wait_for_output, 4}}, 2_000
    assert pid == worker.pid
    :erlang.trace(worker.pid, false, [:running])
    assert :ok = ProcessManager.write(id, "first\n")
    assert_receive {:output, "changed\n"}, 2_000
    assert {:ok, %{status: :running}, _logs} = ProcessStore.get(id)

    assert :ok = ProcessManager.write(id, "second\n")
    assert {:ok, result} = Task.await(worker, 5_000)
    assert result.exit_code == 0
    assert result.output == "ready\nchanged\ndone\n"
  end
end
