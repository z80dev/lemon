defmodule LemonAutomation.CronManagerDowntimeTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronSchedule, CronStore}

  setup do
    id = "downtime_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      CronStore.delete_job(id)
      for run <- CronStore.list_runs(id, limit: 10_000), do: CronStore.delete_run(run.id)
    end)

    %{id: id}
  end

  test "boot preserves a missed daily slot and tick claims it exactly once", %{id: id} do
    job = store_job(id, next_run_at_ms: LemonCore.Clock.now_ms() - 1_800_000)
    {:ok, state} = CronManager.init([])
    assert state.jobs[id].next_run_at_ms == job.next_run_at_ms
    state = %{state | jobs: Map.take(state.jobs, [id])}
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert {:noreply, _state} = CronManager.handle_cast(:tick, state)
    assert [run] = CronStore.list_runs(id)
    assert run.meta.catch_up
    assert run.meta.scheduled_for_ms == job.next_run_at_ms
    assert_receive {:submit_claimed_run, ^id, _}
    refute_receive {:submit_claimed_run, ^id, _}
  end

  test "slots outside grace re-anchor with an audit", %{id: id} do
    store_job(id, next_run_at_ms: LemonCore.Clock.now_ms() - 7_200_001)
    {:ok, state} = CronManager.init([])
    assert state.jobs[id].next_run_at_ms > LemonCore.Clock.now_ms()
    assert CronStore.list_runs(id) == []

    assert Enum.any?(CronStore.list_audit_events(limit: 100), fn event ->
             event.job_id == id and event.action == "missed_slot_skipped"
           end)
  end

  test "missed one-shot retires outside grace instead of moving to next year", %{id: id} do
    due = LemonCore.Clock.now_ms() - 7_200_001
    date = DateTime.from_unix!(due, :millisecond)
    schedule = "#{date.minute} #{date.hour} #{date.day} #{date.month} *"
    assert CronSchedule.next_run_ms(schedule, "UTC") > due
    store_job(id, schedule: schedule, once: true, next_run_at_ms: due)
    {:ok, state} = CronManager.init([])
    refute Map.has_key?(state.jobs, id)
    assert CronStore.get_job(id) == nil
    assert CronStore.list_runs(id) == []
  end

  test "missed one-shot inside grace claims once and disables immediately", %{id: id} do
    store_job(id, once: true, next_run_at_ms: LemonCore.Clock.now_ms() - 1_000)
    {:ok, state} = CronManager.init([])
    state = %{state | jobs: Map.take(state.jobs, [id])}
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    refute state.jobs[id].enabled
    assert state.jobs[id].next_run_at_ms == nil
    assert [run] = CronStore.list_runs(id)
    assert run.meta.catch_up
  end

  test "paused jobs retain their paused schedule", %{id: id} do
    job = store_job(id, enabled: false, next_run_at_ms: LemonCore.Clock.now_ms() - 1_000)
    {:ok, state} = CronManager.init([])
    assert state.jobs[id] == job
    assert {:noreply, _} = CronManager.handle_cast(:tick, %{state | jobs: %{id => job}})
    assert CronStore.list_runs(id) == []
  end

  test "short periods use the two-minute minimum grace", %{id: id} do
    store_job(id, schedule: "* * * * *", next_run_at_ms: LemonCore.Clock.now_ms() - 119_000)
    {:ok, state} = CronManager.init([])
    assert state.catch_up_slots[id]

    store_job(id, schedule: "* * * * *", next_run_at_ms: LemonCore.Clock.now_ms() - 121_000)
    {:ok, state} = CronManager.init([])
    refute state.catch_up_slots[id]
    assert state.jobs[id].next_run_at_ms > LemonCore.Clock.now_ms()
  end

  test "tick cleans history only at the hourly cadence", %{id: id} do
    {:ok, state} = CronManager.init([])
    run = id |> CronRun.new(:manual) |> CronRun.complete("ok")
    CronStore.put_run(run)
    state = %{state | jobs: %{}, run_retention_per_job: 0}
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert CronStore.get_run(run.id)
    state = %{state | last_cleanup_at_ms: LemonCore.Clock.now_ms() - 3_600_001}
    assert {:noreply, _} = CronManager.handle_cast(:tick, state)
    assert CronStore.get_run(run.id) == nil
  end

  test "retention is per job and keeps active attempts and pending retries", %{id: id} do
    other = id <> "_other"

    on_exit(fn ->
      for run <- CronStore.list_runs(other), do: CronStore.delete_run(run.id)
    end)

    runs =
      for {job_id, offset} <- [{id, 1}, {id, 2}, {other, 3}] do
        run = job_id |> CronRun.new(:schedule) |> CronRun.complete("ok")
        run = %{run | started_at_ms: offset}
        CronStore.put_run(run)
        run
      end

    active = CronRun.new(id, :schedule)
    CronStore.put_run(active)
    retry = id |> CronRun.new(:schedule) |> CronRun.complete("retry")
    retry = %{retry | meta: %{retry_due_at_ms: 1, retry_next_attempt: 1}}
    CronStore.put_run(retry)
    assert :ok = CronStore.cleanup_old_runs(1)
    [old, recent, foreign] = runs
    assert CronStore.get_run(old.id) == nil
    assert CronStore.get_run(recent.id)
    assert CronStore.get_run(foreign.id)
    assert CronStore.get_run(active.id)
    assert CronStore.get_run(retry.id)
  end

  defp store_job(id, attrs) do
    job =
      CronJob.new(
        Map.merge(
          %{
            id: id,
            name: id,
            schedule: "0 9 * * *",
            timezone: "UTC",
            agent_id: "test",
            session_key: "agent:test:main",
            prompt: "test"
          },
          Map.new(attrs)
        )
      )

    job = %{job | next_run_at_ms: Keyword.get(attrs, :next_run_at_ms)}
    CronStore.put_job(job)
    job
  end
end
