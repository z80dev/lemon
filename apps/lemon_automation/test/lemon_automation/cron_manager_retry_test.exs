defmodule LemonAutomation.CronManagerRetryTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}

  defmodule RetrySubmitter do
    def submit(job, run, _opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:cron_submit, self(), job.id, run.id, run.triggered_by, run.meta})

      case run.triggered_by do
        :schedule ->
          run_id = run.id

          receive do
            {:release_cron_submit, ^run_id} -> {:error, "scheduled failure"}
          after
            5_000 -> {:error, "scheduled failure"}
          end

        :manual ->
          {:error, "manual failure"}

        :retry ->
          {:ok, "retry success"}
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

    assert_receive {:cron_submit, submitter_pid, job_id, first_run_id, :schedule, first_meta},
                   5_000

    assert job_id == job.id
    assert first_meta.retry_attempt == 0
    assert first_meta.retry_root_id == first_run_id

    send(submitter_pid, {:release_cron_submit, first_run_id})

    assert await(fn ->
             Enum.any?(CronStore.list_audit_events(job_id: job.id, action: :retry_scheduled), fn
               event -> event.run_id == first_run_id
             end)
           end)

    assert_receive {:cron_submit, _submitter_pid, ^job_id, retry_run_id, :retry, retry_meta},
                   5_000

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

    assert_receive {:cron_submit, _submitter_pid, job_id, ^run_id, :manual, _meta}, 5_000
    assert job_id == job.id
    refute_receive {:cron_submit, _submitter_pid, ^job_id, _retry_run_id, :retry, _meta}, 150

    assert await(fn ->
             match?(%CronRun{id: ^run_id, status: :failed}, CronStore.get_run(run_id))
           end)
  end

  test "pending retry survives manager restart and keeps one deterministic attempt", %{job: job} do
    assert {:ok, job} = CronManager.update(job.id, %{retry_backoff_ms: 250})
    replace_job_state(%{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000})

    CronManager.tick()

    assert_receive {:cron_submit, submitter_pid, _job_id, first_run_id, :schedule, _meta}, 5_000
    send(submitter_pid, {:release_cron_submit, first_run_id})

    assert await(fn ->
             run = CronStore.get_run(first_run_id)
             is_integer(run && meta(run, :retry_due_at_ms))
           end)

    old_pid = Process.whereis(CronManager)
    GenServer.stop(CronManager)

    assert await(fn ->
             pid = Process.whereis(CronManager)
             is_pid(pid) and pid != old_pid
           end)

    assert_receive {:cron_submit, _pid, _job_id, retry_run_id, :retry, retry_meta}, 5_000

    assert retry_run_id == CronStore.retry_run_id(first_run_id, 1)
    assert retry_meta.retry_attempt == 1
    refute_receive {:cron_submit, _pid, _job_id, ^retry_run_id, :retry, _meta}, 500

    attempts =
      CronStore.list_runs(job.id, limit: 20)
      |> Enum.filter(&(meta(&1, :retry_root_id) == first_run_id))
      |> Enum.map(&meta(&1, :retry_attempt))

    assert Enum.sort(attempts) == [0, 1]
  end

  test "stale recovery uses normal terminal policy once and reconstructs retry", %{job: job} do
    assert {:ok, job} =
             CronManager.update(job.id, %{timeout_ms: 1, retry_backoff_ms: 0, max_retries: 1})

    root_id = "cron_stale_retry_#{System.unique_integer([:positive])}"

    stale =
      job.id
      |> CronRun.new(:schedule)
      |> Map.put(:id, root_id)
      |> Map.put(:meta, %{
        agent_id: job.agent_id,
        session_key: job.session_key,
        job_name: job.name,
        retry_attempt: 0,
        retry_root_id: root_id
      })
      |> CronRun.start("router_stale")
      |> Map.put(:started_at_ms, LemonCore.Clock.now_ms() - 1_000)

    CronStore.put_run(stale)
    LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(job.session_key))

    old_pid = Process.whereis(CronManager)
    GenServer.stop(CronManager)

    assert await(fn ->
             pid = Process.whereis(CronManager)
             is_pid(pid) and pid != old_pid
           end)

    assert_receive %LemonCore.Event{type: :run_completed, meta: %{cron_run_id: ^root_id}}, 5_000

    assert_receive {:cron_submit, _pid, _job_id, retry_run_id, :retry, retry_meta}, 5_000
    assert retry_run_id == CronStore.retry_run_id(root_id, 1)
    assert retry_meta.retry_root_id == root_id

    send(CronManager, {:run_complete, root_id, {:ok, "late"}})
    Process.sleep(50)

    assert CronStore.get_run(root_id).status == :timeout
    assert length(CronStore.list_audit_events(run_id: root_id, action: :stale_run_recovered)) == 1
    refute_receive {:cron_submit, _pid, _job_id, ^retry_run_id, :retry, _meta}, 300

    LemonCore.Bus.unsubscribe(LemonCore.Bus.session_topic(job.session_key))
  end

  defp replace_job_state(job) do
    CronStore.put_job(job)

    :sys.replace_state(CronManager, fn state ->
      put_in(state.jobs[job.id], job)
    end)
  end

  defp meta(run, key) do
    Map.get(run.meta || %{}, key) || Map.get(run.meta || %{}, Atom.to_string(key))
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
