defmodule LemonAutomation.CronRunTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.CronRun

  defp base_run(attrs \\ %{}) do
    run = %CronRun{
      id: "run_test",
      job_id: "cron_test",
      run_id: nil,
      status: :pending,
      started_at_ms: nil,
      completed_at_ms: nil,
      duration_ms: nil,
      triggered_by: :schedule,
      error: nil,
      output: nil,
      suppressed: false,
      meta: %{source: "test"}
    }

    struct!(run, attrs)
  end

  describe "new/2" do
    test "creates a pending run with defaults" do
      run = CronRun.new("cron_new_1")

      assert String.starts_with?(run.id, "run_")
      assert run.job_id == "cron_new_1"
      assert run.status == :pending
      assert run.triggered_by == :schedule
      assert run.started_at_ms == nil
      assert run.completed_at_ms == nil
      assert run.duration_ms == nil
      assert run.suppressed == false
    end

    test "accepts explicit trigger" do
      run = CronRun.new("cron_new_2", :manual)
      assert run.triggered_by == :manual
    end
  end

  describe "start/2" do
    test "marks run as running and sets run_id and started_at_ms" do
      before = LemonCore.Clock.now_ms()
      started = CronRun.start(base_run(), "router_run_1")
      after_ms = LemonCore.Clock.now_ms()

      assert started.status == :running
      assert started.run_id == "router_run_1"
      assert started.started_at_ms >= before
      assert started.started_at_ms <= after_ms
    end

    test "keeps run_id nil when omitted" do
      started = CronRun.start(base_run())

      assert started.status == :running
      assert started.run_id == nil
      assert is_integer(started.started_at_ms)
    end
  end

  describe "complete/2" do
    test "computes duration when started_at_ms is set" do
      started_at_ms = LemonCore.Clock.now_ms() - 50

      completed =
        base_run(%{status: :running, started_at_ms: started_at_ms})
        |> CronRun.complete("ok")

      assert completed.status == :completed
      assert completed.output == "ok"
      assert is_integer(completed.completed_at_ms)
      assert completed.duration_ms == completed.completed_at_ms - started_at_ms
    end

    test "leaves duration nil when started_at_ms is nil" do
      completed =
        base_run(%{status: :running, started_at_ms: nil})
        |> CronRun.complete("ok")

      assert completed.status == :completed
      assert completed.output == "ok"
      assert completed.duration_ms == nil
      assert is_integer(completed.completed_at_ms)
    end
  end

  describe "fail/2" do
    test "computes duration when started_at_ms is set" do
      started_at_ms = LemonCore.Clock.now_ms() - 25

      failed =
        base_run(%{status: :running, started_at_ms: started_at_ms})
        |> CronRun.fail("boom")

      assert failed.status == :failed
      assert failed.error == "boom"
      assert is_integer(failed.completed_at_ms)
      assert failed.duration_ms == failed.completed_at_ms - started_at_ms
    end

    test "leaves duration nil when started_at_ms is nil" do
      failed =
        base_run(%{status: :running, started_at_ms: nil})
        |> CronRun.fail("boom")

      assert failed.status == :failed
      assert failed.error == "boom"
      assert failed.duration_ms == nil
      assert is_integer(failed.completed_at_ms)
    end
  end

  describe "timeout/1" do
    test "computes duration when started_at_ms is set" do
      started_at_ms = LemonCore.Clock.now_ms() - 10
      timed_out = CronRun.timeout(base_run(%{status: :running, started_at_ms: started_at_ms}))

      assert timed_out.status == :timeout
      assert timed_out.error == "Run exceeded timeout"
      assert is_integer(timed_out.completed_at_ms)
      assert timed_out.duration_ms == timed_out.completed_at_ms - started_at_ms
    end

    test "leaves duration nil when started_at_ms is nil" do
      timed_out = CronRun.timeout(base_run(%{status: :running, started_at_ms: nil}))

      assert timed_out.status == :timeout
      assert timed_out.error == "Run exceeded timeout"
      assert timed_out.duration_ms == nil
      assert is_integer(timed_out.completed_at_ms)
    end
  end

  describe "suppress/1" do
    test "marks run as suppressed" do
      assert CronRun.suppress(base_run()).suppressed
    end
  end

  describe "active?/1" do
    test "returns true only for pending and running states" do
      assert CronRun.active?(base_run(%{status: :pending}))
      assert CronRun.active?(base_run(%{status: :running}))
      refute CronRun.active?(base_run(%{status: :completed}))
      refute CronRun.active?(base_run(%{status: :failed}))
      refute CronRun.active?(base_run(%{status: :timeout}))
    end
  end

  describe "finished?/1" do
    test "returns true only for terminal states" do
      refute CronRun.finished?(base_run(%{status: :pending}))
      refute CronRun.finished?(base_run(%{status: :running}))
      assert CronRun.finished?(base_run(%{status: :completed}))
      assert CronRun.finished?(base_run(%{status: :failed}))
      assert CronRun.finished?(base_run(%{status: :timeout}))
    end
  end

  describe "to_map/1 and from_map/1" do
    test "serializes and restores all fields" do
      run =
        base_run(%{
          id: "run_map",
          job_id: "cron_map",
          run_id: "router_map",
          status: :completed,
          started_at_ms: 101,
          completed_at_ms: 202,
          duration_ms: 101,
          triggered_by: :wake,
          error: nil,
          output: "done",
          suppressed: true,
          meta: %{scope: "map"}
        })

      map = CronRun.to_map(run)
      restored = CronRun.from_map(map)

      assert map == %{
               id: "run_map",
               job_id: "cron_map",
               run_id: "router_map",
               status: :completed,
               started_at_ms: 101,
               completed_at_ms: 202,
               duration_ms: 101,
               triggered_by: :wake,
               error: nil,
               output: "done",
               suppressed: true,
               meta: %{scope: "map"}
             }

      assert restored == run
    end

    test "parses string status/trigger and falls back for unknown values" do
      parsed =
        CronRun.from_map(%{
          "id" => "run_string",
          "job_id" => "cron_string",
          "status" => "failed",
          "triggered_by" => "manual",
          "suppressed" => true
        })

      assert parsed.status == :failed
      assert parsed.triggered_by == :manual
      assert parsed.suppressed == true

      fallback =
        CronRun.from_map(%{
          "id" => "run_unknown",
          "job_id" => "cron_unknown",
          "status" => "unexpected",
          "triggered_by" => "unexpected"
        })

      assert fallback.status == :pending
      assert fallback.triggered_by == :schedule
      assert fallback.suppressed == false
    end
  end
end
