defmodule LemonRouter.SlotsTest do
  use ExUnit.Case, async: false

  alias LemonRouter.Slots

  setup do
    server = start_supervised!({Slots, name: __MODULE__, max: 2})
    %{server: server}
  end

  test "two permits cap admission and live waiters advance in FIFO order", %{server: server} do
    a = owner(:a)
    b = owner(:b)
    c = owner(:c)
    d = owner(:d)
    acquire(server, "a", a)
    acquire(server, "b", b)
    assert_receive {:a, {:slot_granted, first}}
    assert_receive {:b, {:slot_granted, second}}
    acquire(server, "c", c)
    acquire(server, "d", d)
    assert stats(server) == %{in_flight: 2, waitq: 2, max: 2}
    refute_receive {:c, {:slot_granted, _}}, 0
    refute_receive {:d, {:slot_granted, _}}, 0

    GenServer.cast(server, {:release, first})
    assert_receive {:c, {:slot_granted, third}}
    assert stats(server) == %{in_flight: 2, waitq: 1, max: 2}
    refute_receive {:d, {:slot_granted, _}}, 0
    GenServer.cast(server, {:release, second})
    assert_receive {:d, {:slot_granted, fourth}}
    GenServer.cast(server, {:release, third})
    GenServer.cast(server, {:release, fourth})
    assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}
  end

  test "duplicate identity and duplicate release never consume extra permits", %{server: server} do
    a = owner(:a)
    acquire(server, "a", a)
    acquire(server, "a", a)
    acquire(server, "a", owner(:duplicate))
    assert_receive {:a, {:slot_granted, permit}}
    assert stats(server) == %{in_flight: 1, waitq: 0, max: 2}
    refute_receive {:a, {:slot_granted, _}}, 0
    refute_receive {:duplicate, {:slot_granted, _}}, 0
    GenServer.cast(server, {:release, permit})
    GenServer.cast(server, {:release, permit})
    assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}
    assert {:monitors, []} = Process.info(server, :monitors)
  end

  test "cancelling a waiter removes it before capacity opens", %{server: server} do
    acquire(server, "a", owner(:a))
    acquire(server, "b", owner(:b))
    assert_receive {:a, {:slot_granted, first}}
    assert_receive {:b, {:slot_granted, _}}
    acquire(server, "cancelled", owner(:cancelled))
    acquire(server, "next", owner(:next))
    GenServer.cast(server, {:cancel, "cancelled", :user_requested})
    assert_receive {:cancelled, {:"$gen_cast", {:cancel, :user_requested}}}
    assert stats(server) == %{in_flight: 2, waitq: 1, max: 2}
    GenServer.cast(server, {:release, first})
    assert_receive {:next, {:slot_granted, _}}
    assert stats(server) == %{in_flight: 2, waitq: 0, max: 2}
    refute_receive {:cancelled, {:slot_granted, _}}, 0
  end

  test "active cancellation retains capacity until owner release", %{server: server} do
    acquire(server, "a", owner(:a))
    acquire(server, "b", owner(:b))
    assert_receive {:a, {:slot_granted, first}}
    assert_receive {:b, {:slot_granted, _}}
    acquire(server, "next", owner(:next))
    GenServer.cast(server, {:cancel, "a", :user_requested})
    assert_receive {:a, {:"$gen_cast", {:cancel, :user_requested}}}
    assert stats(server) == %{in_flight: 2, waitq: 1, max: 2}
    refute_receive {:next, {:slot_granted, _}}, 0
    GenServer.cast(server, {:release, first})
    assert_receive {:next, {:slot_granted, _}}
  end

  test "owner death frees permits and dead queued owners are skipped", %{server: server} do
    a = owner(:a)
    dead_waiter = owner(:dead)
    acquire(server, "a", a)
    acquire(server, "b", owner(:b))
    assert_receive {:a, {:slot_granted, _}}
    assert_receive {:b, {:slot_granted, _}}
    acquire(server, "dead", dead_waiter)
    acquire(server, "next", owner(:next))
    assert stats(server).waitq == 2
    stop_owner(dead_waiter)
    stop_owner(a)
    assert_receive {:next, {:slot_granted, _}}
    assert stats(server) == %{in_flight: 2, waitq: 0, max: 2}
    refute_receive {:dead, {:slot_granted, _}}, 0
  end

  test "stats remain available while the authority is suspended", %{server: server} do
    acquire(server, "a", owner(:a))
    assert_receive {:a, {:slot_granted, _}}
    assert stats(server) == %{in_flight: 1, waitq: 0, max: 2}
    :ok = :sys.suspend(server)

    try do
      assert {:ok, %{in_flight: 1, waitq: 0, max: 2}} = Slots.stats(__MODULE__)
    after
      :sys.resume(server)
    end

    assert {:error, :not_running} = Slots.stats(LemonRouter.SlotsTest.NotRunning)
  end

  test "invalid concurrency fails startup rather than falling back" do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:invalid_max_concurrent_runs, 0}} =
               Slots.start_link(name: LemonRouter.SlotsTest.Invalid, max: 0)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  # #617/#697: a running router slot pool follows `max_concurrent_runs` across reloads.
  test "a config reload changes the limit of a running router slot pool" do
    key = :gateway_test_config
    previous = Application.fetch_env(:lemon_core, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, key, value)
        :error -> Application.delete_env(:lemon_core, key)
      end

      # The shared router pool also received the test's system broadcasts.
      :ok = LemonCore.Bus.broadcast("system", reloaded_event())
      if slots = Process.whereis(Slots), do: :sys.get_state(slots)
    end)

    Application.put_env(:lemon_core, key, %{max_concurrent_runs: 1})
    name = LemonRouter.SlotsTest.Reloading
    server = start_supervised!({Slots, name: name}, id: name)
    assert {:ok, %{max: 1}} = Slots.stats(name)

    a = owner(:a)
    b = owner(:b)
    GenServer.cast(server, {:acquire, "a", a})
    GenServer.cast(server, {:acquire, "b", b})
    assert_receive {:a, {:slot_granted, _}}
    refute_receive {:b, {:slot_granted, _}}, 50

    Application.put_env(:lemon_core, key, %{max_concurrent_runs: 3})
    LemonCore.Bus.broadcast("system", reloaded_event())

    assert_receive {:b, {:slot_granted, _}}
    :sys.get_state(server)
    assert {:ok, %{max: 3, in_flight: 2}} = Slots.stats(name)

    # An invalid value keeps the last good limit.
    Application.put_env(:lemon_core, key, %{max_concurrent_runs: 0})

    ExUnit.CaptureLog.capture_log(fn ->
      LemonCore.Bus.broadcast("system", reloaded_event())
      :sys.get_state(server)
    end)

    assert {:ok, %{max: 3}} = Slots.stats(name)
  end

  defp reloaded_event do
    LemonCore.Event.new(
      :config_reloaded,
      LemonCore.Events.ConfigReloaded.new(%{reload_id: "test"})
    )
  end

  describe "lending a blocked run's permit" do
    test "two parents with sync children complete under cap 2", %{server: server} do
      run_tree(server, "p1", 1, self())
      run_tree(server, "p2", 1, self())

      assert_receive {:done, "p1"}, 2_000
      assert_receive {:done, "p2"}, 2_000
      assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}
    end

    test "depth-2 delegation does not deadlock, even under cap 1" do
      start_supervised!({Slots, name: LemonRouter.SlotsTest.One, max: 1}, id: :one)
      run_tree(LemonRouter.SlotsTest.One, "root", 2, self())

      assert_receive {:done, "root"}, 2_000

      assert eventually(fn ->
               match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats(LemonRouter.SlotsTest.One))
             end)
    end

    test "a resumed run re-enters at the front of the queue", %{server: server} do
      acquire(server, "a", owner(:a))
      acquire(server, "x", owner(:x))
      assert_receive {:a, {:slot_granted, _}}
      assert_receive {:x, {:slot_granted, x_permit}}
      acquire(server, "b", owner(:b))
      acquire(server, "c", owner(:c))

      assert {:ok, token} = Slots.suspend("a", server)
      assert_receive {:b, {:slot_granted, b_permit}}
      assert stats(server) == %{in_flight: 2, waitq: 1, max: 2}

      resumed = Task.async(fn -> Slots.resume(token, :wait, server) end)
      refute Task.yield(resumed, 50)

      GenServer.cast(server, {:release, b_permit})
      assert :ok = Task.await(resumed)
      refute_receive {:c, {:slot_granted, _}}, 50
      assert stats(server) == %{in_flight: 2, waitq: 1, max: 2}

      GenServer.cast(server, {:release, x_permit})
      assert_receive {:c, {:slot_granted, _}}
    end

    test "parallel suspensions of one run re-queue it once, after the last", %{server: server} do
      acquire(server, "a", owner(:a))
      assert_receive {:a, {:slot_granted, _}}
      assert {:ok, first} = Slots.suspend("a", server)
      assert {:ok, second} = Slots.suspend("a", server)
      assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}

      assert :ok = Slots.resume(first, :wait, server)
      assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}
      assert :ok = Slots.resume(second, :wait, server)
      assert stats(server) == %{in_flight: 1, waitq: 0, max: 2}
    end

    test "holder death, nowait resume and run release end suspensions", %{server: server} do
      acquire(server, "a", owner(:a))
      assert_receive {:a, {:slot_granted, a_permit}}
      parent = self()

      holder =
        spawn(fn ->
          send(parent, {:suspended, Slots.suspend("a", server)})
          Process.sleep(:infinity)
        end)

      assert_receive {:suspended, {:ok, _token}}
      assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}
      stop_owner(holder)
      # The authority observes the holder's death independently of this test.
      assert eventually(fn -> stats(server) == %{in_flight: 1, waitq: 0, max: 2} end)

      assert {:ok, token} = Slots.suspend("a", server)
      :ok = Slots.resume(token, :nowait, server)
      assert stats(server) == %{in_flight: 1, waitq: 0, max: 2}

      assert {:ok, token} = Slots.suspend("a", server)
      GenServer.cast(server, {:release, a_permit})
      assert :ok = Slots.resume(token, :wait, server)
      assert stats(server) == %{in_flight: 0, waitq: 0, max: 2}
      assert {:monitors, []} = Process.info(server, :monitors)
    end

    test "only a run holding a permit can lend it", %{server: server} do
      assert {:error, :not_holding} = Slots.suspend("unknown", server)
      acquire(server, "a", owner(:a))
      acquire(server, "b", owner(:b))
      acquire(server, "waiting", owner(:waiting))
      assert_receive {:a, {:slot_granted, _}}
      assert {:error, :not_holding} = Slots.suspend("waiting", server)
    end
  end

  # A Run that, once admitted, synchronously delegates a child chain of
  # `depth` and lends its permit while it waits.
  defp run_tree(server, run_id, depth, report_to) do
    spawn_link(fn ->
      GenServer.cast(server, {:acquire, run_id, self()})
      permit = receive do: ({:slot_granted, permit} -> permit)

      if depth > 0 do
        child = run_id <> "/child"
        run_tree(server, child, depth - 1, self())
        {:ok, token} = Slots.suspend(run_id, server)
        receive do: ({:done, ^child} -> :ok)
        :ok = Slots.resume(token, :wait, server)
      end

      GenServer.cast(server, {:release, permit})
      send(report_to, {:done, run_id})
    end)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp acquire(server, run_id, pid), do: GenServer.cast(server, {:acquire, run_id, pid})

  defp stats(server) do
    :sys.get_state(server)
    {:ok, counters} = Slots.stats(__MODULE__)
    counters
  end

  defp owner(label) do
    parent = self()
    pid = spawn(fn -> forward(parent, label) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp forward(parent, label) do
    receive do
      message ->
        send(parent, {label, message})
        forward(parent, label)
    end
  end

  defp stop_owner(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end
end
