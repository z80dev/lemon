defmodule LemonAgent.AbortSignalTest do
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal

  @registry LemonAgent.AbortSignal.Registry

  test "new signals have independent atomic abort and redirect slots" do
    first = AbortSignal.new()
    second = AbortSignal.new()
    assert is_reference(first)
    assert first != second
    assert :atomics.info(first).size == 2
    assert :atomics.get(first, 1) == 0
    assert :atomics.get(first, 2) == 0
    refute AbortSignal.aborted?(first)
    refute AbortSignal.redirect_requested?(first)
    assert :ok = AbortSignal.abort(first)
    assert :atomics.get(first, 1) == 1
    assert AbortSignal.aborted?(first)
    refute AbortSignal.aborted?(second)
  end

  test "abort is monotonic and repeated calls are safe" do
    signal = AbortSignal.new()

    for _ <- 1..100 do
      assert :ok = AbortSignal.abort(signal)
      assert AbortSignal.aborted?(signal)
      assert :ok = AbortSignal.clear_redirect(signal)
      assert AbortSignal.aborted?(signal)
    end
  end

  test "nil checks and subscriptions are harmless" do
    refute AbortSignal.aborted?(nil)
    assert :ok = AbortSignal.subscribe(nil)
    assert :ok = AbortSignal.unsubscribe(nil)
  end

  test "subscriptions are idempotent and unsubscribe does not reset the level" do
    signal = AbortSignal.new()
    pid = self()
    assert :ok = AbortSignal.subscribe(signal)
    assert :ok = AbortSignal.subscribe(signal)
    assert Registry.lookup(@registry, signal) == [{pid, nil}]
    assert :ok = AbortSignal.abort(signal)
    assert_receive {:lemon_abort, ^signal, :abort}
    refute_received {:lemon_abort, ^signal, :abort}
    assert :ok = AbortSignal.unsubscribe(signal)
    assert :ok = AbortSignal.unsubscribe(signal)
    assert Registry.lookup(@registry, signal) == []
    assert :ok = AbortSignal.abort(signal)
    refute_received {:lemon_abort, ^signal, :abort}
    assert AbortSignal.aborted?(signal)
  end

  test "signals require no named flag ETS table" do
    signals = for _ <- 1..100, do: AbortSignal.new()
    Enum.each(signals, &AbortSignal.abort/1)
    assert Enum.all?(signals, &AbortSignal.aborted?/1)
    assert :ets.whereis(:agent_core_abort_signals) == :undefined
  end

  test "signal state survives its creator being killed" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        signal = AbortSignal.new()
        AbortSignal.abort(signal)
        send(parent, {:created, self(), signal})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:created, ^pid, signal}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert AbortSignal.aborted?(signal)
    assert :ok = AbortSignal.request_redirect(signal)
    assert AbortSignal.redirect_requested?(signal)
  end
end
