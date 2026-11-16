defmodule LemonCore.TaskSupervisorTest do
  use ExUnit.Case, async: true

  alias LemonCore.TaskSupervisor

  test "real supervisor capacity is mapped without executing rejected work" do
    supervisor = start_supervised!(TaskSupervisor.child_spec(max_children: 1))
    owner = self()

    assert {:ok, blocker} =
             TaskSupervisor.start_child(supervisor, fn ->
               send(owner, {:occupied, self()})

               receive do
                 :release -> :ok
               end
             end)

    assert_receive {:occupied, ^blocker}
    rejected = fn -> send(owner, :rejected_work_ran) end
    assert {:error, :max_children} = Task.Supervisor.start_child(supervisor, rejected)
    assert {:error, :task_capacity_reached} = TaskSupervisor.start_child(supervisor, rejected)
    assert {:error, :task_capacity_reached} = TaskSupervisor.async(supervisor, rejected)
    assert {:error, :task_capacity_reached} = TaskSupervisor.async_nolink(supervisor, rejected)
    refute_received :rejected_work_ran
  end

  test "missing supervisor admission is mapped" do
    supervisor = start_supervised!(TaskSupervisor.child_spec(max_children: 1))
    :ok = stop_supervised(Task.Supervisor)

    assert {:error, :task_supervisor_unavailable} =
             TaskSupervisor.start_child(supervisor, fn -> :ok end)

    assert {:error, :task_supervisor_unavailable} =
             TaskSupervisor.async(supervisor, fn -> :ok end)

    assert {:error, :task_supervisor_unavailable} =
             TaskSupervisor.async_nolink(supervisor, fn -> :ok end)
  end

  test "explicit caller cap is retained" do
    assert %{start: {Task.Supervisor, :start_link, [opts]}} =
             TaskSupervisor.child_spec(max_children: 7)

    assert opts[:max_children] == 7
  end
end
