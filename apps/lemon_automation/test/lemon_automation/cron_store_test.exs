defmodule LemonAutomation.CronStoreTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronRun, CronStore}
  alias LemonCore.Store

  @jobs_table :cron_jobs
  @runs_table :cron_runs
  @future_ms 4_102_444_800_000

  setup do
    clear_table(@jobs_table)
    clear_table(@runs_table)

    {:ok, token: System.unique_integer([:positive, :monotonic])}
  end

  describe "job operations" do
    test "put/get/delete and list/list_enabled/list_due behavior", %{token: token} do
      job_due =
        build_job(token, "due",
          created_at_ms: 1_000,
          enabled: true,
          next_run_at_ms: 0
        )

      job_disabled =
        build_job(token, "disabled",
          created_at_ms: 3_000,
          enabled: false,
          next_run_at_ms: 0
        )

      job_future =
        build_job(token, "future",
          created_at_ms: 2_000,
          enabled: true,
          next_run_at_ms: @future_ms
        )

      :ok = CronStore.put_job(job_due)
      :ok = CronStore.put_job(job_disabled)
      :ok = CronStore.put_job(job_future)

      assert CronStore.get_job(job_due.id) == job_due

      assert Enum.map(CronStore.list_jobs(), & &1.id) == [
               job_disabled.id,
               job_future.id,
               job_due.id
             ]

      assert Enum.map(CronStore.list_enabled_jobs(), & &1.id) == [job_future.id, job_due.id]
      assert Enum.map(CronStore.list_due_jobs(), & &1.id) == [job_due.id]

      :ok = CronStore.delete_job(job_due.id)
      assert CronStore.get_job(job_due.id) == nil

      assert Enum.map(CronStore.list_jobs(), & &1.id) == [job_disabled.id, job_future.id]
    end
  end

  describe "run operations" do
    test "put/get/delete and list_runs ordering with limit/status/since filters", %{token: token} do
      job_id = job_id(token, "primary")
      other_job_id = job_id(token, "other")

      run_1 =
        build_run(token, "one", job_id,
          status: :completed,
          started_at_ms: 1_000
        )

      run_2 =
        build_run(token, "two", job_id,
          status: :failed,
          started_at_ms: 2_000
        )

      run_3 =
        build_run(token, "three", job_id,
          status: :running,
          started_at_ms: 3_000
        )

      run_4 =
        build_run(token, "four", job_id,
          status: :completed,
          started_at_ms: 4_000
        )

      run_other =
        build_run(token, "other", other_job_id,
          status: :completed,
          started_at_ms: 9_000
        )

      :ok = CronStore.put_run(run_2)
      :ok = CronStore.put_run(run_4)
      :ok = CronStore.put_run(run_1)
      :ok = CronStore.put_run(run_3)
      :ok = CronStore.put_run(run_other)

      assert CronStore.get_run(run_2.id) == run_2

      assert Enum.map(CronStore.list_runs(job_id), & &1.id) == [
               run_4.id,
               run_3.id,
               run_2.id,
               run_1.id
             ]

      assert Enum.map(CronStore.list_runs(job_id, limit: 2), & &1.id) == [run_4.id, run_3.id]

      assert Enum.map(CronStore.list_runs(job_id, status: :completed), & &1.id) == [
               run_4.id,
               run_1.id
             ]

      assert Enum.map(CronStore.list_runs(job_id, since_ms: 2_000), & &1.id) == [
               run_4.id,
               run_3.id,
               run_2.id
             ]

      assert Enum.map(CronStore.list_runs(job_id, status: :completed, since_ms: 2_000), & &1.id) ==
               [run_4.id]

      :ok = CronStore.delete_run(run_2.id)
      assert CronStore.get_run(run_2.id) == nil
      assert Enum.map(CronStore.list_runs(job_id), & &1.id) == [run_4.id, run_3.id, run_1.id]
    end

    test "list_all_runs and active_runs respect ordering and filters", %{token: token} do
      job_a = job_id(token, "a")
      job_b = job_id(token, "b")

      run_pending =
        build_run(token, "pending", job_a,
          status: :pending,
          started_at_ms: 100
        )

      run_running_a =
        build_run(token, "running_a", job_a,
          status: :running,
          started_at_ms: 300
        )

      run_completed =
        build_run(token, "completed", job_a,
          status: :completed,
          started_at_ms: 200
        )

      run_running_b =
        build_run(token, "running_b", job_b,
          status: :running,
          started_at_ms: 400
        )

      run_timeout =
        build_run(token, "timeout", job_b,
          status: :timeout,
          started_at_ms: 50
        )

      :ok = CronStore.put_run(run_completed)
      :ok = CronStore.put_run(run_running_b)
      :ok = CronStore.put_run(run_pending)
      :ok = CronStore.put_run(run_timeout)
      :ok = CronStore.put_run(run_running_a)

      assert Enum.map(CronStore.list_all_runs(), & &1.id) == [
               run_running_b.id,
               run_running_a.id,
               run_completed.id,
               run_pending.id,
               run_timeout.id
             ]

      assert Enum.map(CronStore.list_all_runs(limit: 3), & &1.id) == [
               run_running_b.id,
               run_running_a.id,
               run_completed.id
             ]

      assert Enum.map(CronStore.list_all_runs(status: :running), & &1.id) == [
               run_running_b.id,
               run_running_a.id
             ]

      assert Enum.map(CronStore.list_all_runs(since_ms: 200), & &1.id) == [
               run_running_b.id,
               run_running_a.id,
               run_completed.id
             ]

      assert Enum.map(CronStore.active_runs(job_a), & &1.id) == [run_running_a.id, run_pending.id]
    end

    test "cleanup_old_runs keeps only the most recent N runs per job", %{token: token} do
      job_one = build_job(token, "cleanup_one", created_at_ms: 10_000)
      job_two = build_job(token, "cleanup_two", created_at_ms: 20_000)

      :ok = CronStore.put_job(job_one)
      :ok = CronStore.put_job(job_two)

      one_1 = build_run(token, "one_1", job_one.id, started_at_ms: 100)
      one_2 = build_run(token, "one_2", job_one.id, started_at_ms: 200)
      one_3 = build_run(token, "one_3", job_one.id, started_at_ms: 300)
      one_4 = build_run(token, "one_4", job_one.id, started_at_ms: 400)

      two_1 = build_run(token, "two_1", job_two.id, started_at_ms: 150)
      two_2 = build_run(token, "two_2", job_two.id, started_at_ms: 250)
      two_3 = build_run(token, "two_3", job_two.id, started_at_ms: 350)

      Enum.each([one_1, one_2, one_3, one_4, two_1, two_2, two_3], fn run ->
        :ok = CronStore.put_run(run)
      end)

      assert :ok = CronStore.cleanup_old_runs(2)

      assert Enum.map(CronStore.list_runs(job_one.id, limit: 10), & &1.id) == [one_4.id, one_3.id]
      assert Enum.map(CronStore.list_runs(job_two.id, limit: 10), & &1.id) == [two_3.id, two_2.id]
    end
  end

  defp clear_table(table) do
    Enum.each(Store.list(table), fn {key, _value} ->
      :ok = Store.delete(table, key)
    end)
  end

  defp job_id(token, suffix), do: "cron_store_#{token}_#{suffix}"

  defp run_id(token, suffix), do: "run_store_#{token}_#{suffix}"

  defp build_job(token, suffix, attrs) do
    base = %CronJob{
      id: job_id(token, suffix),
      name: "Job #{suffix}",
      schedule: "* * * * *",
      enabled: true,
      agent_id: "agent_#{token}_#{suffix}",
      session_key: "agent:agent_#{token}_#{suffix}:main",
      prompt: "Prompt #{suffix}",
      timezone: "UTC",
      jitter_sec: 0,
      timeout_ms: 300_000,
      created_at_ms: 1_000,
      updated_at_ms: 1_000,
      last_run_at_ms: nil,
      next_run_at_ms: nil,
      meta: %{source: "cron_store_test"}
    }

    struct!(base, Map.new(attrs))
  end

  defp build_run(token, suffix, job_id, attrs) do
    base = %CronRun{
      id: run_id(token, suffix),
      job_id: job_id,
      run_id: "router_#{token}_#{suffix}",
      status: :completed,
      started_at_ms: 1_000,
      completed_at_ms: 1_010,
      duration_ms: 10,
      triggered_by: :schedule,
      error: nil,
      output: "ok",
      suppressed: false,
      meta: %{source: "cron_store_test"}
    }

    struct!(base, Map.new(attrs))
  end
end
