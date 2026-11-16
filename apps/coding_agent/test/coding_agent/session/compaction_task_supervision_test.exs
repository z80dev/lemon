defmodule CodingAgent.Session.CompactionTaskSupervisionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.CompactionManager

  test "missing supervisor rejects compaction without running an unsupervised fallback" do
    observer = self()

    assert {:error, :task_supervisor_unavailable} =
             CompactionManager.start_background_task(
               fn -> send(observer, :unexpected_compaction) end,
               __MODULE__.MissingSupervisor
             )

    refute_received :unexpected_compaction
  end

  test "a full supervisor rejects compaction and leaves its existing worker owned" do
    supervisor = start_supervised!({Task.Supervisor, max_children: 1})
    observer = self()

    assert {:ok, worker} =
             CompactionManager.start_background_task(
               fn ->
                 send(observer, {:compaction_started, self()})

                 receive do
                   :finish -> :ok
                 end
               end,
               supervisor
             )

    assert_receive {:compaction_started, ^worker}

    assert {:error, :task_capacity_reached} =
             CompactionManager.start_background_task(
               fn -> send(observer, :unexpected_compaction) end,
               supervisor
             )

    assert [^worker] = Task.Supervisor.children(supervisor)
    refute_received :unexpected_compaction
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end
end
