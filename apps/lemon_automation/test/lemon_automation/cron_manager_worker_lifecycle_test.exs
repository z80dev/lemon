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

  defmodule ClaimThenCrashSubmitter do
    @moduledoc false

    def submit(job, run, opts) do
      :ok = Keyword.fetch!(opts, :on_submitting).(run.run_id, job.session_key)
      send(:persistent_term.get({CrashingSubmitter, :test_pid}), {:submitter_claimed, run.id})
      exit(:submitter_boom)
    end
  end

  defmodule AcceptedRouter do
    def submit(params) do
      send(:persistent_term.get({CrashingSubmitter, :test_pid}), {:router_submitted, params})
      {:ok, params.run_id}
    end
  end

  defmodule TimeoutWaiter do
    def wait_already_subscribed(_id, _timeout, _opts), do: :timeout
  end

  defmodule TimeoutSubmitter do
    def submit(job, run, opts) do
      LemonAutomation.RunSubmitter.submit(
        job,
        run,
        Keyword.merge(opts, router_mod: AcceptedRouter, waiter_mod: TimeoutWaiter)
      )
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

  test "submitter crash before the submission claim releases the run", %{job: job} do
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    assert_receive {:submitter_started, job_id, ^run_id}, 1_000
    assert job_id == job.id

    assert eventually(fn -> match?(%CronRun{status: :failed}, CronStore.get_run(run_id)) end)

    run = CronStore.get_run(run_id)
    assert run.error == "cron run was never submitted"
    refute run.meta[:outcome_unknown]
    assert {:ok, %CronRun{id: next_id}} = CronManager.run_now(job.id)
    assert next_id != run_id
    assert Process.alive?(Process.whereis(CronManager))

    assert Enum.any?(CronStore.list_audit_events(run_id: run_id), fn event ->
             event.action == "claim_released"
           end)
  end

  test "submitter crash after the submission claim retains router ownership", %{job: job} do
    Application.put_env(:lemon_automation, :cron_run_submitter, ClaimThenCrashSubmitter)
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    assert_receive {:submitter_claimed, ^run_id}, 1_000

    assert eventually(fn ->
             match?(
               %CronRun{status: :running, meta: %{outcome_unknown: true}},
               CronStore.get_run(run_id)
             )
           end)

    run = CronStore.get_run(run_id)
    assert run.error == "completion_outcome_unknown"
    assert is_binary(run.run_id)
    assert {:error, :outcome_unknown} = CronManager.run_now(job.id)

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

  test "full task supervisor terminalizes manual work without submitting it", %{job: job} do
    supervisor = start_supervised!(LemonCore.TaskSupervisor.child_spec(max_children: 1))

    assert {:ok, _blocker} =
             LemonCore.TaskSupervisor.start_child(supervisor, fn ->
               receive do
                 :release -> :ok
               end
             end)

    :sys.replace_state(CronManager, &Map.put(&1, :task_supervisor, supervisor))
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)

    state = :sys.get_state(CronManager)
    run = CronStore.get_run(run_id)
    assert run.status == :failed
    assert run.error =~ "task_capacity_reached"
    refute Map.has_key?(state.tasks, run_id)
    refute_receive {:submitter_started, _job_id, ^run_id}, 0
    assert Process.alive?(Process.whereis(CronManager))
  end

  test "accepted coding timeout cannot schedule duplicate retries and keeps its session link", %{
    job: job
  } do
    Application.put_env(:lemon_automation, :cron_run_submitter, TimeoutSubmitter)

    {:ok, job} =
      CronManager.update(job.id, %{cwd: System.tmp_dir!(), max_retries: 2, retry_backoff_ms: 0})

    due_job = %{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1}
    CronStore.put_job(due_job)
    :sys.replace_state(CronManager, &put_in(&1.jobs[job.id], due_job))
    CronManager.tick()

    assert_receive {:router_submitted, params}, 1_000
    assert params.cwd == Path.expand(System.tmp_dir!())
    cron_id = params.meta.cron_run_id

    assert eventually(fn ->
             match?(%CronRun{meta: %{outcome_unknown: true}}, CronStore.get_run(cron_id))
           end)

    persisted = CronStore.get_run(cron_id)
    assert persisted.run_id == params.run_id
    assert persisted.meta.router_session_key == params.session_key
    assert persisted.meta.retry_attempt == 0
    assert is_nil(persisted.meta[:retry_due_at_ms])
    CronManager.tick()
    refute_receive {:router_submitted, _}, 100
    assert length(CronStore.list_runs(job.id)) == 1
  end

  defp eventually(fun, attempts \\ 500)
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
