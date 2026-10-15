defmodule LemonAutomation.CronFailureAlertsTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore, RunNotifications}
  alias LemonAutomation.Doctor.Checks.Cron, as: CronCheck
  alias LemonCore.{ChannelSupervision, Store}
  alias LemonCore.Doctor.CronDiagnostics

  defmodule Notices do
    @behaviour ChannelSupervision
    def bind_run(_id, _session, _target), do: :ok
    def target_for_run(_id, _session), do: :none

    def notify(target, notice) do
      send(Application.fetch_env!(:lemon_automation, :failure_alert_test_pid), {target, notice})
      Application.get_env(:lemon_automation, :failure_alert_test_result, :ok)
    end
  end

  setup do
    previous_provider = ChannelSupervision.provider()
    previous_gateway = Application.get_env(:lemon_gateway, LemonGateway.Config)
    id = "failure_alert_#{System.unique_integer([:positive, :monotonic])}"
    :ok = ChannelSupervision.register(Notices)
    Application.put_env(:lemon_automation, :failure_alert_test_pid, self())

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      enable_telegram: false,
      enable_discord: false
    })

    job =
      CronJob.new(%{
        id: id,
        name: "Nightly check",
        schedule: "0 0 1 1 *",
        enabled: false,
        command: "true"
      })

    CronStore.put_job(job)

    on_exit(fn ->
      restore(:lemon_core, :channel_supervision_provider, previous_provider)
      restore(:lemon_gateway, LemonGateway.Config, previous_gateway)
      Application.delete_env(:lemon_automation, :failure_alert_test_pid)
      Application.delete_env(:lemon_automation, :failure_alert_test_result)
      CronStore.delete_job(id)
      CronStore.delete_failure_alert_state(id)
      CronStore.clear_failure_notice(id)
      for run <- CronStore.list_runs(id), do: CronStore.delete_run(run.id)
    end)

    %{job: job}
  end

  test "terminalization increments once per run, persists across reload, and resets on success",
       %{job: job} do
    {:ok, state} = CronManager.init([])
    state = %{state | jobs: %{job.id => job}}
    run = running(job)
    CronStore.put_run(run)

    assert {:noreply, state} =
             CronManager.handle_info({:run_complete, run.id, {:error, "timeout"}}, state)

    assert CronJob.failure_streak(state.jobs[job.id]) == 1
    assert CronJob.last_status(CronStore.get_job(job.id)) == :failed

    assert {:noreply, state} =
             CronManager.handle_info({:run_complete, run.id, {:error, "late"}}, state)

    assert CronJob.failure_streak(state.jobs[job.id]) == 1

    run = running(job)
    CronStore.put_run(run)

    assert {:noreply, state} =
             CronManager.handle_info({:run_complete, run.id, {:error, "timeout"}}, state)

    assert CronJob.failure_streak(state.jobs[job.id]) == 2
    {:ok, reloaded} = CronManager.init([])
    assert CronJob.failure_streak(reloaded.jobs[job.id]) == 2

    run = running(job)
    CronStore.put_run(run)

    assert {:noreply, state} =
             CronManager.handle_info({:run_complete, run.id, {:ok, "ok"}}, state)

    assert CronJob.failure_streak(state.jobs[job.id]) == 0
    assert CronJob.last_status(CronStore.get_job(job.id)) == :completed
    refute CronStore.get_run(run.id).suppressed
    assert CronStore.get_failure_alert_state(job.id) == %{}
    assert CronStore.list_failure_notices() |> Enum.all?(&(&1.job_id != job.id))
  end

  test "retired one-shot failures remain visible as unread doctor alerts", %{job: job} do
    job = %{job | once: true}
    CronStore.put_job(job)
    {:ok, state} = CronManager.init([])
    state = %{state | jobs: %{job.id => job}}
    run = job.id |> CronRun.new(:schedule) |> CronRun.start(nil)
    CronStore.put_run(run)

    assert {:noreply, state} =
             CronManager.handle_info({:run_complete, run.id, {:error, "timeout"}}, state)

    refute Map.has_key?(state.jobs, job.id)
    assert CronStore.get_job(job.id) == nil
    assert Enum.any?(CronStore.list_failure_notices(), &(&1.job_id == job.id))
    diagnostics = CronDiagnostics.status(limit: 100)
    assert diagnostics.unread_failing_job_count >= 1

    assert Enum.any?(
             diagnostics.unread_failing_jobs,
             &(&1[:retired] == true and &1.last_status == "failed")
           )
  end

  test "first incident alerts, repeats cool down durably, changed classes alert and recovery is one notice",
       %{job: job} do
    job = %{job | deliver_to: "telegram:42:7"} |> with_streak(1)
    notify(job, "timeout", 1_000)
    assert_receive {%{peer: %{id: "42", thread_id: "7"}}, %{summary: summary}}
    assert summary =~ "Nightly check"
    assert summary =~ "Failure streak: 1"
    assert summary =~ "Last error: timeout"
    assert summary =~ "lemon cron runs --job #{job.id}"
    assert CronStore.get_failure_alert_state(job.id).alerted

    notify(with_streak(job, 2), "timed out at 123", 1_999)
    refute_receive {_, %{kind: :cron}}
    notify(with_streak(job, 3), "timeout at 456", 2_000)
    assert_receive {_, %{summary: summary}}
    assert summary =~ "Failure streak: 3"
    notify(job, "401 authentication failed", 2_001)
    assert_receive {_, %{summary: summary}}
    assert summary =~ "authentication_failed"
    notify(job, "timeout", 2_002)
    refute_receive {_, %{kind: :cron}}

    run = job |> running() |> CronRun.complete("All good")
    assert :ok = RunNotifications.cron_finished(with_streak(job, 0), run, "All good")
    assert_receive {_, %{status: :completed, summary: recovery}}
    assert recovery =~ "Cron recovered"
    assert recovery =~ "Last error: timeout"
    refute_receive {_, %{kind: :cron}}
    assert CronStore.get_failure_alert_state(job.id) == %{}
    notify(job, "timeout", 2_003)
    assert_receive {_, %{status: :failed}}
  end

  test "failure without a job route falls back to paired owner but success does not", %{job: job} do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      enable_telegram: true,
      telegram: %{allowed_chat_ids: [1234]}
    })

    job = %{job | deliver_to: "none"} |> with_streak(1)
    notify(job, "failed", 1_000)
    assert_receive {%{peer: %{id: "1234"}}, %{status: :failed}}
    assert CronStore.list_failure_notices() |> Enum.all?(&(&1.job_id != job.id))

    recovered = job |> running() |> CronRun.complete("ok")
    RunNotifications.cron_finished(with_streak(job, 0), recovered, "ok")
    assert_receive {%{peer: %{id: "1234"}}, %{summary: summary}}
    assert summary =~ "recovered"
    RunNotifications.cron_finished(job, job |> running() |> CronRun.complete("normal"), "normal")
    refute_receive {_, %{kind: :cron}}
  end

  test "no route is durable, deduped and visible in doctor without leaking raw errors", %{
    job: job
  } do
    job = CronJob.terminalize(job, :failed)
    CronStore.put_job(job)
    notify(job, "api_key=private-value /private/secret-path", 1_000)
    assert [notice] = Enum.filter(CronStore.list_failure_notices(), &(&1.job_id == job.id))
    assert notice.reason == :no_route
    assert notice.error_label == "run_failed"
    refute inspect(notice) =~ "private-value"
    refute inspect(notice) =~ "secret-path"
    notify(job, "api_key=different-value", 1_001)
    assert [^notice] = Enum.filter(CronStore.list_failure_notices(), &(&1.job_id == job.id))
    diagnostics = CronDiagnostics.status()
    assert diagnostics.unread_failing_job_count >= 1
    assert Enum.any?(diagnostics.unread_failing_jobs, &(&1.failure_streak == 1))
    [check] = CronCheck.run([])
    assert check.status == :warn
    assert check.message =~ "unread, undelivered"
    refute inspect(diagnostics) =~ job.name
  end

  test "failed notification admission records locally without retrying unknown outcomes", %{
    job: job
  } do
    Application.put_env(:lemon_automation, :failure_alert_test_result, {:error, :outcome_unknown})
    job = %{job | deliver_to: "telegram:42"} |> with_streak(1)
    notify(job, "timeout", 1_000)
    assert_receive {_, %{status: :failed}}
    notify(job, "timeout", 1_001)
    refute_receive {_, %{kind: :cron}}

    assert Enum.any?(
             CronStore.list_failure_notices(),
             &(&1.job_id == job.id and &1.reason == :delivery_failed)
           )
  end

  test "unchanged monitor output still sends the incident recovery notice", %{job: job} do
    job = %{job | deliver_to: "telegram:42"} |> with_streak(1)
    notify(job, "timeout", 1_000)
    assert_receive {_, %{status: :failed}}
    run = %{CronRun.complete(running(job), "unchanged") | suppressed: true}
    RunNotifications.cron_finished(with_streak(job, 0), run, "unchanged")
    assert_receive {_, %{summary: summary}}
    assert summary =~ "recovered"
  end

  test "silent and healthy heartbeat successes never send recovery notices; failures still alert",
       %{job: job} do
    job = %{job | deliver_to: "telegram:42"} |> with_streak(1)

    for output <- ["[SILENT]", "HEARTBEAT_OK"] do
      notify(job, "timeout", 1_000)
      assert_receive {_, %{status: :failed}}
      run = %{CronRun.complete(running(job), output) | suppressed: true}
      RunNotifications.cron_finished(with_streak(job, 0), run, output)
      refute_receive {_, %{kind: :cron}}
      assert CronStore.get_failure_alert_state(job.id) == %{}
    end

    failed = %{CronRun.fail(running(job), "timeout") | output: "[SILENT]", suppressed: true}
    RunNotifications.cron_finished(job, failed, "[SILENT]", now_ms: 1_001, cooldown_ms: 1_000)
    assert_receive {_, %{status: :failed}}
  end

  test "alert titles and text are bounded and redacted", %{job: job} do
    job = %{
      job
      | name: "api_key=private-value\n" <> String.duplicate("x", 2_000),
        deliver_to: "telegram:42",
        failure_state: %{consecutive_failures: 7, last_status: :failed}
    }

    notify(job, "token=private-error", 1_000)
    assert_receive {_, %{title: title, summary: summary}}
    assert String.length(title) <= 160
    assert String.length(summary) < 500
    refute summary =~ "private-value"
    refute summary =~ "private-error"
    assert summary =~ "[REDACTED]"
  end

  test "persisted fields round trip and old records default safely", %{job: job} do
    failed = job |> CronJob.terminalize(:failed) |> CronJob.terminalize(:timeout)
    CronStore.put_job(failed)
    assert CronStore.get_job(job.id) == failed
    old = Map.delete(CronJob.to_storage_map(failed), :failure_state)
    Store.put(:cron_jobs, job.id, old)

    assert %{failure_state: %{consecutive_failures: 0, last_status: nil}} =
             CronStore.get_job(job.id)

    assert CronJob.from_map(%{
             "id" => job.id,
             "name" => "old",
             "schedule" => "* * * * *",
             "failure_state" => %{"last_status" => "failed", "consecutive_failures" => 2}
           }).failure_state.last_status == :failed
  end

  defp with_streak(job, streak) do
    %{job | failure_state: %{consecutive_failures: streak, last_status: :failed}}
  end

  defp notify(job, error, now) do
    run = CronRun.fail(running(job), error)
    RunNotifications.cron_finished(job, run, error, now_ms: now, cooldown_ms: 1_000)
  end

  defp running(job) do
    job.id
    |> CronRun.new(:manual)
    |> CronRun.start(nil)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
