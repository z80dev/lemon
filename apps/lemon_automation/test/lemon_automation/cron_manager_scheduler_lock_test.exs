defmodule LemonAutomation.CronManagerSchedulerLockTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}
  alias LemonCore.{Bus, Event}

  defmodule LockSubmitter do
    def submit(_job, run, _opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:cron_submit, run.id, run.triggered_by}
      )

      {:ok, "unexpected submit"}
    end
  end

  setup do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, LockSubmitter)
    :persistent_term.put({LockSubmitter, :test_pid}, self())

    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "scheduler-lock-#{token}",
        schedule: "* * * * *",
        agent_id: "cron_lock_#{token}",
        session_key: "agent:cron_lock_#{token}:main",
        prompt: "should not submit while active",
        timezone: "UTC"
      })

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_automation, :cron_run_submitter)
      else
        Application.put_env(:lemon_automation, :cron_run_submitter, previous)
      end

      :persistent_term.erase({LockSubmitter, :test_pid})

      for run <- CronStore.list_runs(job.id, limit: 100) do
        CronStore.delete_run(run.id)
      end

      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "scheduled tick does not start another run while the job has an active run", %{job: job} do
    %CronJob{} = job

    due_job = %{
      job
      | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000,
        last_run_at_ms: nil
    }

    CronStore.put_job(due_job)
    replace_job_state(due_job)

    existing_run =
      job.id
      |> CronRun.new(:schedule)
      |> CronRun.start("router_existing_lock")

    CronStore.put_run(existing_run)

    CronManager.tick()

    assert await(fn ->
             persisted = CronStore.get_job(job.id)
             persisted.next_run_at_ms && persisted.next_run_at_ms > due_job.next_run_at_ms
           end)

    active_runs = CronStore.active_runs(job.id)
    assert Enum.map(active_runs, & &1.id) == [existing_run.id]
    assert CronStore.get_job(job.id).last_run_at_ms == nil
  end

  test "scheduled tick claims a deterministic run slot before submit", %{job: job} do
    %CronJob{} = job
    scheduled_for_ms = LemonCore.Clock.now_ms() - 1_000

    due_job = %{
      job
      | next_run_at_ms: scheduled_for_ms,
        last_run_at_ms: nil
    }

    CronStore.put_job(due_job)
    replace_job_state(due_job)

    expected_run_id = CronStore.scheduled_run_id(job.id, scheduled_for_ms)

    CronManager.tick()

    assert_receive {:cron_submit, ^expected_run_id, :schedule}, 2_000

    assert await(fn ->
             case CronStore.get_run(expected_run_id) do
               %CronRun{run_id: router_run_id, meta: %{scheduled_for_ms: ^scheduled_for_ms}}
               when is_binary(router_run_id) ->
                 true

               _ ->
                 false
             end
           end)

    assert await(fn ->
             case CronStore.get_job(job.id) do
               %CronJob{last_run_at_ms: last_run_at_ms} when is_integer(last_run_at_ms) -> true
               _ -> false
             end
           end)
  end

  test "scheduled slot claim preserves the first dispatcher winner", %{job: job} do
    scheduled_for_ms = LemonCore.Clock.now_ms() - 1_000

    assert {:ok, first} =
             CronStore.claim_scheduled_run(job, scheduled_for_ms, "router_first_dispatcher")

    assert {:error, :exists} =
             CronStore.claim_scheduled_run(job, scheduled_for_ms, "router_second_dispatcher")

    assert CronStore.get_run(first.id).run_id == "router_first_dispatcher"
  end

  test "scheduled tick times out stale active runs before applying the active-run lock", %{
    job: job
  } do
    %CronJob{} = job

    due_job = %{
      job
      | timeout_ms: 10,
        next_run_at_ms: LemonCore.Clock.now_ms() + 60_000,
        last_run_at_ms: nil
    }

    CronStore.put_job(due_job)
    replace_job_state(due_job)

    stale_run =
      due_job.id
      |> CronRun.new(:schedule)
      |> CronRun.start("router_stale_lock")

    stale_run = %{stale_run | started_at_ms: LemonCore.Clock.now_ms() - 1_000}
    CronStore.put_run(stale_run)

    Bus.subscribe("cron")
    flush_events()

    on_exit(fn ->
      Bus.unsubscribe("cron")
    end)

    CronManager.tick()

    assert_receive %Event{
                     type: :cron_run_completed,
                     payload: %{cron_run_id: cron_run_id, status: :timeout}
                   },
                   2_000

    assert cron_run_id == stale_run.id

    assert await(fn ->
             case CronStore.get_run(stale_run.id) do
               %CronRun{status: :timeout, error: "Run exceeded timeout"} -> true
               _ -> false
             end
           end)

    assert CronStore.active_runs(due_job.id) == []
  end

  test "manager restart reloads persisted active runs without duplicate scheduled submit", %{
    job: job
  } do
    %CronJob{} = job

    due_job = %{
      job
      | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000,
        last_run_at_ms: nil
    }

    CronStore.put_job(due_job)
    replace_job_state(due_job)

    existing_run =
      due_job.id
      |> CronRun.new(:schedule)
      |> CronRun.start("router_restart_lock")

    CronStore.put_run(existing_run)

    old_pid = Process.whereis(CronManager)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 2_000

    assert await(fn ->
             case Process.whereis(CronManager) do
               pid when is_pid(pid) and pid != old_pid -> true
               _ -> false
             end
           end)

    CronManager.tick()
    refute_receive {:cron_submit, _run_id, _triggered_by}, 150
    assert Enum.map(CronStore.active_runs(job.id), & &1.id) == [existing_run.id]
  end

  test "manager restart recovers stale active runs as timeouts", %{job: job} do
    %CronJob{} = job

    stale_job = %{
      job
      | timeout_ms: 10,
        next_run_at_ms: LemonCore.Clock.now_ms() + 60_000,
        last_run_at_ms: nil
    }

    CronStore.put_job(stale_job)
    replace_job_state(stale_job)

    stale_run =
      stale_job.id
      |> CronRun.new(:schedule)
      |> CronRun.start("router_restart_stale")

    stale_run = %{stale_run | started_at_ms: LemonCore.Clock.now_ms() - 1_000}
    CronStore.put_run(stale_run)

    Bus.subscribe("cron")
    flush_events()

    on_exit(fn ->
      Bus.unsubscribe("cron")
    end)

    old_pid = Process.whereis(CronManager)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 2_000

    assert_receive %Event{
                     type: :cron_run_completed,
                     payload: %{cron_run_id: cron_run_id, status: :timeout}
                   },
                   2_000

    assert cron_run_id == stale_run.id

    assert await(fn ->
             case CronStore.get_run(stale_run.id) do
               %CronRun{status: :timeout, error: "Run exceeded timeout"} -> true
               _ -> false
             end
           end)

    assert CronStore.active_runs(stale_job.id) == []
  end

  defp replace_job_state(job) do
    :sys.replace_state(CronManager, fn state ->
      put_in(state.jobs[job.id], job)
    end)
  end

  defp await(fun, attempts \\ 100)

  defp await(_fun, 0), do: false

  defp await(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end

  defp flush_events do
    receive do
      %Event{} -> flush_events()
    after
      0 -> :ok
    end
  end
end
