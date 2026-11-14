defmodule LemonAutomation.IntervalRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonAutomation.IntervalRunner

  defmodule Runner do
    def should_run_now?(_opts), do: true

    def run_once(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runner_started, opts})
    end
  end

  setup do
    if is_nil(Process.whereis(LemonAutomation.TaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: LemonAutomation.TaskSupervisor})
    end

    :ok
  end

  test "an absent task supervisor defers work without crashing or starting an unlinked task" do
    supervisor = Process.whereis(LemonAutomation.TaskSupervisor)
    state = state()

    log =
      capture_log(fn ->
        Process.unregister(LemonAutomation.TaskSupervisor)

        try do
          assert {:noreply, ^state} = IntervalRunner.handle_cast(:tick, state)
        after
          Process.register(supervisor, LemonAutomation.TaskSupervisor)
        end
      end)

    assert log =~ "task_supervisor_unavailable"
    refute_receive {:runner_started, _}
  end

  test "idle tracking resets on activity and supplies elapsed idle time to the runner" do
    busy = %{state() | track_idle: true, opts: [active_sessions_fun: fn -> [:busy] end]}
    assert {:noreply, busy} = IntervalRunner.handle_cast(:tick, busy)
    assert busy.last_busy_at_ms > 0
    assert is_nil(busy.in_flight_ref)

    idle = %{busy | opts: [test_pid: self(), active_sessions_fun: fn -> [] end]}
    assert {:noreply, running} = IntervalRunner.handle_cast(:tick, idle)
    assert is_reference(running.in_flight_ref)
    assert_receive {:runner_started, opts}
    assert opts[:idle_for_seconds] >= 0

    assert {:noreply, ^running} = IntervalRunner.handle_cast(:tick, running)
    refute_receive {:runner_started, _}

    assert {:noreply, cleared} =
             IntervalRunner.handle_info({:DOWN, running.in_flight_ref, :process, self(), :normal}, running)

    assert is_nil(cleared.in_flight_ref)
  end

  defp state do
    %{
      runner: Runner,
      opts: [test_pid: self(), active_sessions_fun: fn -> [] end],
      track_idle: false,
      last_busy_at_ms: 0,
      in_flight_ref: nil
    }
  end
end
