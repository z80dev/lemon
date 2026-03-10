defmodule LemonCore.Testing.AsyncHelpersTest do
  use ExUnit.Case, async: true

  alias LemonCore.Testing.AsyncHelpers

  describe "assert_eventually/2" do
    test "returns :ok immediately when condition is true" do
      assert :ok = AsyncHelpers.assert_eventually(fn -> true end)
    end

    test "waits until condition becomes true" do
      ref = make_ref()
      parent = self()

      spawn(fn ->
        Process.sleep(50)
        send(parent, {ref, :ready})
      end)

      assert :ok =
               AsyncHelpers.assert_eventually(
                 fn ->
                   receive do
                     {^ref, :ready} -> true
                   after
                     0 -> false
                   end
                 end,
                 timeout: 2_000
               )
    end
  end

  describe "latch/release/await_latch" do
    test "latch blocks until released" do
      latch = AsyncHelpers.latch()

      spawn(fn ->
        Process.sleep(20)
        AsyncHelpers.release(latch)
      end)

      assert :ok = AsyncHelpers.await_latch(latch, timeout: 2_000)
    end
  end

  describe "barrier/arrive/await_barrier" do
    test "barrier opens when all participants arrive" do
      barrier = AsyncHelpers.barrier(2)

      Task.async(fn ->
        Process.sleep(10)
        AsyncHelpers.arrive(barrier)
      end)

      AsyncHelpers.arrive(barrier)
      assert :ok = AsyncHelpers.await_barrier(barrier, timeout: 2_000)
    end
  end

  describe "with_ordered_tasks/1" do
    test "runs tasks and returns results in order" do
      results = AsyncHelpers.with_ordered_tasks([
        fn -> :first end,
        fn -> :second end,
        fn -> :third end
      ])

      assert results == [:first, :second, :third]
    end
  end

  describe "process lifecycle" do
    test "assert_process_dead waits for process to stop" do
      pid = spawn(fn -> Process.sleep(30) end)
      assert :ok = AsyncHelpers.assert_process_dead(pid, timeout: 2_000)
    end

    test "assert_process_alive confirms a running process" do
      pid = spawn(fn -> Process.sleep(5_000) end)
      assert :ok = AsyncHelpers.assert_process_alive(pid)
    end
  end
end
