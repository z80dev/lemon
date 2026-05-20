defmodule LemonAutomation.CronManagerRetryTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}

  defmodule RetrySubmitter do
    def submit(job, run, _opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:cron_submit, job.id, run.id, run.triggered_by, run.meta}
      )

      case run.triggered_by do
        :schedule -> {:error, "scheduled failure"}
        :manual -> {:error, "manual failure"}
        :retry -> {:ok, "retry success"}
      end
    end
  end

  setup do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, RetrySubmitter)
    :persistent_term.put({RetrySubmitter, :test_pid}, self())
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "retry-test-#{token}",
        schedule: "* * * * *",
        agent_id: "cron_retry_#{token}",
        session_key: "agent:cron_retry_#{token}:main",
        prompt: "retry me",
        timezone: "UTC",
        max_retries: 1,
        retry_backoff_ms: 0
      })

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_automation, :cron_run_submitter)
      else
        Application.put_env(:lemon_automation, :cron_run_submitter, previous)
      end

      :persistent_term.erase({RetrySubmitter, :test_pid})

      for run <- CronStore.list_runs(job.id, limit: 100) do
        CronStore.delete_run(run.id)
      end

      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "failed scheduled runs retry after the configured backoff", %{job: job} do
    %CronJob{} = job
    replace_job_state(%{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000})

    CronManager.tick()

    assert_receive {:cron_submit, job_id, first_run_id, :schedule, first_meta}, 2_000
    assert job_id == job.id
    assert first_meta.retry_attempt == 0
    assert first_meta.retry_root_id == first_run_id

    assert_receive {:cron_submit, ^job_id, retry_run_id, :retry, retry_meta}, 2_000
    assert retry_run_id != first_run_id
    assert retry_meta.retry_attempt == 1
    assert retry_meta.retry_of == first_run_id
    assert retry_meta.retry_root_id == first_run_id
    assert retry_meta.source_triggered_by == :schedule

    assert await(fn ->
             runs = CronStore.list_runs(job.id, limit: 10)

             Enum.any?(runs, &match?(%CronRun{id: ^first_run_id, status: :failed}, &1)) and
               Enum.any?(runs, &match?(%CronRun{id: ^retry_run_id, status: :completed}, &1))
           end)
  end

  test "manual runs do not retry by default", %{job: job} do
    assert {:ok, %CronRun{id: run_id, triggered_by: :manual}} = CronManager.run_now(job.id)

    assert_receive {:cron_submit, job_id, ^run_id, :manual, _meta}, 2_000
    assert job_id == job.id
    refute_receive {:cron_submit, ^job_id, _retry_run_id, :retry, _meta}, 150

    assert await(fn ->
             match?(%CronRun{id: ^run_id, status: :failed}, CronStore.get_run(run_id))
           end)
  end

  defp replace_job_state(job) do
    CronStore.put_job(job)

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
end
