defmodule LemonAutomation.CronManagerWorkerLifecycleTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronRun, CronStore}

  defmodule PassingPreflight do
    @moduledoc false
    def check(_job), do: :ok
    def current_default_model, do: {:ok, "test-model"}
  end

  defmodule CrashingSubmitter do
    @moduledoc false

    def submit(job, run, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:submitter_started, job.id, run.id})
      exit(:submitter_boom)
    end
  end

  setup do
    previous_submitter = Application.get_env(:lemon_automation, :cron_run_submitter)
    previous_preflight = Application.get_env(:lemon_automation, :cron_preflight_mod)
    Application.put_env(:lemon_automation, :cron_run_submitter, CrashingSubmitter)
    Application.put_env(:lemon_automation, :cron_preflight_mod, PassingPreflight)
    :persistent_term.put({CrashingSubmitter, :test_pid}, self())

    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "worker-lifecycle-#{token}",
        schedule: "* * * * *",
        agent_id: "worker_lifecycle_#{token}",
        session_key: "agent:worker_lifecycle_#{token}:main",
        prompt: "run"
      })

    original_supervisor = :sys.get_state(CronManager).task_supervisor

    on_exit(fn ->
      restore_env(:cron_run_submitter, previous_submitter)
      restore_env(:cron_preflight_mod, previous_preflight)
      :persistent_term.erase({CrashingSubmitter, :test_pid})

      if Process.whereis(CronManager) do
        :sys.replace_state(CronManager, &Map.put(&1, :task_supervisor, original_supervisor))
      end

      for run <- CronStore.list_runs(job.id, limit: 100), do: CronStore.delete_run(run.id)

      for event <- CronStore.list_audit_events(job_id: job.id, limit: 100) do
        CronStore.delete_audit_event(event.id)
      end

      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "submitter crash is terminalized immediately from the monitor", %{job: job} do
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    assert_receive {:submitter_started, job_id, ^run_id}, 1_000
    assert job_id == job.id

    assert eventually(fn ->
             match?(%CronRun{status: :failed}, CronStore.get_run(run_id))
           end)

    run = CronStore.get_run(run_id)
    assert run.error =~ "submitter_boom"
    assert Process.alive?(Process.whereis(CronManager))

    assert Enum.any?(CronStore.list_audit_events(run_id: run_id), fn event ->
             event.action == "worker_down"
           end)
  end

  test "missing task supervisor fails the run without unsupervised fallback", %{job: job} do
    :sys.replace_state(CronManager, &Map.put(&1, :task_supervisor, :missing_cron_task_supervisor))

    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)

    assert eventually(fn ->
             match?(%CronRun{status: :failed}, CronStore.get_run(run_id))
           end)

    run = CronStore.get_run(run_id)
    assert run.error =~ "task_supervisor_unavailable"
    refute_receive {:submitter_started, _job_id, ^run_id}, 100

    assert Enum.any?(CronStore.list_audit_events(run_id: run_id), fn event ->
             event.action == "worker_start_failed"
           end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_automation, key, value)
end
