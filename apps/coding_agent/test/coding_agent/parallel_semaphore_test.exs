defmodule CodingAgent.Parallel.SemaphoreTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Parallel.Semaphore

  test "killed holder returns every acquired slot to waiting callers" do
    sem = start_supervised!({Semaphore, max: 2})
    holder = start_caller(sem, 2)
    assert_receive {:acquired, ^holder}, 1000
    assert Semaphore.available(sem) == 0

    first = start_caller(sem)
    await_monitored(sem, first)
    second = start_caller(sem)
    await_monitored(sem, second)
    # Acquisition waits for capacity, not for a blocked server callback.
    assert Semaphore.available(sem) == 0

    kill_and_wait(holder)

    assert_receive {:acquired, ^first}, 1000
    assert_receive {:acquired, ^second}, 1000
    assert Semaphore.available(sem) == 0

    release_caller(first)
    release_caller(second)
    assert Semaphore.available(sem) == 2
  end

  test "queued caller DOWN cannot consume a released slot" do
    sem = start_supervised!({Semaphore, max: 1})
    assert :ok = Semaphore.acquire(sem)
    dead = start_caller(sem)
    await_monitored(sem, dead)
    next = start_caller(sem)
    await_monitored(sem, next)

    kill_and_wait(dead)
    await_unmonitored(sem, dead)
    Semaphore.release(sem)

    assert_receive {:acquired, ^next}, 1000
    release_caller(next)
    assert Semaphore.available(sem) == 1
  end

  test "release skips a dead waiter even when its DOWN is still queued" do
    sem = start_supervised!({Semaphore, max: 1})
    assert :ok = Semaphore.acquire(sem)
    dead = start_caller(sem)
    await_monitored(sem, dead)
    next = start_caller(sem)
    await_monitored(sem, next)

    :ok = :sys.suspend(sem)

    try do
      # Queue the release before the death notification while the server is paused.
      Semaphore.release(sem)
      kill_and_wait(dead)
    after
      :sys.resume(sem)
    end

    assert_receive {:acquired, ^next}, 1000
    release_caller(next)
    assert Semaphore.available(sem) == 1
  end

  test "nonholders cannot release another caller's slot" do
    sem = start_supervised!({Semaphore, max: 1})
    holder = start_caller(sem)
    assert_receive {:acquired, ^holder}, 1000
    waiter = start_caller(sem)
    await_monitored(sem, waiter)

    Semaphore.release(sem)
    assert Semaphore.available(sem) == 0
    refute_receive {:acquired, ^waiter}, 20

    release_caller(holder)
    assert_receive {:acquired, ^waiter}, 1000
    release_caller(waiter)
    assert Semaphore.available(sem) == 1
  end

  test "repeated acquisitions require matching releases and remove monitors" do
    sem = start_supervised!({Semaphore, max: 2})
    assert :ok = Semaphore.acquire(sem)
    assert :ok = Semaphore.acquire(sem)
    assert Semaphore.available(sem) == 0

    Semaphore.release(sem)
    assert Semaphore.available(sem) == 1
    Semaphore.release(sem)
    assert Semaphore.available(sem) == 2
    assert {:monitors, []} = Process.info(sem, :monitors)
    Semaphore.release(sem)
    assert Semaphore.available(sem) == 2
  end

  defp start_caller(sem, count \\ 1) do
    parent = self()

    pid =
      spawn(fn ->
        for _ <- 1..count, do: Semaphore.acquire(sem)
        send(parent, {:acquired, self()})

        receive do
          :release ->
            for _ <- 1..count, do: Semaphore.release(sem)
            # Fence the casts before notifying the test process.
            Semaphore.available(sem)
            send(parent, {:released, self()})
        end
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: kill_and_wait(pid)
    end)

    pid
  end

  defp release_caller(pid) do
    send(pid, :release)
    assert_receive {:released, ^pid}, 1000
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000
  end

  defp await_monitored(sem, pid), do: await_monitor_state(sem, pid, true, 1000)
  defp await_unmonitored(sem, pid), do: await_monitor_state(sem, pid, false, 1000)

  defp await_monitor_state(sem, pid, expected, attempts) do
    {:monitors, monitors} = Process.info(sem, :monitors)
    present = {:process, pid} in monitors

    if present == expected or attempts == 0 do
      assert present == expected
    else
      Process.sleep(10)
      await_monitor_state(sem, pid, expected, attempts - 1)
    end
  end
end
