defmodule LemonAutomation.RunCompletionWaiterTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.RunCompletionWaiter

  defmodule TestBus do
    @moduledoc false

    def subscribe(topic) do
      if pid = Process.get(:run_completion_waiter_test_pid) do
        send(pid, {:bus_subscribed, topic})
      end

      :ok
    end

    def unsubscribe(topic) do
      if pid = Process.get(:run_completion_waiter_test_pid) do
        send(pid, {:bus_unsubscribed, topic})
      end

      :ok
    end
  end

  test "wait/3 subscribes, extracts completion output, and unsubscribes" do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:run_completion_waiter_test_pid, parent)
        RunCompletionWaiter.wait("run_waiter_ok", 1_000, bus_mod: TestBus)
      end)

    assert_receive {:bus_subscribed, "run:run_waiter_ok"}, 500

    send(
      task.pid,
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "Hello from waiter"}})
    )

    assert {:ok, "Hello from waiter"} = Task.await(task, 2_000)
    assert_receive {:bus_unsubscribed, "run:run_waiter_ok"}, 500
  end

  test "wait/3 returns :timeout and unsubscribes when no completion is received" do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:run_completion_waiter_test_pid, parent)
        RunCompletionWaiter.wait("run_waiter_timeout", 20, bus_mod: TestBus)
      end)

    assert_receive {:bus_subscribed, "run:run_waiter_timeout"}, 500
    assert :timeout = Task.await(task, 1_000)
    assert_receive {:bus_unsubscribed, "run:run_waiter_timeout"}, 500
  end

  test "extract_output_from_completion/1 truncates oversized output" do
    long_text = String.duplicate("a", 1_200)
    assert {:ok, output} = RunCompletionWaiter.extract_output_from_completion(%{answer: long_text})
    assert byte_size(output) == 1_000
  end
end
