defmodule CodingAgent.LaneQueueTest do
  use ExUnit.Case, async: true

  alias CodingAgent.LaneQueue

  setup do
    {:ok, sup} = Task.Supervisor.start_link()
    %{task_sup: sup}
  end

  test "accepts caps as a map", %{task_sup: sup} do
    {:ok, pid} = LaneQueue.start_link(name: :lane_queue_map, caps: %{main: 2}, task_supervisor: sup)

    assert {:ok, 4} = LaneQueue.run(pid, :main, fn -> 4 end)
  end

  test "accepts caps as a keyword list", %{task_sup: sup} do
    {:ok, pid} = LaneQueue.start_link(name: :lane_queue_kw, caps: [main: 2, subagent: 1], task_supervisor: sup)

    assert {:ok, :ok} = LaneQueue.run(pid, :subagent, fn -> :ok end)
  end

  test "defaults to cap 1 for unknown lane", %{task_sup: sup} do
    {:ok, pid} = LaneQueue.start_link(name: :lane_queue_default, caps: [main: 1], task_supervisor: sup)

    results =
      1..2
      |> Task.async_stream(fn _ ->
        LaneQueue.run(pid, :unknown, fn ->
          Process.sleep(50)
          :done
        end)
      end, timeout: 5_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == {:ok, :done}))
  end
end
