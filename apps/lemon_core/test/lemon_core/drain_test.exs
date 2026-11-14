defmodule LemonCore.DrainTest do
  use ExUnit.Case, async: false

  alias LemonCore.Drain

  defmodule Recorder do
    @behaviour LemonCore.Drain

    @impl true
    def drain(phase, ctx) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:drained, __MODULE__, phase, ctx})
      {:ok, %{phase: phase, phase_seen: Drain.phase()}}
    end
  end

  defmodule Crasher do
    @behaviour LemonCore.Drain
    @impl true
    def drain(_phase, _ctx), do: raise("boom")
  end

  defmodule Sleeper do
    @behaviour LemonCore.Drain
    @impl true
    def drain(:work, ctx) do
      Process.sleep(ctx.deadline_ms - System.monotonic_time(:millisecond) + 5_000)
      :ok
    end

    def drain(:ingress, _ctx), do: :ok
  end

  setup do
    # Drain the real coordinator only with this test's participants.
    saved = Drain.participants()
    Enum.each(saved, fn {name, _module, _order} -> Drain.unregister(name) end)
    :persistent_term.put({Recorder, :test_pid}, self())

    on_exit(fn ->
      Enum.each(Drain.participants(), fn {name, _module, _order} -> Drain.unregister(name) end)
      Enum.each(saved, fn {name, module, order} -> Drain.register(name, module, order: order) end)
      Drain.reset()
      :persistent_term.erase({Recorder, :test_pid})
    end)
  end

  test "runs every participant through ingress, then work, while reporting draining" do
    :ok = Drain.register(:recorder, Recorder)
    assert Drain.phase() == :serving

    assert {:ok, report} = Drain.run(grace_ms: 100, timeout_ms: 2_000, reason: :test)

    assert_received {:drained, Recorder, :ingress, ingress_ctx}
    assert_received {:drained, Recorder, :work, work_ctx}
    assert ingress_ctx.deadline_ms <= work_ctx.deadline_ms
    assert work_ctx.grace_deadline_ms - work_ctx.started_at_ms == 100

    assert %{status: :ok, phase: :work, phase_seen: :draining} = report.work.recorder
    assert report.reason == :test
    assert Drain.phase() == :stopping
    assert {:error, :already_draining} = Drain.run()
  end

  test "a crashing or overrunning participant is reported and skipped" do
    :ok = Drain.register(:crasher, Crasher, order: 1)
    :ok = Drain.register(:sleeper, Sleeper, order: 2)
    :ok = Drain.register(:recorder, Recorder, order: 3)

    started = System.monotonic_time(:millisecond)
    assert {:ok, report} = Drain.run(grace_ms: 0, timeout_ms: 300)

    assert report.ingress.crasher.status == :failed
    assert report.work.sleeper.status == :failed
    assert report.work.recorder.status == :ok
    # Bounded by the deadline plus the one-second overrun allowance.
    assert System.monotonic_time(:millisecond) - started < 3_000
  end
end
